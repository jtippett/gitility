//! Failure-atomic administration for gitility-owned bare repositories.
//!
//! These helpers are intentionally synchronous. The NIF adapter schedules
//! them on dirty IO schedulers, while native fetch calls the initializer from
//! its existing runtime worker.

use crate::{Error, ErrorCode, HashKind};
use bstr::{BString, ByteSlice};
use gix_ref::transaction::{Change, LogChange, PreviousValue, RefEdit, RefLog};
use gix_ref::Target;
use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

const STAGING_RANDOM_BYTES: usize = 16;
const STAGING_ATTEMPTS: usize = 16;
const BUNDLE_TOC_CAP_BYTES: usize = 67_108_864;
// Four name-length bytes, one name byte, a SHA-1 oid, kind, and peeled flag.
// Format.parse applies the byte ceiling before write_refs is reached; derive a
// count guard from that format bound instead of treating bytes as rows.
const MIN_BUNDLE_REF_ROW_BYTES: usize = 27;
const MAX_BUNDLE_REF_ROWS: usize = BUNDLE_TOC_CAP_BYTES / MIN_BUNDLE_REF_ROW_BYTES;
const MAX_REF_NAME_BYTES: usize = 4096;
const MAX_REF_COMPONENT_BYTES: usize = 255;

/// Initialize a gc-safe bare repository without ever exposing a partial
/// repository at `path`.
pub fn init_bare(path: &Path, hash: HashKind) -> Result<(), Error> {
    if hash != HashKind::Sha1 {
        return Err(Error::new(
            ErrorCode::UnsupportedHash,
            "bare repository initialization supports SHA-1 only",
        ));
    }

    init_bare_repo(path).map(|_| ())
}

/// Initialize a gc-safe SHA-1 bare repository and return a handle opened at
/// its final path. Native fetch shares this exact creation path.
pub(crate) fn init_bare_repo(path: &Path) -> Result<gix::Repository, Error> {
    let destination_preexisted = validate_destination(path)?;

    let parent = destination_parent(path)?;
    std::fs::create_dir_all(parent).map_err(|_| {
        Error::new(
            ErrorCode::BackendError,
            "bare repository parent directory could not be created",
        )
    })?;
    sweep_init_staging(parent, destination_name(path)?)?;

    let (staging_path, mut staging) = create_staging_directory(path, parent)?;
    let staged_repo = gix::ThreadSafeRepository::init_opts(
        &staging_path,
        gix::create::Kind::Bare,
        gix::create::Options::default(),
        gix::open::Options::isolated(),
    )
    .map(|repo| repo.to_thread_local())
    .map_err(|_| {
        Error::new(
            ErrorCode::BackendError,
            "bare repository staging directory could not be initialized",
        )
    })?;

    write_gc_safe_config(staged_repo.git_dir())?;
    drop(staged_repo);

    let staging_identity = directory_identity(&staging_path)?;

    std::fs::rename(&staging_path, path).map_err(map_install_error)?;
    match gix::open_opts(path, gix::open::Options::isolated()) {
        Ok(repo) => {
            staging.committed = true;
            Ok(repo)
        }
        Err(_) => {
            // No fallible operation may report failure while leaving the
            // just-installed repository behind. Compare the directory
            // identity before cleanup so a cross-process replacement is
            // never removed accidentally.
            cleanup_failed_install(path, staging_identity, destination_preexisted);
            Err(Error::new(
                ErrorCode::BackendError,
                "initialized bare repository could not be reopened",
            ))
        }
    }
}

fn cleanup_failed_install(path: &Path, staging_identity: (u64, u64), preexisted: bool) {
    if directory_identity(path).ok() != Some(staging_identity) {
        return;
    }
    let removed = std::fs::remove_dir_all(path).is_ok();
    if removed && preexisted {
        // rename(2) replaced the caller's pre-existing empty directory.
        // Recreate it so an initialization error does not make a path the
        // caller already owned disappear.
        let _ = std::fs::create_dir(path);
    }
}

