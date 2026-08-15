//! Local repository object database backed by gitoxide plumbing.
//!
//! Only repository metadata and object storage are opened. Worktree files are
//! never consulted.

use crate::budget::Budget;
use crate::error::{Error, ErrorCode};
use crate::object::{HashKind, ObjectHeader, ObjectKind, Oid};
use crate::odb::ObjectDb;
use crate::verify::{verify, ContentHasher};
use std::ffi::OsStr;
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};

const INTEGRITY_CHECK_INTERVAL_CHUNKS: usize = 16;

/// Repository storage facts discovered while opening a local ODB.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RepositoryLayout {
    /// Whether the supplied repository is bare.
    pub bare: bool,
    /// Hash algorithm declared by the repository configuration.
    pub object_hash: HashKind,
}

/// Options controlling how a local object database is opened.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LocalOdbOptions {
    /// Verify every pack, index, and multi-pack-index checksum before the first
    /// object read after open or refresh.
    ///
    /// This deep scan is disabled by default. Per-object [`verify`] already
    /// guarantees that every returned payload is exactly the content addressed
    /// by its OID. Whole-file pack checksums matter when bytes cross a trust
    /// boundary (for example remote fetch or bundle load), and those paths
    /// verify at acquisition time; for local opens this is an optional,
    /// cancellable, budget-accounted deep check.
    pub verify_pack_checksums: bool,
}

/// A read-only local object database supporting loose objects, packs,
/// multi-pack indices, and alternates.
///
/// The pinned gitoxide release can open SHA-256 object stores when its
/// `sha256` feature is enabled, so [`LocalOdb::open`] succeeds for them and
/// reports [`HashKind::Sha256`]. Snapshot creation remains responsible for
/// the Milestone 1 execution refusal.
pub struct LocalOdb {
    hash: HashKind,
    objects: PathBuf,
    store: RwLock<Arc<gix_odb::Store>>,
    object_dirs: RwLock<Vec<PathBuf>>,
    verify_pack_checksums: bool,
    integrity: Mutex<Option<Result<(), Error>>>,
}

impl std::fmt::Debug for LocalOdb {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LocalOdb")
            .field("hash", &self.hash)
            .field(
                "object_directories",
                &self.object_dirs.read().map_or(0, |paths| paths.len()),
            )
            .field("verify_pack_checksums", &self.verify_pack_checksums)
            .finish_non_exhaustive()
    }
}

impl LocalOdb {
    /// Opens a bare repository directory or a normal repository through its
    /// `.git` directory, returning the store and discovered layout.
    pub fn open(
        path: impl AsRef<Path>,
        options: LocalOdbOptions,
    ) -> Result<(Self, RepositoryLayout), Error> {
        let (git_dir, bare_hint) = locate_git_dir(path.as_ref())?;
        let config = load_config(&git_dir)?;
        let hash = object_hash_from_config(&config)?;
        let bare = bare_hint.unwrap_or_else(|| bare_from_config(&config).unwrap_or(true));
        let objects = git_dir.join("objects");
        if !objects.is_dir() {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "local repository has no object directory",
            ));
        }

        let (store, object_dirs) = open_dynamic_store(&objects, hash)?;

        let layout = RepositoryLayout {
            bare,
            object_hash: hash,
        };
        Ok((
            Self {
                hash,
                objects,
                store: RwLock::new(store),
                object_dirs: RwLock::new(object_dirs),
                verify_pack_checksums: options.verify_pack_checksums,
                integrity: Mutex::new(None),
            },
            layout,
        ))
    }

    /// Opens an object directory directly, without requiring a repository
    /// skeleton, configuration, refs, or a fabricated `HEAD`.
    ///
    /// This is the acquisition seam used by [`crate::packfetch::PackFetchOdb`]:
    /// hydrated files live below `<destination>/objects/pack`, and the hash
    /// algorithm is already authenticated by the decoded pack manifest.
    pub fn open_objects_dir(
        objects: impl AsRef<Path>,
        hash: HashKind,
        options: LocalOdbOptions,
    ) -> Result<Self, Error> {
        let objects = objects.as_ref().to_path_buf();
        if !objects.is_dir() {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "local object database path is not a directory",
            ));
        }

        let (store, object_dirs) = open_dynamic_store(&objects, hash)?;

        Ok(Self {
            hash,
            objects,
            store: RwLock::new(store),
            object_dirs: RwLock::new(object_dirs),
            verify_pack_checksums: options.verify_pack_checksums,
            integrity: Mutex::new(None),
        })
    }

    fn read_prologue(&self, oid: &Oid, budget: &Budget) -> Result<(), Error> {
        budget.check()?;
        ensure_hash(self.hash, oid)?;
        if self.verify_pack_checksums {
            self.check_pack_integrity(budget)?;
        }
        Ok(())
    }

    fn check_pack_integrity(&self, budget: &Budget) -> Result<(), Error> {
        budget.check()?;
        let mut cached = self.integrity.lock().map_err(|_| {
            Error::new(
                ErrorCode::InternalError,
                "local object database integrity state is unavailable",
            )
        })?;
        budget.check()?;
        if let Some(result) = cached.as_ref() {
            return result.clone();
        }

        let object_dirs = self.object_dirs.read().map_err(|_| {
            Error::new(
                ErrorCode::InternalError,
                "local object database paths are unavailable",
            )
        })?;
        let result = verify_pack_files(&object_dirs, self.hash, budget);
        let transient_budget_failure = matches!(
            result.as_ref().err().map(|error| error.code),
            Some(ErrorCode::Cancelled | ErrorCode::Timeout | ErrorCode::BudgetExceeded)
        );
        if !transient_budget_failure {
            *cached = Some(result.clone());
        }
        result
    }
}

