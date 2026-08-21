//! Native smart-HTTP fetch into a local bare repository.
//!
//! This is deliberately the only write path in the core crate. Query stores
//! remain read-only. Fetch uses gix's blocking reqwest/rustls transport on a
//! runtime worker and reserves the dependency threads it may create from the
//! same process-wide thread budget as Gitility's own runtime threads.

use crate::repo_admin::init_bare_repo;
use crate::runtime::thread_budget;
use crate::{Budget, Error, ErrorCode};
use bstr::{BStr, BString, ByteSlice};
use gix_ref::transaction::{Change, PreviousValue, RefEdit, RefLog};
use gix_ref::Target;
use std::any::Any;
use std::collections::{BTreeMap, BTreeSet};
use std::error::Error as StdError;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

const TRANSPORT_THREAD_SLOTS: usize = 3;

/// A validated request owned by a runtime job.
///
/// This type intentionally implements neither `Debug` nor `Display`: its
/// authorization field must never be formatted.
pub struct FetchRequest {
    pub dest: PathBuf,
    pub url: String,
    pub refspecs: Vec<String>,
    pub authorization: Option<String>,
    pub prune: bool,
}

/// The kind of successful reference update.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FetchAction {
    Created,
    FastForward,
    Forced,
}

/// A successful reference update.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchUpdatedRef {
    pub name: String,
    pub action: FetchAction,
    pub old_oid: Option<String>,
    pub new_oid: String,
}

/// A stable reason why a mapped reference was not updated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FetchRejection {
    SourceObjectNotFound,
    TagUpdate,
    NonFastForward,
    ReplaceWithUnborn,
    CurrentlyCheckedOut,
}

/// A rejected reference update. Rejections do not fail the fetch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchRejectedRef {
    pub name: String,
    pub reason: FetchRejection,
}

/// Stable fetch result returned through the NIF.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchResult {
    pub updated_refs: Vec<FetchUpdatedRef>,
    pub rejected_refs: Vec<FetchRejectedRef>,
    pub pruned_refs: Vec<String>,
    pub remote_ref_count: usize,
    pub pack_received: bool,
}

/// Validate the portions whose grammar is owned by gix before job admission.
///
/// Caller-side Elixir validation handles types, sizes, schemes, and header
/// bytes. This backstop parses every refspec synchronously at NIF submission
/// and enforces the observable-destination requirement.
pub fn validate_request(request: &FetchRequest) -> Result<(), Error> {
    if request.refspecs.is_empty() {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "fetch requires at least one refspec",
        ));
    }

    for raw in &request.refspecs {
        let parsed =
            gix_refspec::parse(raw.as_bytes().into(), gix_refspec::parse::Operation::Fetch)
                .map_err(|_| {
                    Error::new(
                        ErrorCode::InvalidArgument,
                        format!("invalid fetch refspec: {raw}"),
                    )
                })?;
        if parsed.destination().is_none() {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                format!("fetch refspec must have a destination: {raw}"),
            ));
        }
    }
    Ok(())
}