fn directory_identity(path: &Path) -> Result<(u64, u64), Error> {
    std::fs::symlink_metadata(path)
        .map(|metadata| (metadata.dev(), metadata.ino()))
        .map_err(|_| {
            Error::new(
                ErrorCode::BackendError,
                "bare repository staging directory could not be inspected",
            )
        })
}

fn map_install_error(error: std::io::Error) -> Error {
    use std::io::ErrorKind;

    let destination_changed = matches!(
        error.kind(),
        ErrorKind::AlreadyExists
            | ErrorKind::DirectoryNotEmpty
            | ErrorKind::NotADirectory
            | ErrorKind::IsADirectory
    );

    if destination_changed {
        Error::new(
            ErrorCode::InvalidArgument,
            "bare repository destination changed during initialization",
        )
    } else {
        Error::new(
            ErrorCode::BackendError,
            "bare repository staging directory could not be installed",
        )
    }
}

/// Atomically create all supplied references and HEAD in one gix-ref
/// transaction. Reference names are raw bytes; object IDs must use the
/// repository's configured hash family.
#[allow(clippy::type_complexity)] // The frozen cross-language API names this tuple shape.
pub fn write_refs(
    path: &Path,
    refs: Vec<(Vec<u8>, Vec<u8>)>,
    head: Option<(Option<Vec<u8>>, Option<Vec<u8>>)>,
) -> Result<u64, Error> {
    if refs.len() > MAX_BUNDLE_REF_ROWS {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "reference count exceeds the bundle TOC cap",
        ));
    }

    let repo = gix::open_opts(path, gix::open::Options::isolated()).map_err(|_| {
        Error::new(
            ErrorCode::InvalidArgument,
            "reference destination is not a Git repository",
        )
    })?;
    if !repo.is_bare() {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "reference destination must be a bare repository",
        ));
    }

    let hash = repo.object_hash();
    let mut targets = BTreeMap::<Vec<u8>, gix_hash::ObjectId>::new();
    for (name, raw_oid) in refs {
        validated_ref_name(&name)?;
        if name == b"HEAD" {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "HEAD must be supplied through the dedicated head argument",
            ));
        }
        let oid = oid_for_repo(hash, &raw_oid)?;
        if targets.insert(name, oid).is_some() {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "duplicate reference name",
            ));
        }
    }

    let (head_oid, head_symref) =
        head.ok_or_else(|| Error::new(ErrorCode::InvalidArgument, "HEAD target must be supplied"))?;

    let head_target = match (head_oid, head_symref) {
        (Some(raw_oid), Some(raw_symref)) => {
            let oid = oid_for_repo(hash, &raw_oid)?;
            let symref = validated_head_symref(&raw_symref)?;
            match targets.get(raw_symref.as_slice()) {
                Some(target) if *target == oid => Target::Symbolic(symref),
                _ => {
                    return Err(Error::new(
                        ErrorCode::InvalidArgument,
                        "HEAD symref target disagrees with HEAD row",
                    ));
                }
            }
        }
        (None, Some(raw_symref)) => {
            let symref = validated_head_symref(&raw_symref)?;
            if targets.contains_key(raw_symref.as_slice()) {
                return Err(Error::new(
                    ErrorCode::InvalidArgument,
                    "unborn HEAD must name an absent branch reference",
                ));
            }
            Target::Symbolic(symref)
        }
        (Some(raw_oid), None) => Target::Object(oid_for_repo(hash, &raw_oid)?),
        (None, None) => {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "HEAD target must contain an object ID or symbolic reference",
            ));
        }
    };

    let has_directory_file_conflict = has_directory_file_conflict(&targets);
    let mut edits = Vec::with_capacity(targets.len().saturating_add(1));
    for (name, oid) in targets {
        edits.push(update_edit(
            validated_ref_name(&name)?,
            Target::Object(oid),
            PreviousValue::MustNotExist,
        ));
    }
    edits.push(update_edit(
        "HEAD"
            .try_into()
            .expect("HEAD is a valid full reference name"),
        head_target,
        PreviousValue::Any,
    ));

    let committed = repo
        .edit_references(edits)
        .map_err(|error| map_edit_error(error, has_directory_file_conflict))?;
    u64::try_from(committed.len()).map_err(|_| {
        Error::new(
            ErrorCode::UnsupportedOperation,
            "reference transaction edit count exceeds u64",
        )
    })
}