impl ObjectDb for LocalOdb {
    fn hash_kind(&self) -> HashKind {
        self.hash
    }

    fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
        self.read_prologue(oid, budget)?;
        budget.charge_header()?;
        let engine_oid = to_gix_oid(oid)?;
        let store = self.store.read().map_err(|_| store_lock_error())?.clone();
        let handle = store.to_handle_arc();
        let header = gix_object::FindHeader::try_header(&handle, engine_oid.as_ref())
            .map_err(map_find_error)?;
        Ok(header.map(|header| ObjectHeader {
            kind: from_gix_kind(header.kind),
            size: header.size,
        }))
    }

    fn try_find(
        &self,
        oid: &Oid,
        out: &mut Vec<u8>,
        budget: &Budget,
    ) -> Result<Option<ObjectKind>, Error> {
        out.clear();
        self.read_prologue(oid, budget)?;

        let engine_oid = to_gix_oid(oid)?;
        let store = self.store.read().map_err(|_| store_lock_error())?.clone();
        let handle = store.to_handle_arc();
        let Some(header) = gix_object::FindHeader::try_header(&handle, engine_oid.as_ref())
            .map_err(map_find_error)?
        else {
            return Ok(None);
        };
        // M2/M5: gix exposes the final header here, but not the delta depth or
        // inflated sizes of bases it consumed. Enforcing max_delta_depth and
        // charging base inflation activates when the M5 reader owns traversal;
        // until then gix's internal recursion limit guards the chain and only
        // the final inflated object is charged.
        budget.charge_object(header.size)?;

        let data = match gix_object::Find::try_find(&handle, engine_oid.as_ref(), out) {
            Ok(Some(data)) => data,
            Ok(None) => {
                out.clear();
                return Err(Error::new(
                    ErrorCode::MalformedObject,
                    "object disappeared between local header and payload reads",
                ));
            }
            Err(error) => {
                out.clear();
                return Err(map_find_error(error));
            }
        };
        let kind = from_gix_kind(data.kind);
        if data.data.len() as u64 != header.size || data.kind != header.kind {
            out.clear();
            return Err(Error::new(
                ErrorCode::MalformedObject,
                "local object header does not match its inflated payload",
            ));
        }
        if let Err(error) = verify(oid, kind, data.data) {
            out.clear();
            return Err(error);
        }
        Ok(Some(kind))
    }

    fn refresh(&self, budget: &Budget) -> Result<(), Error> {
        budget.check()?;
        let (store, object_dirs) = open_dynamic_store(&self.objects, self.hash)?;
        *self.store.write().map_err(|_| store_lock_error())? = store;
        *self.object_dirs.write().map_err(|_| store_lock_error())? = object_dirs;
        let mut cached = self.integrity.lock().map_err(|_| {
            Error::new(
                ErrorCode::InternalError,
                "local object database integrity state is unavailable",
            )
        })?;
        *cached = None;
        Ok(())
    }
}

fn open_dynamic_store(
    objects: &Path,
    hash: HashKind,
) -> Result<(Arc<gix_odb::Store>, Vec<PathBuf>), Error> {
    let mut replacements = std::iter::empty::<(gix_hash::ObjectId, gix_hash::ObjectId)>();
    let store = gix_odb::Store::at_opts(
        objects.to_path_buf(),
        &mut replacements,
        gix_odb::store::init::Options {
            object_hash: to_gix_hash(hash),
            ..gix_odb::store::init::Options::default()
        },
    )
    .map_err(|_| {
        Error::new(
            ErrorCode::BackendError,
            "could not open local object database",
        )
    })?;
    let mut object_dirs = vec![objects.to_path_buf()];
    object_dirs.extend(store.alternate_db_paths().map_err(|_| {
        Error::new(
            ErrorCode::BackendError,
            "could not resolve local object database alternates",
        )
    })?);
    Ok((Arc::new(store), object_dirs))
}