/// Execute one native fetch on a runtime worker.
pub fn fetch(request: FetchRequest, budget: &Budget) -> Result<FetchResult, Error> {
    validate_request(&request)?;
    budget.check()?;

    let repo = open_or_init_bare(&request.dest)?;
    budget.check()?;

    let remote = repo
        .remote_at_without_url_rewrite(request.url.as_str())
        .map_err(|_| invalid_transport())?
        .with_fetch_tags(gix::remote::fetch::Tags::None);
    let effective_url = remote
        .url(gix::remote::Direction::Fetch)
        .ok_or_else(invalid_transport)?;
    if !matches!(
        effective_url.scheme,
        gix::url::Scheme::Http | gix::url::Scheme::Https
    ) {
        return Err(invalid_transport());
    }
    let remote = remote
        .with_refspecs(
            request
                .refspecs
                .iter()
                .map(|spec| spec.as_bytes().as_bstr()),
            gix::remote::Direction::Fetch,
        )
        .map_err(|_| {
            Error::new(
                ErrorCode::InvalidArgument,
                "one or more fetch refspecs are invalid",
            )
        })?;

    budget.check()?;
    let transport_reservation = thread_budget::global()
        .try_reserve(TRANSPORT_THREAD_SLOTS)
        .map_err(|_| {
            Error::retryable(
                ErrorCode::Busy,
                "native fetch dependency thread budget is exhausted",
            )
        })?;

    let mut connection = remote
        .connect(gix::remote::Direction::Fetch)
        .map_err(|error| map_connect_error(&error, budget))?;
    // The closure's Err type is gix's 192-byte credential protocol error; the
    // shape is mandated (disarming the git-credential cascade) and the Err
    // variant is never constructed.
    #[allow(clippy::result_large_err)]
    connection.set_credentials(|_| Ok(None));
    connection.set_transport_options(transport_options(
        request.authorization.as_deref(),
        budget.deadline(),
    ));

    let prepared = connection
        .prepare_fetch(gix::progress::Discard, Default::default())
        .map_err(|error| map_prepare_error(&error, budget))?;
    check_exact_refspecs(prepared.ref_map())?;
    budget.check()?;

    let outcome = prepared
        .receive(gix::progress::Discard, budget.cancel_flag().as_ref())
        .map_err(|error| map_receive_error(&error, budget))?;

    // Dropping the connection starts asynchronous transport teardown. Releasing
    // these dependency slots is therefore advisory: it honestly bounds steady
    // state, while reqwest/gix pool threads can linger briefly after this point.
    drop(transport_reservation);

    let gix::remote::fetch::Outcome {
        ref_map,
        handshake: _,
        status,
    } = outcome;
    let remote_ref_count = ref_map.remote_refs.len();
    let (pack_received, update_outcome, keep_path) = match status {
        gix::remote::fetch::Status::Change {
            update_refs,
            write_pack_bundle,
            negotiate: _,
        } => (true, update_refs, write_pack_bundle.keep_path),
        gix::remote::fetch::Status::NoPackReceived {
            update_refs,
            dry_run: _,
            negotiate: _,
        } => (false, update_refs, None),
    };

    let (mut updated_refs, mut rejected_refs) = map_updates(&ref_map.mappings, &update_outcome);
    updated_refs.sort_by(|left, right| left.name.as_bytes().cmp(right.name.as_bytes()));
    rejected_refs.sort_by(|left, right| left.name.as_bytes().cmp(right.name.as_bytes()));

    if let Some(path) = keep_path {
        if std::fs::remove_file(&path).is_err() {
            return Err(Error::new(
                ErrorCode::CleanupFailed,
                format!(
                    "fetch committed, but the leftover pack keep file could not be removed: {}",
                    path.display()
                ),
            ));
        }
    }

    let mut pruned_refs = if request.prune {
        prune(&repo, &ref_map).map_err(|_| {
            Error::retryable(
                ErrorCode::CleanupFailed,
                "fetch committed, but the prune reference transaction failed",
            )
        })?
    } else {
        Vec::new()
    };
    pruned_refs.sort_by(|left, right| left.as_bytes().cmp(right.as_bytes()));

    Ok(FetchResult {
        updated_refs,
        rejected_refs,
        pruned_refs,
        remote_ref_count,
        pack_received,
    })
}

fn invalid_transport() -> Error {
    Error::new(
        ErrorCode::InvalidArgument,
        "fetch URL must use the http or https scheme",
    )
}

fn open_or_init_bare(path: &Path) -> Result<gix::Repository, Error> {
    let initialize = match std::fs::read_dir(path) {
        Ok(mut entries) => entries.next().is_none(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
        Err(_) => false,
    };

    let repo = if initialize {
        init_bare_repo(path)?
    } else {
        gix::open_opts(path, gix::open::Options::isolated()).map_err(map_open_error)?
    };

    if !repo.is_bare() {
        return Err(Error::new(
            ErrorCode::InvalidArgument,
            "fetch destination must be a bare repository",
        ));
    }
    Ok(repo)
}

fn map_open_error(error: gix::open::Error) -> Error {
    if matches!(
        &error,
        gix::open::Error::Config(gix::config::Error::ConfigTypedString(inner))
            if inner.key.as_bstr() == "extensions.objectFormat"
    ) {
        Error::new(
            ErrorCode::UnsupportedHash,
            "the destination repository object format is unsupported by native fetch",
        )
    } else {
        Error::new(
            ErrorCode::InvalidArgument,
            "fetch destination is not a Git repository",
        )
    }
}

fn transport_options(authorization: Option<&str>, deadline: Option<Instant>) -> Box<dyn Any> {
    let mut extra_headers = Vec::new();
    if let Some(value) = authorization {
        let mut header = String::from("Authorization: ");
        header.push_str(value);
        extra_headers.push(header);
    }

    let backend: Arc<Mutex<dyn Any + Send + Sync + 'static>> = Arc::new(Mutex::new(
        gix_transport::client::blocking_io::http::reqwest::Options {
            configure_request: Some(Box::new(move |request| {
                *request.timeout_mut() =
                    deadline.map(|deadline| deadline.saturating_duration_since(Instant::now()));
                Ok(())
            })),
        },
    ));

    Box::new(gix_transport::client::blocking_io::http::Options {
        extra_headers,
        backend: Some(backend),
        ..Default::default()
    })
}