fn has_directory_file_conflict(targets: &BTreeMap<Vec<u8>, gix_hash::ObjectId>) -> bool {
    // HEAD is added to every transaction below even though it is not present
    // in `targets`. Account for it here so a supplied `HEAD/...` reference is
    // classified as malformed bundle content instead of a filesystem failure.
    if targets.keys().any(|name| name.starts_with(b"HEAD/")) {
        return true;
    }

    targets.keys().any(|name| {
        name.iter()
            .enumerate()
            .any(|(index, byte)| *byte == b'/' && targets.contains_key(&name[..index]))
    })
}

fn map_edit_error(error: gix::reference::edit::Error, has_directory_file_conflict: bool) -> Error {
    use gix_ref::file::transaction::prepare::Error as PrepareError;

    let content_conflict = matches!(
        error,
        gix::reference::edit::Error::FileTransactionPrepare(
            PrepareError::DeleteReferenceMustExist { .. }
                | PrepareError::MustNotExist { .. }
                | PrepareError::MustExist { .. }
                | PrepareError::ReferenceOutOfDate { .. }
                | PrepareError::ReferenceDecode(_)
        )
    );

    if has_directory_file_conflict || content_conflict {
        Error::new(
            ErrorCode::MalformedRef,
            "reference transaction could not be applied",
        )
    } else {
        Error::new(
            ErrorCode::BackendError,
            "reference transaction failed during filesystem IO",
        )
    }
}

fn update_edit(name: gix_ref::FullName, new: Target, expected: PreviousValue) -> RefEdit {
    RefEdit {
        change: Change::Update {
            log: LogChange {
                mode: RefLog::AndReference,
                force_create_reflog: false,
                message: BString::default(),
            },
            expected,
            new,
        },
        name,
        deref: false,
    }
}

fn validated_ref_name(name: &[u8]) -> Result<gix_ref::FullName, Error> {
    if name.len() > MAX_REF_NAME_BYTES {
        return Err(
            Error::new(ErrorCode::MalformedRef, "reference name is too long")
                .with_reason("name_too_long"),
        );
    }
    if name
        .split(|byte| *byte == b'/')
        .any(|component| component.len() > MAX_REF_COMPONENT_BYTES)
    {
        return Err(Error::new(
            ErrorCode::MalformedRef,
            "reference name component is too long",
        )
        .with_reason("component_too_long"));
    }
    gix::validate::reference::name(name.as_bstr())
        .map_err(|_| Error::new(ErrorCode::MalformedRef, "reference name is malformed"))?;
    BString::from(name)
        .try_into()
        .map_err(|_| Error::new(ErrorCode::MalformedRef, "reference name is malformed"))
}

fn validated_head_symref(name: &[u8]) -> Result<gix_ref::FullName, Error> {
    let name = validated_ref_name(name)?;
    if !name.as_bstr().starts_with(b"refs/heads/") {
        return Err(Error::new(
            ErrorCode::MalformedRef,
            "HEAD symbolic reference must name a branch",
        ));
    }
    Ok(name)
}