fn store_lock_error() -> Error {
    Error::new(
        ErrorCode::InternalError,
        "local object database store is unavailable",
    )
}

fn verify_pack_files(
    object_dirs: &[PathBuf],
    hash: HashKind,
    budget: &Budget,
) -> Result<(), Error> {
    let mut files = Vec::new();
    for object_dir in object_dirs {
        budget.check()?;
        let pack_dir = object_dir.join("pack");
        let entries = match std::fs::read_dir(pack_dir) {
            Ok(entries) => entries,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => {
                return Err(Error::new(
                    ErrorCode::BackendError,
                    "could not inspect local pack directory",
                ));
            }
        };
        for entry in entries {
            let entry = entry.map_err(|_| {
                Error::new(
                    ErrorCode::BackendError,
                    "could not inspect local pack directory",
                )
            })?;
            let path = entry.path();
            let file_name = path.file_name();
            let extension = path.extension();
            if extension == Some(OsStr::new("pack")) {
                files.push((path, ErrorCode::PackChecksumMismatch));
            } else if extension == Some(OsStr::new("idx"))
                || file_name == Some(OsStr::new("multi-pack-index"))
            {
                files.push((path, ErrorCode::IndexChecksumMismatch));
            }
        }
    }
    files.sort_by(|left, right| left.0.cmp(&right.0));
    for (path, code) in files {
        verify_file_checksum(&path, hash, code, budget)?;
    }
    Ok(())
}

fn verify_file_checksum(
    path: &Path,
    hash: HashKind,
    mismatch_code: ErrorCode,
    budget: &Budget,
) -> Result<(), Error> {
    let mut file = File::open(path).map_err(|_| checksum_read_failure(mismatch_code))?;
    let len = file
        .metadata()
        .map_err(|_| checksum_read_failure(mismatch_code))?
        .len();
    let digest_len = hash.digest_len() as u64;
    if len < digest_len {
        return Err(checksum_mismatch(mismatch_code));
    }

    let mut hasher = ContentHasher::new(hash);
    let mut remaining = len - digest_len;
    let mut buffer = [0u8; 64 * 1024];
    let mut chunks = 0usize;
    while remaining > 0 {
        if chunks % INTEGRITY_CHECK_INTERVAL_CHUNKS == 0 {
            budget.check()?;
        }
        let wanted = usize::try_from(remaining.min(buffer.len() as u64))
            .map_err(|_| checksum_read_failure(mismatch_code))?;
        file.read_exact(&mut buffer[..wanted])
            .map_err(|_| checksum_read_failure(mismatch_code))?;
        budget.charge_integrity_bytes(wanted as u64)?;
        hasher.update(&buffer[..wanted]);
        remaining -= wanted as u64;
        chunks += 1;
    }
    let mut expected = vec![0u8; hash.digest_len()];
    budget.check()?;
    file.read_exact(&mut expected)
        .map_err(|_| checksum_read_failure(mismatch_code))?;
    budget.charge_integrity_bytes(digest_len)?;
    let actual = hasher
        .finalize()
        .map_err(|_| checksum_collision(mismatch_code))?;
    if actual.as_bytes() != expected {
        return Err(checksum_mismatch(mismatch_code));
    }
    Ok(())
}

fn checksum_read_failure(code: ErrorCode) -> Error {
    let message = match code {
        ErrorCode::PackChecksumMismatch => "could not read local pack checksum",
        ErrorCode::IndexChecksumMismatch => "could not read local index checksum",
        _ => "could not read local object database checksum",
    };
    Error::new(code, message)
}

fn checksum_mismatch(code: ErrorCode) -> Error {
    let message = match code {
        ErrorCode::PackChecksumMismatch => "local pack checksum does not match",
        ErrorCode::IndexChecksumMismatch => "local index checksum does not match",
        _ => "local object database checksum does not match",
    };
    Error::new(code, message)
}

fn checksum_collision(code: ErrorCode) -> Error {
    let message = match code {
        ErrorCode::PackChecksumMismatch => {
            "SHA-1 collision detected while verifying a local pack checksum"
        }
        ErrorCode::IndexChecksumMismatch => {
            "SHA-1 collision detected while verifying a local index checksum"
        }
        _ => "SHA-1 collision detected while verifying local object database checksums",
    };
    Error::new(code, message)
}