fn check_exact_refspecs(ref_map: &gix::remote::fetch::RefMap) -> Result<(), Error> {
    for (index, spec) in ref_map.refspecs.iter().enumerate() {
        let spec_ref = spec.to_ref();
        let Some(source) = spec_ref.source() else {
            continue;
        };
        if contains_glob(source) || gix_hash::ObjectId::from_hex(source).is_ok() {
            continue;
        }
        let matched = ref_map.mappings.iter().any(|mapping| {
            matches!(
                mapping.spec_index,
                gix_protocol::fetch::refmap::SpecIndex::ExplicitInRemote(mapped) if mapped == index
            )
        });
        if !matched {
            // RefMap refspecs are deduplicated, so their indices cannot be
            // used to index the caller's raw list. Render the exact spec that
            // failed from the RefMap itself.
            let shown = spec_ref.to_bstring();
            return Err(Error::new(
                ErrorCode::RefNotFound,
                format!(
                    "fetch refspec did not match a remote reference: {}",
                    shown.to_str_lossy()
                ),
            ));
        }
    }
    Ok(())
}

fn contains_glob(value: &BStr) -> bool {
    value.find_byteset(b"*?[]\\").is_some()
}

fn action_for_mode(mode: &gix::remote::fetch::refs::update::Mode) -> Option<FetchAction> {
    use gix::remote::fetch::refs::update::Mode;
    match mode {
        Mode::New => Some(FetchAction::Created),
        Mode::FastForward => Some(FetchAction::FastForward),
        Mode::Forced => Some(FetchAction::Forced),
        Mode::NoChangeNeeded
        | Mode::ImplicitTagNotSentByRemote
        | Mode::RejectedSourceObjectNotFound { .. }
        | Mode::RejectedTagUpdate
        | Mode::RejectedNonFastForward
        | Mode::RejectedToReplaceWithUnborn
        | Mode::RejectedCurrentlyCheckedOut { .. } => None,
    }
}

fn rejection_for_mode(mode: &gix::remote::fetch::refs::update::Mode) -> Option<FetchRejection> {
    use gix::remote::fetch::refs::update::Mode;
    match mode {
        Mode::RejectedSourceObjectNotFound { .. } => Some(FetchRejection::SourceObjectNotFound),
        Mode::RejectedTagUpdate => Some(FetchRejection::TagUpdate),
        Mode::RejectedNonFastForward => Some(FetchRejection::NonFastForward),
        Mode::RejectedToReplaceWithUnborn => Some(FetchRejection::ReplaceWithUnborn),
        Mode::RejectedCurrentlyCheckedOut { .. } => Some(FetchRejection::CurrentlyCheckedOut),
        Mode::NoChangeNeeded
        | Mode::FastForward
        | Mode::Forced
        | Mode::New
        | Mode::ImplicitTagNotSentByRemote => None,
    }
}

fn map_updates(
    mappings: &[gix_protocol::fetch::refmap::Mapping],
    outcome: &gix::remote::fetch::refs::update::Outcome,
) -> (Vec<FetchUpdatedRef>, Vec<FetchRejectedRef>) {
    let mut updated = Vec::new();
    let mut rejected = Vec::new();

    for (mapping, update) in mappings.iter().zip(outcome.updates.iter()) {
        let Some(name) = mapping.local.as_ref() else {
            continue;
        };
        let name = name.to_str_lossy().into_owned();

        if let Some(action) = action_for_mode(&update.mode) {
            let Some(new_oid) = mapping.remote.as_id() else {
                continue;
            };
            let old_oid = match action {
                // gix represents Mode::New with an expected value equal to
                // the new target. That is transaction machinery, not a
                // pre-existing ref, so the public old_oid contract is nil.
                FetchAction::Created => None,
                FetchAction::FastForward | FetchAction::Forced => update
                    .edit_index
                    .and_then(|index| outcome.edits.get(index))
                    .and_then(|edit| edit.change.previous_value())
                    .and_then(|target| match target {
                        gix_ref::TargetRef::Object(oid) => Some(oid.to_string()),
                        gix_ref::TargetRef::Symbolic(_) => None,
                    }),
            };
            updated.push(FetchUpdatedRef {
                name,
                action,
                old_oid,
                new_oid: new_oid.to_string(),
            });
        } else if let Some(reason) = rejection_for_mode(&update.mode) {
            rejected.push(FetchRejectedRef { name, reason });
        }
    }
    (updated, rejected)
}