fn oid_for_repo(hash: gix_hash::Kind, raw: &[u8]) -> Result<gix_hash::ObjectId, Error> {
    if raw.len() != hash.len_in_bytes() {
        return Err(Error::new(
            ErrorCode::InvalidOid,
            "object ID length does not match the repository hash",
        ));
    }
    let oid = gix_hash::ObjectId::try_from(raw).map_err(|_| {
        Error::new(
            ErrorCode::InvalidOid,
            "object ID length does not match the repository hash",
        )
    })?;
    if oid.kind() != hash {
        return Err(Error::new(
            ErrorCode::InvalidOid,
            "object ID hash does not match the repository hash",
        ));
    }
    Ok(oid)
}

fn validate_destination(path: &Path) -> Result<bool, Error> {
    destination_name(path)?;
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => {
            let mut entries = std::fs::read_dir(path).map_err(|_| invalid_destination())?;
            if entries.next().is_some() {
                Err(invalid_destination())
            } else {
                Ok(true)
            }
        }
        Ok(_) => Err(invalid_destination()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err(invalid_destination()),
    }
}

fn invalid_destination() -> Error {
    Error::new(
        ErrorCode::InvalidArgument,
        "bare repository path must not exist or must be an empty directory",
    )
}

fn destination_parent(path: &Path) -> Result<&Path, Error> {
    let parent = path.parent().ok_or_else(invalid_destination)?;
    if parent.as_os_str().is_empty() {
        Ok(Path::new("."))
    } else {
        Ok(parent)
    }
}

fn destination_name(path: &Path) -> Result<&OsStr, Error> {
    path.file_name().ok_or_else(invalid_destination)
}

fn sweep_init_staging(parent: &Path, basename: &OsStr) -> Result<(), Error> {
    let entries = std::fs::read_dir(parent).map_err(|_| {
        Error::new(
            ErrorCode::BackendError,
            "bare repository staging parent could not be read",
        )
    })?;
    for entry in entries {
        let entry = entry.map_err(|_| {
            Error::new(
                ErrorCode::BackendError,
                "bare repository staging entry could not be read",
            )
        })?;
        if !is_init_staging_name(&entry.file_name(), basename) {
            continue;
        }
        let file_type = entry.file_type().map_err(|_| {
            Error::new(
                ErrorCode::BackendError,
                "bare repository staging entry could not be inspected",
            )
        })?;
        if file_type.is_dir() {
            std::fs::remove_dir_all(entry.path()).map_err(|_| {
                Error::new(
                    ErrorCode::BackendError,
                    "bare repository staging directory could not be swept",
                )
            })?;
        }
    }
    Ok(())
}