fn locate_git_dir(path: &Path) -> Result<(PathBuf, Option<bool>), Error> {
    if !path.is_dir() {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "local repository path is not a directory",
        ));
    }
    let dot_git = path.join(".git");
    if dot_git.is_dir() {
        return Ok((dot_git, Some(false)));
    }
    if dot_git.is_file() {
        let marker = std::fs::read(&dot_git).map_err(|_| {
            Error::new(
                ErrorCode::InvalidArgument,
                "could not read local repository gitdir marker",
            )
        })?;
        if marker.len() > 4096 {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "local repository gitdir marker is too large",
            ));
        }
        let value = trim_ascii(&marker)
            .strip_prefix(b"gitdir:")
            .map(trim_ascii)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                Error::new(
                    ErrorCode::InvalidArgument,
                    "local repository gitdir marker is malformed",
                )
            })?;
        let value = std::str::from_utf8(value).map_err(|_| {
            Error::new(
                ErrorCode::InvalidArgument,
                "local repository gitdir marker is not UTF-8",
            )
        })?;
        let git_dir = PathBuf::from(value);
        return Ok((
            if git_dir.is_absolute() {
                git_dir
            } else {
                path.join(git_dir)
            },
            Some(false),
        ));
    }
    if path.join("HEAD").is_file() && path.join("objects").is_dir() {
        return Ok((path.to_path_buf(), None));
    }
    Err(Error::new(
        ErrorCode::InvalidArgument,
        "path is not a bare or normal Git repository",
    ))
}

fn load_config(git_dir: &Path) -> Result<gix_config::File, Error> {
    let config_path = git_dir.join("config");
    let metadata = gix_config::file::Metadata::from(gix_config::Source::Local).at(config_path);
    let options = gix_config::file::init::Options {
        includes: gix_config::file::includes::Options::follow_without_conditional(None),
        lossy: true,
        ignore_io_errors: false,
    };
    gix_config::File::from_paths_metadata([metadata], options)
        .map_err(|_| {
            Error::new(
                ErrorCode::InvalidArgument,
                "could not read local repository configuration",
            )
        })?
        .ok_or_else(|| {
            Error::new(
                ErrorCode::InvalidArgument,
                "local repository configuration is missing",
            )
        })
}

fn object_hash_from_config(config: &gix_config::File) -> Result<HashKind, Error> {
    let repository_format = config
        .integer_by("core", None, "repositoryFormatVersion")
        .map_err(|_| {
            Error::new(
                ErrorCode::InvalidArgument,
                "local repository format version is malformed",
            )
        })?
        .unwrap_or(0);
    if repository_format > 1 {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "local repository format version is unsupported",
        ));
    }
    if repository_format < 1 {
        return Ok(HashKind::Sha1);
    }

    let Ok(value) = config.raw_value_by("extensions", None, "objectFormat") else {
        return Ok(HashKind::Sha1);
    };
    let value: &[u8] = value.as_ref();
    match value {
        value if value.eq_ignore_ascii_case(b"sha1") => Ok(HashKind::Sha1),
        value if value.eq_ignore_ascii_case(b"sha256") => Ok(HashKind::Sha256),
        _ => Err(Error::new(
            ErrorCode::UnsupportedHash,
            "local repository uses an unsupported object hash",
        )),
    }
}

fn bare_from_config(config: &gix_config::File) -> Option<bool> {
    config.boolean_by("core", None, "bare").ok().flatten()
}

fn trim_ascii(mut bytes: &[u8]) -> &[u8] {
    while bytes.first().is_some_and(u8::is_ascii_whitespace) {
        bytes = &bytes[1..];
    }
    while bytes.last().is_some_and(u8::is_ascii_whitespace) {
        bytes = &bytes[..bytes.len() - 1];
    }
    bytes
}

fn ensure_hash(expected: HashKind, oid: &Oid) -> Result<(), Error> {
    if oid.kind() != expected {
        return Err(Error::new(
            ErrorCode::InvalidOid,
            format!(
                "object ID uses {:?}, but the object store uses {:?}",
                oid.kind(),
                expected
            ),
        ));
    }
    Ok(())
}

fn to_gix_hash(kind: HashKind) -> gix_hash::Kind {
    match kind {
        HashKind::Sha1 => gix_hash::Kind::Sha1,
        HashKind::Sha256 => gix_hash::Kind::Sha256,
    }
}

fn to_gix_oid(oid: &Oid) -> Result<gix_hash::ObjectId, Error> {
    gix_hash::ObjectId::try_from(oid.as_bytes()).map_err(|_| {
        Error::new(
            ErrorCode::InvalidOid,
            "object ID cannot be represented by the local object engine",
        )
    })
}