struct LocalPruneRef {
    name: BString,
    target: gix_hash::ObjectId,
}

fn prune(repo: &gix::Repository, ref_map: &gix::remote::fetch::RefMap) -> Result<Vec<String>, ()> {
    let (wildcards, protected_exact) = prune_refspecs(&ref_map.refspecs);
    if wildcards.is_empty() {
        return Ok(Vec::new());
    }

    let mut locals = Vec::new();
    let references = repo.references().map_err(|_| ())?;
    for reference in references.all().map_err(|_| ())? {
        let reference = reference.map_err(|_| ())?;
        if let Some(target) = reference.target().try_id() {
            locals.push(LocalPruneRef {
                name: reference.name().as_bstr().to_owned(),
                target: target.to_owned(),
            });
        }
    }

    let advertised: BTreeSet<BString> = ref_map
        .remote_refs
        .iter()
        .map(|remote| remote.unpack().0.to_owned())
        .collect();
    let candidates = prune_candidates(&wildcards, &protected_exact, &locals, &advertised);
    if candidates.is_empty() {
        return Ok(Vec::new());
    }

    let mut edits = Vec::with_capacity(candidates.len());
    let mut names = Vec::with_capacity(candidates.len());
    for (name, target) in candidates {
        let full_name = name.clone().try_into().map_err(|_| ())?;
        edits.push(RefEdit {
            change: Change::Delete {
                expected: PreviousValue::MustExistAndMatch(Target::Object(target)),
                log: RefLog::AndReference,
            },
            name: full_name,
            deref: false,
        });
        names.push(name.to_str_lossy().into_owned());
    }
    repo.edit_references(edits).map_err(|_| ())?;
    Ok(names)
}

fn prune_refspecs(
    refspecs: &[gix_refspec::RefSpec],
) -> (Vec<gix_refspec::RefSpec>, BTreeSet<BString>) {
    let mut wildcards = Vec::new();
    let mut protected_exact = BTreeSet::new();
    for spec in refspecs {
        let spec_ref = spec.to_ref();
        let (Some(source), Some(destination)) = (spec_ref.source(), spec_ref.destination()) else {
            continue;
        };
        if contains_glob(source) {
            wildcards.push(spec.clone());
        } else {
            protected_exact.insert(destination.to_owned());
        }
    }
    (wildcards, protected_exact)
}

fn prune_candidates(
    wildcard_specs: &[gix_refspec::RefSpec],
    protected_exact: &BTreeSet<BString>,
    locals: &[LocalPruneRef],
    advertised: &BTreeSet<BString>,
) -> Vec<(BString, gix_hash::ObjectId)> {
    let items = locals.iter().map(|local| gix_refspec::match_group::Item {
        full_ref_name: local.name.as_bstr(),
        target: local.target.as_ref(),
        object: None,
    });
    let reverse = gix_refspec::MatchGroup::from_fetch_specs(
        wildcard_specs.iter().map(gix_refspec::RefSpec::to_ref),
    )
    .match_rhs(items);

    let by_name: BTreeMap<&BStr, &gix_hash::ObjectId> = locals
        .iter()
        .map(|local| (local.name.as_bstr(), &local.target))
        .collect();
    let mut mapped: BTreeMap<BString, (gix_hash::ObjectId, bool)> = BTreeMap::new();
    for mapping in reverse.mappings {
        let (gix_refspec::match_group::SourceRef::FullName(remote), Some(local)) =
            (mapping.lhs, mapping.rhs)
        else {
            continue;
        };
        if protected_exact.contains(local.as_ref()) {
            continue;
        }
        let Some(target) = by_name.get(local.as_ref()) else {
            continue;
        };
        let remote_present = advertised.contains(remote.as_ref());
        let entry = mapped
            .entry(local.into_owned())
            .or_insert_with(|| ((*target).to_owned(), false));
        entry.1 |= remote_present;
    }

    mapped
        .into_iter()
        .filter_map(|(name, (target, remote_present))| (!remote_present).then_some((name, target)))
        .collect()
}

fn map_connect_error(error: &gix::remote::connect::Error, budget: &Budget) -> Error {
    if let Err(error) = budget.check() {
        return error;
    }
    if connect_error_is_redirect(error) {
        redirect_error()
    } else {
        network_error("fetch connection failed")
    }
}