fn is_init_staging_name(candidate: &OsStr, basename: &OsStr) -> bool {
    let candidate = candidate.as_bytes();
    let basename = basename.as_bytes();
    let Some(suffix) = candidate.strip_prefix(basename) else {
        return false;
    };
    let Some(hex) = suffix.strip_prefix(b".init-") else {
        return false;
    };
    hex.len() == STAGING_RANDOM_BYTES * 2
        && hex
            .iter()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn create_staging_directory(path: &Path, parent: &Path) -> Result<(PathBuf, StagingGuard), Error> {
    let basename = destination_name(path)?;
    for _ in 0..STAGING_ATTEMPTS {
        let random = random_hex()?;
        let mut name = OsString::from(basename);
        name.push(".init-");
        name.push(random);
        let staging_path = parent.join(name);
        match std::fs::create_dir(&staging_path) {
            Ok(()) => {
                return Ok((
                    staging_path.clone(),
                    StagingGuard {
                        path: staging_path,
                        committed: false,
                    },
                ));
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => {
                return Err(Error::new(
                    ErrorCode::BackendError,
                    "bare repository staging directory could not be created",
                ));
            }
        }
    }
    Err(Error::new(
        ErrorCode::BackendError,
        "bare repository staging name could not be allocated",
    ))
}

fn random_hex() -> Result<String, Error> {
    let mut bytes = [0u8; STAGING_RANDOM_BYTES];
    File::open("/dev/urandom")
        .and_then(|mut source| source.read_exact(&mut bytes))
        .map_err(|_| {
            Error::new(
                ErrorCode::BackendError,
                "bare repository staging randomness is unavailable",
            )
        })?;
    let mut hex = String::with_capacity(STAGING_RANDOM_BYTES * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        write!(&mut hex, "{byte:02x}").expect("writing to a String cannot fail");
    }
    Ok(hex)
}

fn write_gc_safe_config(git_dir: &Path) -> Result<(), Error> {
    let config_path = git_dir.join("config");
    let mut config =
        gix_config::File::from_path_no_includes(config_path.clone(), gix_config::Source::Local)
            .map_err(|_| config_error())?;
    for (key, value) in [
        ("gc.auto", "0"),
        ("maintenance.auto", "false"),
        ("receive.autogc", "false"),
    ] {
        config
            .set_raw_value(key, value)
            .map_err(|_| config_error())?;
    }

    let temp_path = git_dir.join("config.tmp");
    let mut temp = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temp_path)
        .map_err(|_| config_error())?;
    config.write_to(&mut temp).map_err(|_| config_error())?;
    temp.flush().map_err(|_| config_error())?;
    drop(temp);
    std::fs::rename(&temp_path, &config_path).map_err(|_| config_error())
}

fn config_error() -> Error {
    Error::new(
        ErrorCode::BackendError,
        "gc-safe bare repository configuration could not be written",
    )
}

struct StagingGuard {
    path: PathBuf,
    committed: bool,
}

impl Drop for StagingGuard {
    fn drop(&mut self) {
        if !self.committed {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static NEXT_TEST_DIR: AtomicU64 = AtomicU64::new(1);

    struct TestDir(PathBuf);

    impl TestDir {
        fn new(name: &str) -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system time follows the Unix epoch")
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "gitility-repo-admin-{name}-{}-{nonce}-{}",
                std::process::id(),
                NEXT_TEST_DIR.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&path).expect("test directory is created");
            Self(path)
        }

        fn join(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn oid(byte: u8) -> Vec<u8> {
        vec![byte; HashKind::Sha1.digest_len()]
    }

    #[test]
    fn init_bare_is_gc_safe_and_replaces_an_empty_destination() {
        let root = TestDir::new("init");
        let destination = root.join("nested/repo.git");
        std::fs::create_dir_all(&destination).expect("empty destination is created");

        init_bare(&destination, HashKind::Sha1).expect("bare init succeeds");

        let repo =
            gix::open_opts(&destination, gix::open::Options::isolated()).expect("repository opens");
        assert!(repo.is_bare());
        let config = gix_config::File::from_path_no_includes(
            destination.join("config"),
            gix_config::Source::Local,
        )
        .expect("config parses");
        assert_eq!(config.raw_value("gc.auto").unwrap(), "0");
        assert_eq!(config.raw_value("maintenance.auto").unwrap(), "false");
        assert_eq!(config.raw_value("receive.autogc").unwrap(), "false");
        assert!(!destination.join("config.tmp").exists());
        assert!(std::fs::read_dir(destination.parent().unwrap())
            .unwrap()
            .all(|entry| !is_init_staging_name(
                &entry.unwrap().file_name(),
                destination.file_name().unwrap()
            )));

        let nested = root.join("missing/parent/repo.git");
        init_bare(&nested, HashKind::Sha1).expect("missing parents are created");
        assert!(nested.join("config").is_file());
    }

    #[test]
    fn init_bare_sweeps_only_exact_owned_staging_directories() {
        let root = TestDir::new("sweep");
        let destination = root.join("repo.git");
        let orphan = root.join("repo.git.init-0123456789abcdef0123456789abcdef");
        let decoy = root.join("repo.git.init-not-ours");
        let matching_file = root.join("repo.git.init-fedcba9876543210fedcba9876543210");
        std::fs::create_dir(&orphan).unwrap();
        std::fs::create_dir(&decoy).unwrap();
        std::fs::write(&matching_file, b"keep").unwrap();

        init_bare(&destination, HashKind::Sha1).expect("bare init succeeds");

        assert!(!orphan.exists());
        assert!(decoy.exists());
        assert_eq!(std::fs::read(matching_file).unwrap(), b"keep");
    }

    #[test]
    fn init_bare_rejects_nonempty_and_sha256_without_partial_output() {
        let root = TestDir::new("refuse");
        let nonempty = root.join("nonempty.git");
        std::fs::create_dir(&nonempty).unwrap();
        std::fs::write(nonempty.join("keep"), b"untouched").unwrap();

        let error = init_bare(&nonempty, HashKind::Sha1).expect_err("nonempty is refused");
        assert_eq!(error.code, ErrorCode::InvalidArgument);
        assert_eq!(std::fs::read(nonempty.join("keep")).unwrap(), b"untouched");

        let unsupported = root.join("missing/sha256.git");
        let error = init_bare(&unsupported, HashKind::Sha256).expect_err("sha256 is refused");
        assert_eq!(error.code, ErrorCode::UnsupportedHash);
        assert!(!unsupported.parent().unwrap().exists());
    }

    #[test]
    fn install_rename_classifies_destination_races_separately_from_io() {
        use std::io::ErrorKind;

        for kind in [
            ErrorKind::AlreadyExists,
            ErrorKind::DirectoryNotEmpty,
            ErrorKind::NotADirectory,
            ErrorKind::IsADirectory,
        ] {
            assert_eq!(
                map_install_error(std::io::Error::from(kind)).code,
                ErrorCode::InvalidArgument
            );
        }

        for kind in [
            ErrorKind::PermissionDenied,
            ErrorKind::Interrupted,
            ErrorKind::Other,
        ] {
            assert_eq!(
                map_install_error(std::io::Error::from(kind)).code,
                ErrorCode::BackendError
            );
        }
    }

    #[test]
    fn failed_install_cleanup_restores_a_preexisting_empty_destination() {
        let root = TestDir::new("reopen-failure-cleanup");
        let preexisting = root.join("preexisting.git");
        std::fs::create_dir(&preexisting).unwrap();
        std::fs::write(preexisting.join("partial"), b"installed staging").unwrap();
        let identity = directory_identity(&preexisting).unwrap();

        cleanup_failed_install(&preexisting, identity, true);

        assert!(preexisting.is_dir());
        assert_eq!(std::fs::read_dir(&preexisting).unwrap().count(), 0);

        let originally_absent = root.join("absent.git");
        std::fs::create_dir(&originally_absent).unwrap();
        let identity = directory_identity(&originally_absent).unwrap();

        cleanup_failed_install(&originally_absent, identity, false);

        assert!(!originally_absent.exists());
    }

    #[test]
    fn write_refs_commits_named_and_symbolic_head_edits_together() {
        let root = TestDir::new("write-symbolic");
        let destination = root.join("repo.git");
        init_bare(&destination, HashKind::Sha1).unwrap();
        let target = oid(1);

        let count = write_refs(
            &destination,
            vec![(b"refs/heads/main".to_vec(), target.clone())],
            Some((Some(target.clone()), Some(b"refs/heads/main".to_vec()))),
        )
        .expect("reference transaction succeeds");

        assert_eq!(count, 2);
        assert_eq!(
            std::fs::read(destination.join("HEAD")).unwrap(),
            b"ref: refs/heads/main\n"
        );
        assert_eq!(
            std::fs::read_to_string(destination.join("refs/heads/main")).unwrap(),
            format!("{}\n", "01".repeat(20))
        );
        assert!(!destination.join("logs").exists());
    }

    #[test]
    fn write_refs_supports_unborn_and_detached_head() {
        let root = TestDir::new("head-shapes");
        let unborn = root.join("unborn.git");
        init_bare(&unborn, HashKind::Sha1).unwrap();
        assert_eq!(
            write_refs(
                &unborn,
                Vec::new(),
                Some((None, Some(b"refs/heads/trunk".to_vec())))
            )
            .unwrap(),
            1
        );
        assert_eq!(
            std::fs::read(unborn.join("HEAD")).unwrap(),
            b"ref: refs/heads/trunk\n"
        );

        let detached = root.join("detached.git");
        init_bare(&detached, HashKind::Sha1).unwrap();
        let target = oid(2);
        assert_eq!(
            write_refs(&detached, Vec::new(), Some((Some(target.clone()), None))).unwrap(),
            1
        );
        assert_eq!(
            std::fs::read_to_string(detached.join("HEAD")).unwrap(),
            format!("{}\n", "02".repeat(20))
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn write_refs_preserves_non_utf8_reference_names() {
        let root = TestDir::new("raw-ref-name");
        let destination = root.join("repo.git");
        init_bare(&destination, HashKind::Sha1).unwrap();
        let mut name = b"refs/heads/raw-".to_vec();
        name.push(0xff);
        let target = oid(3);

        assert_eq!(
            write_refs(
                &destination,
                vec![(name.clone(), target.clone())],
                Some((Some(target), None))
            )
            .unwrap(),
            2
        );

        assert_eq!(
            std::fs::read(destination.join("HEAD")).unwrap(),
            format!("{}\n", "03".repeat(20)).as_bytes()
        );
        assert_eq!(
            std::fs::read(destination.join(Path::new(OsStr::from_bytes(&name)))).unwrap(),
            format!("{}\n", "03".repeat(20)).as_bytes()
        );
    }

    #[test]
    fn write_refs_validates_names_oids_duplicates_and_head_consistency() {
        let root = TestDir::new("validation");
        let mut oversized_head = b"refs/heads/".to_vec();
        while oversized_head.len() + 251 <= 5000 {
            oversized_head.extend(vec![b'a'; 250]);
            oversized_head.push(b'/');
        }
        oversized_head.extend(vec![b'a'; 5000 - oversized_head.len()]);

        let cases = [
            (
                vec![(b"refs/heads/bad..name".to_vec(), oid(1))],
                Some((Some(oid(1)), Some(b"refs/heads/bad..name".to_vec()))),
                ErrorCode::MalformedRef,
            ),
            (
                vec![(b"refs/heads/main".to_vec(), vec![1; 19])],
                Some((Some(oid(1)), Some(b"refs/heads/main".to_vec()))),
                ErrorCode::InvalidOid,
            ),
            (
                vec![
                    (b"refs/heads/main".to_vec(), oid(1)),
                    (b"refs/heads/main".to_vec(), oid(1)),
                ],
                Some((Some(oid(1)), Some(b"refs/heads/main".to_vec()))),
                ErrorCode::InvalidArgument,
            ),
            (
                vec![(b"refs/heads/main".to_vec(), oid(1))],
                Some((Some(oid(2)), Some(b"refs/heads/main".to_vec()))),
                ErrorCode::InvalidArgument,
            ),
            (
                vec![(b"refs/heads/main".to_vec(), oid(1))],
                Some((None, Some(b"refs/heads/main".to_vec()))),
                ErrorCode::InvalidArgument,
            ),
            (
                Vec::new(),
                Some((None, Some(b"refs/tags/missing".to_vec()))),
                ErrorCode::MalformedRef,
            ),
            (
                vec![(b"refs/tags/v1".to_vec(), oid(1))],
                Some((Some(oid(1)), Some(b"refs/tags/v1".to_vec()))),
                ErrorCode::MalformedRef,
            ),
            (
                Vec::new(),
                Some((None, Some(oversized_head))),
                ErrorCode::MalformedRef,
            ),
        ];

        for (index, (refs, head, expected)) in cases.into_iter().enumerate() {
            let destination = root.join(&format!("case-{index}.git"));
            init_bare(&destination, HashKind::Sha1).unwrap();
            let error = write_refs(&destination, refs, head).expect_err("input is refused");
            assert_eq!(error.code, expected);
        }

        let missing_head = root.join("missing-head.git");
        init_bare(&missing_head, HashKind::Sha1).unwrap();
        assert_eq!(
            write_refs(&missing_head, Vec::new(), None)
                .expect_err("missing HEAD is refused")
                .code,
            ErrorCode::InvalidArgument
        );

        let nil_head = root.join("nil-head.git");
        init_bare(&nil_head, HashKind::Sha1).unwrap();
        assert_eq!(
            write_refs(&nil_head, Vec::new(), Some((None, None)))
                .expect_err("empty HEAD is refused")
                .code,
            ErrorCode::InvalidArgument
        );
    }

    #[test]
    fn write_refs_rejects_a_component_too_long_for_loose_refs() {
        let root = TestDir::new("component-too-long");
        let destination = root.join("repo.git");
        init_bare(&destination, HashKind::Sha1).unwrap();
        let name = [b"refs/heads/".as_slice(), vec![b'a'; 300].as_slice()].concat();

        let error = write_refs(
            &destination,
            vec![(name, oid(1))],
            Some((Some(oid(1)), None)),
        )
        .expect_err("a ref component beyond the portable filesystem limit is refused");

        assert_eq!(error.code, ErrorCode::MalformedRef);
        assert_eq!(error.reason.as_deref(), Some("component_too_long"));
        assert!(!destination.join("packed-refs").exists());
    }

    #[test]
    fn write_refs_maps_directory_file_conflicts_to_malformed_ref_atomically() {
        let root = TestDir::new("df-conflict");
        let destination = root.join("repo.git");
        init_bare(&destination, HashKind::Sha1).unwrap();

        let error = write_refs(
            &destination,
            vec![
                (b"refs/heads/a".to_vec(), oid(1)),
                (b"refs/heads/a-else".to_vec(), oid(3)),
                (b"refs/heads/a/b".to_vec(), oid(2)),
            ],
            Some((Some(oid(1)), Some(b"refs/heads/a".to_vec()))),
        )
        .expect_err("D/F conflict is refused");

        assert_eq!(error.code, ErrorCode::MalformedRef);
        assert!(!destination.join("refs/heads/a").exists());
        assert!(!destination.join("refs/heads/a-else").exists());

        let head_destination = root.join("head-conflict.git");
        init_bare(&head_destination, HashKind::Sha1).unwrap();
        let error = write_refs(
            &head_destination,
            vec![(b"HEAD/child".to_vec(), oid(3))],
            Some((Some(oid(4)), None)),
        )
        .expect_err("a reference below the injected HEAD edit is refused");

        assert_eq!(error.code, ErrorCode::MalformedRef);
        assert!(!head_destination.join("HEAD/child").exists());
        assert_eq!(
            std::fs::read(head_destination.join("HEAD")).unwrap(),
            b"ref: refs/heads/main\n"
        );
    }

    #[test]
    fn write_refs_keeps_lock_and_io_failures_as_backend_errors() {
        let root = TestDir::new("lock-failure");
        let destination = root.join("repo.git");
        init_bare(&destination, HashKind::Sha1).unwrap();
        std::fs::create_dir_all(destination.join("refs/heads")).unwrap();
        std::fs::write(destination.join("refs/heads/main.lock"), b"held").unwrap();
        let target = oid(4);

        let error = write_refs(
            &destination,
            vec![(b"refs/heads/main".to_vec(), target.clone())],
            Some((Some(target), Some(b"refs/heads/main".to_vec()))),
        )
        .expect_err("a held reference lock is a backend failure");

        assert_eq!(error.code, ErrorCode::BackendError);
        assert!(!destination.join("refs/heads/main").exists());
    }
}