fn from_gix_kind(kind: gix_object::Kind) -> ObjectKind {
    match kind {
        gix_object::Kind::Commit => ObjectKind::Commit,
        gix_object::Kind::Tree => ObjectKind::Tree,
        gix_object::Kind::Blob => ObjectKind::Blob,
        gix_object::Kind::Tag => ObjectKind::Tag,
    }
}

fn map_find_error(error: gix_object::find::Error) -> Error {
    if let Ok(error) = error.downcast::<gix_odb::store::find::Error>() {
        if matches!(
            error.as_ref(),
            gix_odb::store::find::Error::LoadPack(_) | gix_odb::store::find::Error::LoadIndex(_)
        ) {
            return Error::retryable(ErrorCode::BackendError, "local object store I/O failure");
        }
        let message = match error.as_ref() {
            gix_odb::store::find::Error::Loose(_) => "local loose object is malformed",
            gix_odb::store::find::Error::Pack(_)
            | gix_odb::store::find::Error::EntryType(_)
            | gix_odb::store::find::Error::DeltaBaseRecursionLimit { .. }
            | gix_odb::store::find::Error::DeltaBaseMissing { .. }
            | gix_odb::store::find::Error::DeltaBaseLookup { .. } => {
                "local packed object is malformed"
            }
            gix_odb::store::find::Error::LoadPack(_)
            | gix_odb::store::find::Error::LoadIndex(_) => unreachable!("mapped above"),
        };
        return Error::new(ErrorCode::MalformedObject, message);
    }
    Error::new(
        ErrorCode::MalformedObject,
        "local object database returned malformed data",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::budget::BudgetLimits;
    use crate::test_support::{fixture_oid, fixture_repo};
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

    static TEMP_REPO_ID: AtomicU64 = AtomicU64::new(0);

    struct TempRepo(PathBuf);

    impl TempRepo {
        fn new(config: &[u8], included: Option<&[u8]>) -> Self {
            let id = TEMP_REPO_ID.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("gitility-config-repo-{}-{id}", std::process::id()));
            std::fs::create_dir_all(path.join("objects"))
                .expect("temporary object directory is created");
            std::fs::write(path.join("HEAD"), b"ref: refs/heads/main\n")
                .expect("temporary HEAD is written");
            std::fs::write(path.join("config"), config)
                .expect("temporary repository config is written");
            if let Some(included) = included {
                std::fs::write(path.join("included.conf"), included)
                    .expect("included repository config is written");
            }
            Self(path)
        }
    }

    impl Drop for TempRepo {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).expect("temporary repository is removed");
        }
    }

    fn read(store: &LocalOdb, oid: &Oid) -> Result<(ObjectKind, Vec<u8>), Error> {
        let mut out = Vec::new();
        let kind = store
            .try_find(oid, &mut out, &Budget::unlimited())?
            .ok_or_else(|| Error::new(ErrorCode::MissingObject, "fixture object is missing"))?;
        Ok((kind, out))
    }

    fn open(path: impl AsRef<Path>) -> Result<(LocalOdb, RepositoryLayout), Error> {
        LocalOdb::open(path, LocalOdbOptions::default())
    }

    fn open_verified(path: impl AsRef<Path>) -> Result<(LocalOdb, RepositoryLayout), Error> {
        LocalOdb::open(
            path,
            LocalOdbOptions {
                verify_pack_checksums: true,
            },
        )
    }

    #[test]
    fn opens_bare_and_normal_layouts_without_worktree_reads() {
        let bare_repo = fixture_repo("sha1-basic.git");
        let (_, layout) = open(&bare_repo).expect("bare fixture opens");
        assert_eq!(
            layout,
            RepositoryLayout {
                bare: true,
                object_hash: HashKind::Sha1
            }
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            use std::time::{SystemTime, UNIX_EPOCH};

            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock is after epoch")
                .as_nanos();
            let worktree = std::env::temp_dir().join(format!(
                "gitility-normal-repo-{}-{nonce}",
                std::process::id()
            ));
            std::fs::create_dir(&worktree).expect("temporary worktree directory is created");
            symlink(&bare_repo, worktree.join(".git")).expect(".git link is created");
            std::fs::write(worktree.join("untracked-secret"), b"must not be read")
                .expect("worktree sentinel is created");

            let (normal, layout) = open(&worktree).expect("normal fixture opens");
            assert!(!layout.bare);
            assert_eq!(
                read(&normal, &fixture_oid("sha1_basic_head"))
                    .expect("normal repository object reads")
                    .0,
                ObjectKind::Commit
            );
            std::fs::remove_dir_all(&worktree).expect("temporary worktree is removed");
        }
    }

    #[test]
    fn reads_loose_packed_midx_and_alternate_layouts() {
        let head = fixture_oid("sha1_basic_head");
        let (loose, _) = open(fixture_repo("sha1-basic.git")).expect("loose fixture opens");
        let (packed, _) =
            open(fixture_repo("sha1-basic-packed.git")).expect("packed fixture opens");
        let (alternate, _) =
            open(fixture_repo("sha1-alternate.git")).expect("alternate fixture opens");
        let expected = read(&loose, &head).expect("loose commit reads");
        assert_eq!(read(&packed, &head).expect("packed commit reads"), expected);
        assert_eq!(
            read(&alternate, &head).expect("alternate commit reads"),
            expected
        );

        let history_head = fixture_oid("sha1_history_head");
        let (history, _) = open(fixture_repo("sha1-history.git")).expect("history fixture opens");
        let (midx, _) = open(fixture_repo("sha1-history-midx.git")).expect("MIDX fixture opens");
        assert_eq!(
            read(&midx, &history_head).expect("MIDX commit reads"),
            read(&history, &history_head).expect("source history commit reads")
        );
        assert_eq!(
            read(&midx, &fixture_oid("midx_probe"))
                .expect("MIDX-only probe reads")
                .0,
            ObjectKind::Blob
        );
    }

    #[test]
    fn opens_an_objects_directory_without_repository_skeleton() {
        let repository = fixture_repo("sha1-basic-packed.git");
        let store = LocalOdb::open_objects_dir(
            repository.join("objects"),
            HashKind::Sha1,
            LocalOdbOptions::default(),
        )
        .expect("objects-only store opens");
        assert_eq!(
            read(&store, &fixture_oid("sha1_basic_head"))
                .expect("objects-only packed commit reads")
                .0,
            ObjectKind::Commit
        );
    }

    #[test]
    fn refresh_reopens_the_pack_inventory_without_disrupting_existing_reads() {
        let repository = TempRepo::new(
            b"[core]\n\tbare = true\n\trepositoryFormatVersion = 0\n",
            None,
        );
        let destination = repository.0.join("objects/pack");
        std::fs::create_dir_all(&destination).expect("pack directory is created");
        copy_pack_pairs(&fixture_repo("sha1-basic-packed.git"), &destination);

        let (store, _) = open(&repository.0).expect("initial pack inventory opens");
        assert_eq!(
            read(&store, &fixture_oid("sha1_basic_head"))
                .expect("initial object remains readable")
                .0,
            ObjectKind::Commit
        );

        copy_pack_pairs(&fixture_repo("sha1-history-midx.git"), &destination);
        store
            .refresh(&Budget::unlimited())
            .expect("refresh swaps in the enlarged pack inventory");
        assert_eq!(
            read(&store, &fixture_oid("sha1_history_head"))
                .expect("newly published pack is readable after refresh")
                .0,
            ObjectKind::Commit
        );
        assert_eq!(
            read(&store, &fixture_oid("sha1_basic_head"))
                .expect("pre-refresh object remains readable")
                .0,
            ObjectKind::Commit
        );
    }

    fn copy_pack_pairs(repository: &Path, destination: &Path) {
        for entry in std::fs::read_dir(repository.join("objects/pack"))
            .expect("fixture pack directory is readable")
        {
            let path = entry.expect("fixture pack entry is readable").path();
            if matches!(
                path.extension().and_then(OsStr::to_str),
                Some("pack" | "idx")
            ) {
                std::fs::copy(
                    &path,
                    destination.join(path.file_name().expect("pack name")),
                )
                .expect("fixture pack artifact is copied");
            }
        }
    }

    #[test]
    fn sha256_repository_opens_and_reports_its_hash() {
        let (store, layout) = open(fixture_repo("sha256-basic.git"))
            .expect("pinned gix-odb supports opening SHA-256");
        assert_eq!(layout.object_hash, HashKind::Sha256);
        assert_eq!(store.hash_kind(), HashKind::Sha256);
        assert_eq!(
            read(&store, &fixture_oid("sha256_basic_head"))
                .expect("SHA-256 loose commit reads and verifies")
                .0,
            ObjectKind::Commit
        );
    }

    #[test]
    fn missing_objects_return_none_and_clear_the_output() {
        let (store, _) = open(fixture_repo("sha1-basic.git")).expect("fixture repository opens");
        let missing = Oid::new(HashKind::Sha1, &[0; 20]).expect("valid ID");
        let mut out = b"stale".to_vec();
        assert!(store
            .try_find(&missing, &mut out, &Budget::unlimited())
            .expect("missing lookup succeeds")
            .is_none());
        assert!(out.is_empty());
    }

    #[test]
    fn corrupt_loose_objects_are_normalized() {
        let oid = fixture_oid("sha1_basic_readme");
        let cases = [
            ("loose-bad-hash.git", ErrorCode::HashMismatch),
            ("loose-malformed-header.git", ErrorCode::MalformedObject),
        ];
        for (name, expected) in cases {
            let (store, _) = open(fixture_repo(&format!("corrupt/{name}")))
                .expect("corrupt fixture still opens");
            let err = read(&store, &oid).expect_err("corrupt loose read fails");
            assert_eq!(err.code, expected, "wrong code for {name}");
        }
    }

    #[test]
    fn corrupt_pack_and_indices_are_normalized() {
        let oid = fixture_oid("sha1_basic_head");
        let cases = [
            ("pack-truncated.git", ErrorCode::PackChecksumMismatch),
            ("pack-bad-checksum.git", ErrorCode::PackChecksumMismatch),
            ("idx-bad-checksum.git", ErrorCode::IndexChecksumMismatch),
        ];
        for (name, expected) in cases {
            let (store, _) = open_verified(fixture_repo(&format!("corrupt/{name}")))
                .expect("corrupt fixture still opens");
            let err = read(&store, &oid).expect_err("corrupt packed read fails");
            assert_eq!(err.code, expected, "wrong code for {name}");
        }
    }

    #[test]
    fn checksum_scan_is_shared_by_header_and_payload_reads_when_enabled() {
        let oid = fixture_oid("sha1_basic_head");
        let cases = [
            ("pack-truncated.git", ErrorCode::PackChecksumMismatch),
            ("pack-bad-checksum.git", ErrorCode::PackChecksumMismatch),
            ("idx-bad-checksum.git", ErrorCode::IndexChecksumMismatch),
        ];
        for (name, expected) in cases {
            for header_only in [true, false] {
                let (store, _) = open_verified(fixture_repo(&format!("corrupt/{name}")))
                    .expect("corrupt fixture still opens");
                let budget = Budget::unlimited();
                let err = if header_only {
                    store
                        .try_header(&oid, &budget)
                        .expect_err("header read runs the checksum gate")
                } else {
                    store
                        .try_find(&oid, &mut Vec::new(), &budget)
                        .expect_err("payload read runs the checksum gate")
                };
                assert_eq!(err.code, expected, "wrong code for {name}");
            }
        }
    }

    #[test]
    fn checksum_scan_is_opt_in_cancellable_and_budget_accounted() {
        let oid = fixture_oid("sha1_basic_head");
        let (unchecked, _) = open(fixture_repo("corrupt/idx-bad-checksum.git"))
            .expect("corrupt repository opens without a deep scan");
        let mut out = Vec::new();
        match unchecked.try_find(&oid, &mut out, &Budget::unlimited()) {
            Ok(Some(kind)) => verify(&oid, kind, &out)
                .expect("an unchecked read may succeed only with verified correct bytes"),
            Ok(None) => panic!("known fixture object must not silently disappear"),
            Err(error) => assert!(
                matches!(
                    error.code,
                    ErrorCode::HashMismatch | ErrorCode::MalformedObject | ErrorCode::BackendError
                ),
                "unchecked failure must be per-object, got {error:?}"
            ),
        }

        let (bounded, _) =
            open_verified(fixture_repo("sha1-basic-packed.git")).expect("packed repository opens");
        let budget = Budget::new(
            BudgetLimits {
                max_total_object_bytes: 1,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let err = bounded
            .try_header(&oid, &budget)
            .expect_err("checksum bytes consume the total byte budget");
        assert_eq!(err.code, ErrorCode::BudgetExceeded);
        assert!(budget.spent().1 > 0);

        let cancelled = Arc::new(AtomicBool::new(true));
        let budget = Budget::new(BudgetLimits::default(), None, cancelled);
        let (cancelled_store, _) =
            open_verified(fixture_repo("sha1-basic-packed.git")).expect("packed repository opens");
        assert_eq!(
            cancelled_store
                .try_header(&oid, &budget)
                .expect_err("cancelled checksum scan stops")
                .code,
            ErrorCode::Cancelled
        );
    }

    #[test]
    fn unchecked_corrupt_packs_never_return_wrong_bytes() {
        for name in [
            "pack-truncated.git",
            "pack-bad-checksum.git",
            "idx-bad-checksum.git",
        ] {
            let oid = fixture_oid("sha1_basic_head");
            let (store, _) = open(fixture_repo(&format!("corrupt/{name}")))
                .expect("corrupt fixture still opens");
            let mut out = Vec::new();
            match store.try_find(&oid, &mut out, &Budget::unlimited()) {
                Ok(Some(kind)) => verify(&oid, kind, &out)
                    .expect("successful unchecked read returns addressed bytes"),
                Ok(None) => panic!("known object must not silently disappear for {name}"),
                Err(error) => assert!(
                    matches!(
                        error.code,
                        ErrorCode::HashMismatch
                            | ErrorCode::MalformedObject
                            | ErrorCode::BackendError
                    ),
                    "{name} must fail at the per-object layer, got {error:?}"
                ),
            }
        }
    }

    #[test]
    fn valid_trailers_do_not_hide_corrupt_pack_entry_data() {
        let oid = fixture_oid("pack_body_corrupt_oid");
        let fixture = fixture_repo("corrupt/pack-body-corrupt-valid-checksums.git");
        for verify_pack_checksums in [false, true] {
            let (store, _) = LocalOdb::open(
                &fixture,
                LocalOdbOptions {
                    verify_pack_checksums,
                },
            )
            .expect("body-corrupt fixture still opens");
            let err = read(&store, &oid).expect_err("damaged entry must not return bytes");
            assert!(
                matches!(
                    err.code,
                    ErrorCode::HashMismatch | ErrorCode::MalformedObject
                ),
                "damaged entry must fail verification or decoding, got {err:?}"
            );
        }
    }

    #[test]
    fn git_config_resolution_is_last_wins_subsection_aware_and_include_aware() {
        let last_wins = TempRepo::new(
            b"[core]\n\tbare = true\n\trepositoryFormatVersion = 1\n[extensions]\n\tobjectFormat = sha1\n[extensions]\n\tobjectFormat = sha256\n",
            None,
        );
        assert_eq!(
            open(&last_wins.0)
                .expect("duplicate extension blocks resolve")
                .1
                .object_hash,
            HashKind::Sha256
        );

        let decoy = TempRepo::new(
            b"[core]\n\tbare = true\n\trepositoryFormatVersion = 1\n[extensions \"decoy\"]\n\tobjectFormat = sha256\n",
            None,
        );
        assert_eq!(
            open(&decoy.0)
                .expect("extension subsection is ignored")
                .1
                .object_hash,
            HashKind::Sha1
        );

        let included = TempRepo::new(
            b"[core]\n\tbare = true\n[include]\n\tpath = included.conf\n",
            Some(b"[core]\n\trepositoryFormatVersion = 1\n[extensions]\n\tobjectFormat = sha256\n"),
        );
        assert_eq!(
            open(&included.0)
                .expect("relative include is honored")
                .1
                .object_hash,
            HashKind::Sha256
        );
    }

    #[test]
    fn gix_pack_and_index_load_io_errors_are_retryable_backend_failures() {
        let pack: gix_object::find::Error = Box::new(gix_odb::store::find::Error::LoadPack(
            std::io::Error::other("probe"),
        ));
        let index: gix_object::find::Error = Box::new(gix_odb::store::find::Error::LoadIndex(
            std::io::Error::other("probe").into(),
        ));
        for error in [map_find_error(pack), map_find_error(index)] {
            assert_eq!(error.code, ErrorCode::BackendError);
            assert_eq!(error.message, "local object store I/O failure");
            assert!(error.retryable);
        }
    }

    #[test]
    fn total_byte_budget_stops_before_payload_inflation() {
        let (store, _) = open(fixture_repo("sha1-basic.git")).expect("fixture repository opens");
        let budget = Budget::new(
            BudgetLimits {
                max_total_object_bytes: 1,
                ..BudgetLimits::default()
            },
            None,
            Arc::new(AtomicBool::new(false)),
        );
        let err = store
            .try_find(&fixture_oid("sha1_basic_readme"), &mut Vec::new(), &budget)
            .expect_err("tiny byte budget stops read");
        assert_eq!(err.code, ErrorCode::BudgetExceeded);
    }

    #[test]
    fn rejects_an_oid_from_another_algorithm_without_calling_gix() {
        let (store, _) = open(fixture_repo("sha1-basic.git")).expect("fixture repository opens");
        let wrong = Oid::new(HashKind::Sha256, &[0; 32]).expect("valid SHA-256 ID");
        let err = store
            .try_find(&wrong, &mut Vec::new(), &Budget::unlimited())
            .expect_err("algorithm mismatch fails");
        assert_eq!(err.code, ErrorCode::InvalidOid);
    }
}