fn map_prepare_error(error: &gix::remote::fetch::prepare::Error, budget: &Budget) -> Error {
    if let Err(error) = budget.check() {
        return error;
    }

    if let gix::remote::fetch::prepare::Error::RefMap(ref_map_error) = error {
        match ref_map_error {
            gix::remote::ref_map::Error::Handshake(handshake)
                if handshake_error_is_authentication(handshake) =>
            {
                return authentication_error();
            }
            gix::remote::ref_map::Error::InitRefMap(
                gix_protocol::fetch::refmap::init::Error::MappingValidation(validation),
            ) => {
                if let Some(destination) = conflicting_destination(validation) {
                    return Error::new(
                        ErrorCode::InvalidArgument,
                        format!("conflicting fetch refspec destination: {destination}"),
                    );
                }
            }
            gix::remote::ref_map::Error::InitRefMap(
                gix_protocol::fetch::refmap::init::Error::UnknownObjectFormat { .. },
            ) => {
                return Error::new(
                    ErrorCode::UnsupportedHash,
                    "the remote repository object format is unsupported by native fetch",
                );
            }
            _ => {}
        }
    }

    if prepare_error_is_authentication(error) {
        authentication_error()
    } else if prepare_error_is_redirect(error) {
        redirect_error()
    } else {
        network_error("fetch handshake failed")
    }
}

fn map_receive_error(error: &gix::remote::fetch::Error, budget: &Budget) -> Error {
    if let Err(error) = budget.check() {
        return error;
    }
    match error {
        gix::remote::fetch::Error::IncompatibleObjectHash { .. } => Error::new(
            ErrorCode::UnsupportedHash,
            "remote object hash does not match the destination repository",
        ),
        gix::remote::fetch::Error::NoMapping { .. } => Error::new(
            ErrorCode::RefNotFound,
            "none of the fetch refspecs matched a remote reference",
        ),
        gix::remote::fetch::Error::RemovePackKeepFile { path, .. } => Error::new(
            ErrorCode::CleanupFailed,
            format!(
                "fetch committed, but gix could not remove the pack keep file: {}",
                path.display()
            ),
        ),
        gix::remote::fetch::Error::Fetch(gix_protocol::fetch::Error::ConsumePack(source)) => {
            map_pack_error(source.as_ref())
        }
        gix::remote::fetch::Error::Fetch(_) | gix::remote::fetch::Error::Client(_) => {
            if receive_error_is_redirect(error) {
                redirect_error()
            } else {
                network_error("fetch transfer failed")
            }
        }
        gix::remote::fetch::Error::UpdateRefs(_) => Error::new(
            ErrorCode::BackendError,
            "fetch could not apply its reference transaction",
        ),
        _ => Error::new(ErrorCode::BackendError, "native fetch failed"),
    }
}

fn map_pack_error(error: &(dyn StdError + 'static)) -> Error {
    if let Some(bundle) = error.downcast_ref::<gix_pack::bundle::write::Error>() {
        use gix_pack::bundle::write::Error as BundleError;
        match bundle {
            BundleError::PackIter(gix_pack::data::input::Error::Verify(_)) => {
                return Error::new(
                    ErrorCode::PackChecksumMismatch,
                    "received pack checksum did not verify",
                )
            }
            BundleError::PackIter(gix_pack::data::input::Error::PackParse(_))
            | BundleError::PackIter(gix_pack::data::input::Error::IncompletePack { .. })
            | BundleError::PackIter(gix_pack::data::input::Error::NotFound { .. }) => {
                return Error::new(ErrorCode::MalformedObject, "received pack is malformed")
            }
            BundleError::IndexWrite(gix_pack::index::write::Error::PackEntryDecode(
                gix_pack::data::input::Error::Verify(_),
            )) => {
                return Error::new(
                    ErrorCode::PackChecksumMismatch,
                    "received pack checksum did not verify while indexing",
                )
            }
            BundleError::IndexWrite(_) => {
                return Error::new(
                    ErrorCode::MalformedObject,
                    "received pack could not be indexed",
                )
            }
            BundleError::Io(_) | BundleError::Persist(_) | BundleError::PackIter(_) => {}
        }
    }
    Error::retryable(
        ErrorCode::NetworkError,
        "fetch transfer ended before a complete verified pack was received",
    )
}

fn authentication_error() -> Error {
    Error::new(
        ErrorCode::AuthenticationFailed,
        "remote authentication failed",
    )
}

fn conflicting_destination(error: &gix_refspec::match_group::validate::Error) -> Option<String> {
    error
        .issues
        .iter()
        .map(|issue| match issue {
            gix_refspec::match_group::validate::Issue::Conflict {
                destination_full_ref_name,
                ..
            } => destination_full_ref_name.to_str_lossy().into_owned(),
        })
        .next()
}

fn prepare_error_is_authentication(error: &gix::remote::fetch::prepare::Error) -> bool {
    match error {
        gix::remote::fetch::prepare::Error::RefMap(gix::remote::ref_map::Error::Handshake(
            handshake,
        )) => handshake_error_is_authentication(handshake),
        gix::remote::fetch::prepare::Error::RefMap(gix::remote::ref_map::Error::Transport(
            transport,
        )) => transport_error_is_authentication(transport),
        _ => authentication_signal_in_chain(error),
    }
}

fn handshake_error_is_authentication(error: &gix_protocol::handshake::Error) -> bool {
    match error {
        gix_protocol::handshake::Error::Credentials(_)
        | gix_protocol::handshake::Error::EmptyCredentials
        | gix_protocol::handshake::Error::InvalidCredentials { .. } => true,
        gix_protocol::handshake::Error::Transport(transport) => {
            transport_error_is_authentication(transport)
        }
        _ => authentication_signal_in_chain(error),
    }
}

fn transport_error_is_authentication(error: &gix_transport::client::Error) -> bool {
    match error {
        gix_transport::client::Error::Io(io) => {
            io.kind() == std::io::ErrorKind::PermissionDenied || authentication_signal_in_chain(io)
        }
        gix_transport::client::Error::Http(
            gix_transport::client::blocking_io::http::Error::PostBody(io),
        ) => {
            io.kind() == std::io::ErrorKind::PermissionDenied || authentication_signal_in_chain(io)
        }
        _ => authentication_signal_in_chain(error),
    }
}

fn authentication_signal_in_chain(error: &(dyn StdError + 'static)) -> bool {
    let mut current = Some(error);
    while let Some(item) = current {
        if let Some(handshake) = item.downcast_ref::<gix_protocol::handshake::Error>() {
            if matches!(
                handshake,
                gix_protocol::handshake::Error::Credentials(_)
                    | gix_protocol::handshake::Error::EmptyCredentials
                    | gix_protocol::handshake::Error::InvalidCredentials { .. }
            ) {
                return true;
            }
        }
        if item
            .downcast_ref::<std::io::Error>()
            .is_some_and(|io| io.kind() == std::io::ErrorKind::PermissionDenied)
        {
            return true;
        }
        current = item.source();
    }
    false
}

fn network_error(message: &'static str) -> Error {
    Error::retryable(ErrorCode::NetworkError, message)
}

fn redirect_error() -> Error {
    Error::retryable(
        ErrorCode::NetworkError,
        "fetch was redirected, but redirects are not followed",
    )
}

fn connect_error_is_redirect(error: &gix::remote::connect::Error) -> bool {
    match error {
        // gix-transport keeps the concrete connect error module private, but
        // matching this public gix variant still gets past its transparent
        // wrapper before the boxed backend fallback is inspected.
        gix::remote::connect::Error::Connect(source) => redirect_signal_in_chain(source),
        _ => redirect_signal_in_chain(error),
    }
}

fn prepare_error_is_redirect(error: &gix::remote::fetch::prepare::Error) -> bool {
    match error {
        gix::remote::fetch::prepare::Error::RefMap(gix::remote::ref_map::Error::Handshake(
            handshake,
        )) => handshake_error_is_redirect(handshake),
        gix::remote::fetch::prepare::Error::RefMap(gix::remote::ref_map::Error::Transport(
            transport,
        )) => transport_error_is_redirect(transport),
        _ => redirect_signal_in_chain(error),
    }
}

fn handshake_error_is_redirect(error: &gix_protocol::handshake::Error) -> bool {
    match error {
        gix_protocol::handshake::Error::Transport(transport) => {
            transport_error_is_redirect(transport)
        }
        _ => redirect_signal_in_chain(error),
    }
}

fn receive_error_is_redirect(error: &gix::remote::fetch::Error) -> bool {
    match error {
        gix::remote::fetch::Error::Client(transport)
        | gix::remote::fetch::Error::Fetch(gix_protocol::fetch::Error::Client(transport)) => {
            transport_error_is_redirect(transport)
        }
        gix::remote::fetch::Error::Fetch(gix_protocol::fetch::Error::FetchResponse(response)) => {
            match response {
                gix_protocol::fetch::response::Error::Io(io) => io_error_is_redirect(io),
                gix_protocol::fetch::response::Error::Transport(transport) => {
                    transport_error_is_redirect(transport)
                }
                _ => redirect_signal_in_chain(response),
            }
        }
        gix::remote::fetch::Error::Fetch(gix_protocol::fetch::Error::ReadRemainingBytes(io)) => {
            io_error_is_redirect(io)
        }
        _ => redirect_signal_in_chain(error),
    }
}

fn transport_error_is_redirect(error: &gix_transport::client::Error) -> bool {
    match error {
        gix_transport::client::Error::Io(io) => io_error_is_redirect(io),
        gix_transport::client::Error::Http(http) => match http {
            gix_transport::client::blocking_io::http::Error::InitHttpClient { source } => source
                .downcast_ref::<gix_transport::client::blocking_io::http::reqwest::remote::Error>()
                .is_some_and(reqwest_remote_error_is_redirect)
                || redirect_signal_in_chain(source.as_ref()),
            gix_transport::client::blocking_io::http::Error::PostBody(io) => {
                io_error_is_redirect(io)
            }
            _ => redirect_signal_in_chain(http),
        },
        _ => redirect_signal_in_chain(error),
    }
}

fn io_error_is_redirect(error: &std::io::Error) -> bool {
    // std::io::Error::source() forwards to the wrapped error's source and can
    // skip the wrapped reqwest::Error itself. Inspect get_ref() structurally
    // before falling back to a source-chain walk.
    error
        .get_ref()
        .and_then(|source| source.downcast_ref::<reqwest::Error>())
        .is_some_and(reqwest::Error::is_redirect)
        || error
            .get_ref()
            .and_then(|source| {
                source.downcast_ref::<
                    gix_transport::client::blocking_io::http::reqwest::remote::Error,
                >()
            })
            .is_some_and(reqwest_remote_error_is_redirect)
        || redirect_signal_in_chain(error)
}

fn reqwest_remote_error_is_redirect(
    error: &gix_transport::client::blocking_io::http::reqwest::remote::Error,
) -> bool {
    match error {
        gix_transport::client::blocking_io::http::reqwest::remote::Error::Reqwest(error) => {
            error.is_redirect()
        }
        gix_transport::client::blocking_io::http::reqwest::remote::Error::Redirect(_) => true,
        _ => redirect_signal_in_chain(error),
    }
}

/// Fallback for boxed IO/backend errors after all public gix wrapper variants
/// have been matched structurally. Transparent wrappers cannot be recovered by
/// downcasting a `source()` chain, which is why callers must unwrap them first.
fn redirect_signal_in_chain(error: &(dyn StdError + 'static)) -> bool {
    let mut current = Some(error);
    while let Some(item) = current {
        if let Some(io) = item.downcast_ref::<std::io::Error>() {
            if io.get_ref().is_some_and(|source| {
                source
                    .downcast_ref::<reqwest::Error>()
                    .is_some_and(reqwest::Error::is_redirect)
            }) {
                return true;
            }
        }
        if let Some(remote) =
            item.downcast_ref::<gix_transport::client::blocking_io::http::reqwest::remote::Error>()
        {
            if reqwest_remote_error_is_redirect(remote) {
                return true;
            }
        }
        current = item.source();
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    struct RemoveDirectory(PathBuf);

    impl Drop for RemoveDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn oid(byte: u8) -> gix_hash::ObjectId {
        gix_hash::ObjectId::from_bytes_or_panic(&[byte; 20])
    }

    fn spec(value: &str) -> gix_refspec::RefSpec {
        gix_refspec::parse(
            value.as_bytes().into(),
            gix_refspec::parse::Operation::Fetch,
        )
        .expect("valid refspec")
        .to_owned()
    }

    #[test]
    fn only_real_update_modes_are_reported() {
        use gix::remote::fetch::refs::update::Mode;
        assert_eq!(action_for_mode(&Mode::New), Some(FetchAction::Created));
        assert_eq!(
            action_for_mode(&Mode::FastForward),
            Some(FetchAction::FastForward)
        );
        assert_eq!(action_for_mode(&Mode::Forced), Some(FetchAction::Forced));
        assert_eq!(action_for_mode(&Mode::NoChangeNeeded), None);
        assert_eq!(action_for_mode(&Mode::RejectedNonFastForward), None);
    }

    #[test]
    fn prune_reverse_matching_handles_suffixes_overlaps_and_exact_protection() {
        let wildcard_specs = vec![
            spec("refs/heads/*:refs/remotes/origin/*"),
            spec("refs/pull/*/head:refs/pull/*"),
            spec("refs/heads/release/*:refs/remotes/origin/release/*"),
        ];
        let protected_exact = BTreeSet::from([BString::from("refs/remotes/origin/release/pinned")]);
        let locals = vec![
            LocalPruneRef {
                name: "refs/remotes/origin/gone".into(),
                target: oid(1),
            },
            LocalPruneRef {
                name: "refs/pull/17".into(),
                target: oid(2),
            },
            LocalPruneRef {
                name: "refs/remotes/origin/release/kept".into(),
                target: oid(3),
            },
            LocalPruneRef {
                name: "refs/remotes/origin/release/pinned".into(),
                target: oid(4),
            },
        ];
        let advertised = BTreeSet::from([BString::from("refs/heads/release/kept")]);

        let candidates = prune_candidates(&wildcard_specs, &protected_exact, &locals, &advertised);
        let names: Vec<_> = candidates
            .into_iter()
            .map(|(name, _)| name.to_str_lossy().into_owned())
            .collect();

        assert_eq!(
            names,
            vec![
                "refs/pull/17".to_owned(),
                "refs/remotes/origin/gone".to_owned()
            ]
        );
    }

    #[test]
    fn invalid_or_source_only_refspecs_are_rejected_without_auth_formatting() {
        let request = FetchRequest {
            dest: PathBuf::from("unused"),
            url: "https://example.invalid/repo".to_owned(),
            refspecs: vec!["refs/heads/main".to_owned()],
            authorization: Some("Basic must-never-appear".to_owned()),
            prune: false,
        };
        let error = validate_request(&request).expect_err("source-only refspec");
        assert_eq!(error.code, ErrorCode::InvalidArgument);
        assert!(!format!("{error:?}").contains("must-never-appear"));
    }

    #[test]
    fn authentication_and_network_error_signals_map_to_stable_codes() {
        let denied = std::io::Error::new(std::io::ErrorKind::PermissionDenied, "denied");
        assert!(authentication_signal_in_chain(&denied));

        let network = std::io::Error::other("connection failed");
        assert!(!authentication_signal_in_chain(&network));
        let mapped = network_error("fetch connection failed");
        assert_eq!(mapped.code, ErrorCode::NetworkError);
        assert!(mapped.retryable);
        assert_eq!(mapped.message, "fetch connection failed");
    }

    #[test]
    fn refspec_mapping_conflict_is_invalid_argument_and_names_destination() {
        let specs = [
            spec("+refs/heads/*:refs/remotes/conflict/*"),
            spec("+refs/archive/*:refs/remotes/conflict/*"),
        ];
        let names = [
            BString::from("refs/heads/shared"),
            BString::from("refs/archive/shared"),
        ];
        let target = oid(1);
        let items: Vec<_> = names
            .iter()
            .map(|name| gix_refspec::match_group::Item {
                full_ref_name: name.as_bstr(),
                target: target.as_ref(),
                object: None,
            })
            .collect();
        let validation = gix_refspec::MatchGroup::from_fetch_specs(
            specs.iter().map(gix_refspec::RefSpec::to_ref),
        )
        .match_lhs(items.iter().copied())
        .validated()
        .expect_err("the two sources map to the same destination");
        let prepare_error =
            gix::remote::fetch::prepare::Error::RefMap(gix::remote::ref_map::Error::InitRefMap(
                gix_protocol::fetch::refmap::init::Error::MappingValidation(validation),
            ));

        let mapped = map_prepare_error(&prepare_error, &Budget::unlimited());
        assert_eq!(mapped.code, ErrorCode::InvalidArgument);
        assert!(mapped.message.contains("refs/remotes/conflict/shared"));
    }

    #[test]
    fn real_sha256_destination_is_an_unsupported_hash() {
        let destination = std::env::temp_dir().join(format!(
            "gitility-fetch-sha256-{}-{}.git",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system time follows the Unix epoch")
                .as_nanos()
        ));
        let _cleanup = RemoveDirectory(destination.clone());
        let output = Command::new("git")
            .args(["init", "--bare", "--object-format=sha256"])
            .arg(&destination)
            .output()
            .expect("git can be invoked");

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let sha256_unavailable = [
                "unknown option",
                "unknown hash algorithm",
                "invalid object format",
                "unsupported object format",
            ]
            .iter()
            .any(|signal| stderr.to_ascii_lowercase().contains(signal));
            assert!(
                sha256_unavailable,
                "git init failed for an unrelated reason: {stderr}"
            );
            eprintln!("skipping SHA-256 fetch test: local git lacks SHA-256 support");
            return;
        }

        let error = open_or_init_bare(&destination).expect_err("gix 0.86 cannot open SHA-256");
        assert_eq!(error.code, ErrorCode::UnsupportedHash);
        assert!(error
            .message
            .contains("destination repository object format"));
    }
}
