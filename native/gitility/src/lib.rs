//! Rustler NIF adapter for Gitility.
//!
//! This crate owns the BEAM boundary only: term encoding, resources, and the
//! provisional dirty-scheduler handoff. All Git semantics live in
//! `gitility-core`, which never depends on Rustler or Elixir concepts.

#![forbid(unsafe_code)]

use gitility_core::{
    list_tree as core_list_tree, peel as core_peel, read_file as core_read_file, Budget,
    BudgetLimits, Error, ErrorCode, FileKind, FileOptions, HashKind, LocalOdb, LocalOdbOptions,
    ObjectDb, ObjectHeader, ObjectKind, Oid, PeelTarget, QueryStats, Snapshot, StaticOdb,
    TreeItemKind, TreeOptions, TypeFilter,
};
use rustler::{
    Atom, Binary, Encoder, Env, NewBinary, NifMap, NifResult, Resource, ResourceArc, Term,
};
use std::collections::HashSet;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::Instant;

enum StoreImpl {
    Local(LocalOdb),
    Static(StaticStore),
}

struct StaticStore {
    hash: HashKind,
    addressed: StaticOdb,
    addressed_oids: HashSet<Oid>,
    derived: StaticOdb,
}

impl ObjectDb for StaticStore {
    fn hash_kind(&self) -> HashKind {
        self.hash
    }

    fn try_header(&self, oid: &Oid, budget: &Budget) -> Result<Option<ObjectHeader>, Error> {
        if self.addressed_oids.contains(oid) {
            self.addressed.try_header(oid, budget)
        } else {
            self.derived.try_header(oid, budget)
        }
    }

    fn try_find(
        &self,
        oid: &Oid,
        out: &mut Vec<u8>,
        budget: &Budget,
    ) -> Result<Option<ObjectKind>, Error> {
        if self.addressed_oids.contains(oid) {
            self.addressed.try_find(oid, out, budget)
        } else {
            self.derived.try_find(oid, out, budget)
        }
    }
}

impl StoreImpl {
    fn as_dyn(&self) -> &dyn ObjectDb {
        match self {
            Self::Local(store) => store,
            Self::Static(store) => store,
        }
    }
}

struct StoreResource(StoreImpl);

#[rustler::resource_impl]
impl Resource for StoreResource {}

#[derive(NifMap)]
struct OpenLocalOptions {
    require_bare: bool,
    verify_pack_checksums: bool,
}

#[derive(Clone, Copy, NifMap)]
struct LimitsMap {
    timeout_ms: u64,
    max_objects: u64,
    max_object_bytes: u64,
    max_total_object_bytes: u64,
    max_provider_requests: u64,
    max_provider_bytes: u64,
    max_tree_entries: u64,
    max_results: u64,
    max_diff_files: u64,
    max_diff_hunks: u64,
    max_diff_lines: u64,
    max_result_bytes: u64,
    max_delta_depth: u32,
}

#[derive(NifMap)]
struct ListTreeOptions<'a> {
    path: Binary<'a>,
    recursive: bool,
    depth: Option<u32>,
    types: Vec<Atom>,
    pathspecs: Vec<Binary<'a>>,
    include_size: bool,
    limit: u64,
    cursor: Option<Binary<'a>>,
}

#[derive(NifMap)]
struct ReadFileOptions {
    lines: Option<(u32, u32)>,
    max_bytes: u64,
}

#[derive(NifMap)]
struct ErrorMap {
    code: Atom,
    message: String,
    retryable: bool,
    limit: Option<String>,
}

#[derive(NifMap)]
struct SnapshotMap<'a> {
    commit_oid: Binary<'a>,
    tree_oid: Binary<'a>,
}

#[derive(NifMap)]
struct HeaderMap {
    kind: Atom,
    size: u64,
}

#[derive(NifMap)]
struct ObjectMap<'a> {
    kind: Atom,
    size: u64,
    data: Binary<'a>,
}

#[derive(NifMap)]
struct TreeEntryMap<'a> {
    path: Binary<'a>,
    name: Binary<'a>,
    oid: Binary<'a>,
    kind: Atom,
    mode: u32,
    size: Option<u64>,
}

#[derive(NifMap)]
struct StatsMap {
    objects_requested: u64,
    objects_read: u64,
    entries_emitted: u64,
    cache_hits: u64,
    cache_misses: u64,
    provider_requests: u64,
    provider_bytes: u64,
    decompressed_bytes: u64,
    scanned_blobs: u64,
    elapsed_ms: u64,
    stopped_by: Option<Atom>,
}

#[derive(NifMap)]
struct TreePageMap<'a> {
    entries: Vec<TreeEntryMap<'a>>,
    next_cursor: Option<Binary<'a>>,
    truncated: bool,
    stats: StatsMap,
}

#[derive(NifMap)]
struct LfsPointerMap {
    oid: String,
    size: u64,
}

#[derive(NifMap)]
struct FileMap<'a> {
    path: Binary<'a>,
    blob_oid: Binary<'a>,
    mode: u32,
    kind: Atom,
    data: Binary<'a>,
    start_line: Option<u32>,
    end_line: Option<u32>,
    total_lines: Option<u32>,
    truncated: bool,
    lfs_pointer: Option<LfsPointerMap>,
}

enum ObjectOrNotFound<'a> {
    Object(ObjectMap<'a>),
    NotFound,
}

impl Encoder for ObjectOrNotFound<'_> {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Self::Object(object) => object.encode(env),
            Self::NotFound => atoms::not_found().encode(env),
        }
    }
}

/// Builds an M1c budget from every `BudgetLimits` counterpart.
///
/// `Gitility.Limits.timeout_ms` is accepted but NOT enforced in M1c.
fn budget(limits: LimitsMap) -> Budget {
    let LimitsMap {
        timeout_ms,
        max_objects,
        max_object_bytes,
        max_total_object_bytes,
        max_provider_requests,
        max_provider_bytes,
        max_tree_entries,
        max_results,
        max_diff_files,
        max_diff_hunks,
        max_diff_lines,
        max_result_bytes,
        max_delta_depth,
    } = limits;
    let _m2_limits = (
        timeout_ms,
        max_results,
        max_diff_files,
        max_diff_hunks,
        max_diff_lines,
        max_result_bytes,
    );
    Budget::new(
        BudgetLimits {
            max_objects,
            max_object_bytes,
            max_total_object_bytes,
            max_provider_requests,
            max_provider_bytes,
            max_tree_entries,
            max_delta_depth,
        },
        None,
        Default::default(),
    )
}

fn file_budget(mut limits: LimitsMap) -> Budget {
    // M1 local/static stores inflate a blob before the semantic file cap is
    // applied. Keep that implementation detail from turning a lower
    // max_object_bytes file cap into an error; total-byte accounting remains
    // enforced by the budget.
    limits.max_object_bytes = u64::MAX;
    budget(limits)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn open_local<'a>(env: Env<'a>, path: Binary<'a>, opts: OpenLocalOptions) -> NifResult<Term<'a>> {
    let path = Path::new(OsStr::from_bytes(path.as_slice()));
    let result = LocalOdb::open(
        path,
        LocalOdbOptions {
            verify_pack_checksums: opts.verify_pack_checksums,
        },
    )
    .and_then(|(store, layout)| {
        if opts.require_bare && !layout.bare {
            Err(Error::new(
                ErrorCode::InvalidArgument,
                "repository is not bare",
            ))
        } else {
            Ok((store, layout.object_hash))
        }
    });

    match result {
        Ok((store, hash)) => Ok(Result::<_, ErrorMap>::Ok((
            ResourceArc::new(StoreResource(StoreImpl::Local(store))),
            hash_atom(hash),
        ))
        .encode(env)),
        Err(error) => Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn static_from_objects<'a>(
    env: Env<'a>,
    objects: Vec<(Option<Binary<'a>>, Atom, Binary<'a>)>,
    hash: Atom,
) -> NifResult<Term<'a>> {
    let hash = match parse_hash(hash) {
        Ok(hash) => hash,
        Err(error) => {
            return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
        }
    };
    let mut addressed = Vec::new();
    let mut addressed_oids = HashSet::new();
    let mut derived = Vec::new();
    for (address, kind, data) in objects {
        let kind = match parse_object_kind(kind) {
            Ok(kind) => kind,
            Err(error) => {
                return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
            }
        };
        let payload = data.as_slice().to_vec();
        if let Some(address) = address {
            let oid = match Oid::new(hash, address.as_slice()) {
                Ok(oid) => oid,
                Err(error) => {
                    return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env));
                }
            };
            addressed_oids.insert(oid);
            addressed.push((oid, kind, payload));
        } else {
            derived.push((kind, payload));
        }
    }

    let addressed = match StaticOdb::from_addressed_objects(hash, addressed) {
        Ok(store) => store,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let derived = match StaticOdb::from_objects(hash, derived) {
        Ok(store) => store,
        Err(error) => return Ok(Result::<(), _>::Err(error_map(env, error)?).encode(env)),
    };
    let store = StaticStore {
        hash,
        addressed,
        addressed_oids,
        derived,
    };
    Ok(Result::<_, ErrorMap>::Ok((
        ResourceArc::new(StoreResource(StoreImpl::Static(store))),
        hash_atom(hash),
    ))
    .encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn snapshot_open<'a>(
    env: Env<'a>,
    store: ResourceArc<StoreResource>,
    oid: Binary<'a>,
    limits: LimitsMap,
) -> NifResult<Result<SnapshotMap<'a>, ErrorMap>> {
    let oid = match oid_for_store(&store, oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Err(error_map(env, error)?)),
    };
    match Snapshot::open(store.0.as_dyn(), oid, &budget(limits)) {
        Ok(snapshot) => Ok(Ok(SnapshotMap {
            commit_oid: binary(env, snapshot.commit_oid.as_bytes()),
            tree_oid: binary(env, snapshot.tree_oid.as_bytes()),
        })),
        Err(error) => Ok(Err(error_map(env, error)?)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn odb_header<'a>(
    env: Env<'a>,
    store: ResourceArc<StoreResource>,
    oid: Binary<'a>,
    limits: LimitsMap,
) -> NifResult<Result<HeaderMap, ErrorMap>> {
    let oid = match oid_for_store(&store, oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Err(error_map(env, error)?)),
    };
    match store.0.as_dyn().try_header(&oid, &budget(limits)) {
        Ok(Some(header)) => Ok(Ok(HeaderMap {
            kind: object_kind_atom(header.kind),
            size: header.size,
        })),
        Ok(None) => Ok(Err(error_map(env, missing_object(oid))?)),
        Err(error) => Ok(Err(error_map(env, error)?)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn odb_read<'a>(
    env: Env<'a>,
    store: ResourceArc<StoreResource>,
    oid: Binary<'a>,
    max_bytes: Option<u64>,
    limits: LimitsMap,
) -> NifResult<Result<ObjectMap<'a>, ErrorMap>> {
    let oid = match oid_for_store(&store, oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Err(error_map(env, error)?)),
    };
    match read_object(store.0.as_dyn(), oid, max_bytes, &budget(limits)) {
        Ok(Some((kind, data))) => Ok(Ok(object_map(env, kind, data))),
        Ok(None) => Ok(Err(error_map(env, missing_object(oid))?)),
        Err(error) => Ok(Err(error_map(env, error)?)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn odb_read_many<'a>(
    env: Env<'a>,
    store: ResourceArc<StoreResource>,
    oids: Vec<Binary<'a>>,
    max_total_bytes: Option<u64>,
    limits: LimitsMap,
) -> NifResult<Result<Vec<(Binary<'a>, ObjectOrNotFound<'a>)>, ErrorMap>> {
    let budget = budget(limits);
    let mut total = 0u64;
    let mut results = Vec::with_capacity(oids.len());
    for raw_oid in oids {
        let oid = match oid_for_store(&store, raw_oid.as_slice()) {
            Ok(oid) => oid,
            Err(error) => return Ok(Err(error_map(env, error)?)),
        };
        let value = match read_object(store.0.as_dyn(), oid, None, &budget) {
            Ok(Some((kind, data))) => {
                total = total.saturating_add(data.len() as u64);
                if max_total_bytes.is_some_and(|maximum| total > maximum) {
                    let error = Error::new(
                        ErrorCode::ResultTooLarge,
                        "object batch exceeds max_total_bytes",
                    )
                    .with_limit("max_total_bytes");
                    return Ok(Err(error_map(env, error)?));
                }
                ObjectOrNotFound::Object(object_map(env, kind, data))
            }
            Ok(None) => ObjectOrNotFound::NotFound,
            Err(error) => return Ok(Err(error_map(env, error)?)),
        };
        results.push((binary(env, oid.as_bytes()), value));
    }
    Ok(Ok(results))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn list_tree<'a>(
    env: Env<'a>,
    store: ResourceArc<StoreResource>,
    commit_oid: Binary<'a>,
    tree_oid: Binary<'a>,
    opts: ListTreeOptions<'a>,
    limits: LimitsMap,
) -> NifResult<Result<TreePageMap<'a>, ErrorMap>> {
    let commit_oid = match oid_for_store(&store, commit_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Err(error_map(env, error)?)),
    };
    let tree_oid = match oid_for_store(&store, tree_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Err(error_map(env, error)?)),
    };
    let types = match type_filter(&opts.types) {
        Ok(types) => types,
        Err(error) => return Ok(Err(error_map(env, error)?)),
    };
    let page_limit_stopped_by = if limits.max_results < opts.limit {
        atoms::max_results()
    } else {
        atoms::limit()
    };
    let effective_limit = opts.limit.min(limits.max_results);
    let limit = match usize::try_from(effective_limit) {
        Ok(limit) => limit,
        Err(_) => {
            return Ok(Err(error_map(
                env,
                Error::new(ErrorCode::InvalidArgument, "tree page limit is too large"),
            )?))
        }
    };
    let options = TreeOptions {
        path: opts.path.as_slice().to_vec(),
        recursive: opts.recursive,
        depth: opts.depth,
        types,
        pathspecs: opts
            .pathspecs
            .iter()
            .map(|pathspec| pathspec.as_slice().to_vec())
            .collect(),
        include_size: opts.include_size,
        limit,
        cursor: opts.cursor.map(|cursor| cursor.as_slice().to_vec()),
    };
    let started = Instant::now();
    match core_list_tree(
        store.0.as_dyn(),
        &Snapshot {
            commit_oid,
            tree_oid,
        },
        &options,
        &budget(limits),
    ) {
        Ok(page) => {
            let entries = page
                .entries
                .into_iter()
                .map(|entry| TreeEntryMap {
                    path: binary(env, &entry.path),
                    name: binary(env, &entry.name),
                    oid: binary(env, entry.oid.as_bytes()),
                    kind: tree_kind_atom(entry.kind),
                    mode: entry.mode,
                    size: entry.size,
                })
                .collect();
            Ok(Ok(TreePageMap {
                entries,
                next_cursor: page.next_cursor.map(|cursor| binary(env, &cursor)),
                truncated: page.truncated,
                stats: stats_map(
                    page.stats,
                    started.elapsed().as_millis() as u64,
                    page_limit_stopped_by,
                ),
            }))
        }
        Err(error) => Ok(Err(error_map(env, error)?)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn read_file<'a>(
    env: Env<'a>,
    store: ResourceArc<StoreResource>,
    commit_oid: Binary<'a>,
    tree_oid: Binary<'a>,
    path: Binary<'a>,
    opts: ReadFileOptions,
    limits: LimitsMap,
) -> NifResult<Result<FileMap<'a>, ErrorMap>> {
    let commit_oid = match oid_for_store(&store, commit_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Err(error_map(env, error)?)),
    };
    let tree_oid = match oid_for_store(&store, tree_oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Err(error_map(env, error)?)),
    };
    let max_bytes = match usize::try_from(opts.max_bytes) {
        Ok(max_bytes) => max_bytes,
        Err(_) => {
            return Ok(Err(error_map(
                env,
                Error::new(ErrorCode::InvalidArgument, "max_bytes is too large"),
            )?))
        }
    };
    let budget = file_budget(limits);
    match core_read_file(
        store.0.as_dyn(),
        &Snapshot {
            commit_oid,
            tree_oid,
        },
        path.as_slice(),
        &FileOptions {
            lines: opts.lines,
            max_bytes,
        },
        &budget,
    ) {
        Ok(file) => Ok(Ok(FileMap {
            path: binary(env, &file.path),
            blob_oid: binary(env, file.blob_oid.as_bytes()),
            mode: file.mode,
            kind: file_kind_atom(file.kind),
            data: binary(env, &file.data),
            start_line: file.start_line,
            end_line: file.end_line,
            total_lines: file.total_lines,
            truncated: file.truncated,
            lfs_pointer: file.lfs_pointer.map(|pointer| LfsPointerMap {
                oid: pointer.oid,
                size: pointer.size,
            }),
        })),
        Err(error) => Ok(Err(error_map(env, error)?)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn peel<'a>(
    env: Env<'a>,
    store: ResourceArc<StoreResource>,
    oid: Binary<'a>,
    to: Atom,
    limits: LimitsMap,
) -> NifResult<Result<Binary<'a>, ErrorMap>> {
    let oid = match oid_for_store(&store, oid.as_slice()) {
        Ok(oid) => oid,
        Err(error) => return Ok(Err(error_map(env, error)?)),
    };
    let target = match parse_peel_target(to) {
        Ok(target) => target,
        Err(error) => return Ok(Err(error_map(env, error)?)),
    };
    match core_peel(store.0.as_dyn(), oid, target, &budget(limits)) {
        Ok(peeled) => Ok(Ok(binary(env, peeled.as_bytes()))),
        Err(error) => Ok(Err(error_map(env, error)?)),
    }
}

#[rustler::nif]
fn error_codes(env: Env<'_>) -> NifResult<Vec<Atom>> {
    ErrorCode::all()
        .iter()
        .map(|code| Atom::from_str(env, code.as_str()))
        .collect()
}

#[rustler::nif]
fn ping() -> Atom {
    atoms::pong()
}

fn read_object(
    store: &dyn ObjectDb,
    oid: Oid,
    max_bytes: Option<u64>,
    budget: &Budget,
) -> Result<Option<(ObjectKind, Vec<u8>)>, Error> {
    let mut data = Vec::new();
    let Some(kind) = store.try_find(&oid, &mut data, budget)? else {
        return Ok(None);
    };
    if max_bytes.is_some_and(|maximum| data.len() as u64 > maximum) {
        return Err(
            Error::new(ErrorCode::ObjectTooLarge, "object exceeds max_bytes")
                .with_limit("max_bytes"),
        );
    }
    Ok(Some((kind, data)))
}

fn object_map<'a>(env: Env<'a>, kind: ObjectKind, data: Vec<u8>) -> ObjectMap<'a> {
    ObjectMap {
        kind: object_kind_atom(kind),
        size: data.len() as u64,
        data: binary(env, &data),
    }
}

fn stats_map(stats: QueryStats, elapsed_ms: u64, page_limit_stopped_by: Atom) -> StatsMap {
    StatsMap {
        objects_requested: stats.objects_read,
        objects_read: stats.objects_read,
        entries_emitted: stats.entries_emitted,
        cache_hits: 0,
        cache_misses: 0,
        provider_requests: 0,
        provider_bytes: 0,
        decompressed_bytes: stats.bytes_read,
        scanned_blobs: 0,
        elapsed_ms,
        stopped_by: stats.stopped_by.and_then(|limit| {
            if limit == "limit" {
                Some(page_limit_stopped_by)
            } else {
                limit_atom(limit)
            }
        }),
    }
}

fn oid_for_store(store: &StoreResource, bytes: &[u8]) -> Result<Oid, Error> {
    Oid::new(store.0.as_dyn().hash_kind(), bytes)
}

fn parse_hash(hash: Atom) -> Result<HashKind, Error> {
    if hash == atoms::sha1() {
        Ok(HashKind::Sha1)
    } else if hash == atoms::sha256() {
        Ok(HashKind::Sha256)
    } else {
        Err(Error::new(
            ErrorCode::InvalidArgument,
            "unsupported hash atom",
        ))
    }
}

fn parse_object_kind(kind: Atom) -> Result<ObjectKind, Error> {
    if kind == atoms::commit() {
        Ok(ObjectKind::Commit)
    } else if kind == atoms::tree() {
        Ok(ObjectKind::Tree)
    } else if kind == atoms::blob() {
        Ok(ObjectKind::Blob)
    } else if kind == atoms::tag() {
        Ok(ObjectKind::Tag)
    } else {
        Err(Error::new(
            ErrorCode::InvalidArgument,
            "unsupported object kind atom",
        ))
    }
}

fn parse_peel_target(target: Atom) -> Result<PeelTarget, Error> {
    if target == atoms::commit() {
        Ok(PeelTarget::Commit)
    } else if target == atoms::tree() {
        Ok(PeelTarget::Tree)
    } else if target == atoms::blob() {
        Ok(PeelTarget::Blob)
    } else {
        Err(Error::new(
            ErrorCode::InvalidArgument,
            "peel target must be commit, tree, or blob",
        ))
    }
}

fn type_filter(types: &[Atom]) -> Result<TypeFilter, Error> {
    let mut filter = TypeFilter::NONE;
    for kind in types {
        if *kind == atoms::blob() {
            filter |= TypeFilter::BLOB;
        } else if *kind == atoms::tree() {
            filter |= TypeFilter::TREE;
        } else if *kind == atoms::symlink() {
            filter |= TypeFilter::SYMLINK;
        } else if *kind == atoms::gitlink() {
            filter |= TypeFilter::GITLINK;
        } else {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                "tree type filter contains an unsupported kind",
            ));
        }
    }
    Ok(filter)
}

fn hash_atom(hash: HashKind) -> Atom {
    match hash {
        HashKind::Sha1 => atoms::sha1(),
        HashKind::Sha256 => atoms::sha256(),
    }
}

fn object_kind_atom(kind: ObjectKind) -> Atom {
    match kind {
        ObjectKind::Commit => atoms::commit(),
        ObjectKind::Tree => atoms::tree(),
        ObjectKind::Blob => atoms::blob(),
        ObjectKind::Tag => atoms::tag(),
    }
}

fn tree_kind_atom(kind: TreeItemKind) -> Atom {
    match kind {
        TreeItemKind::Blob => atoms::blob(),
        TreeItemKind::Tree => atoms::tree(),
        TreeItemKind::Symlink => atoms::symlink(),
        TreeItemKind::Gitlink => atoms::gitlink(),
    }
}

fn file_kind_atom(kind: FileKind) -> Atom {
    match kind {
        FileKind::Text => atoms::text(),
        FileKind::Binary => atoms::binary(),
        FileKind::Symlink => atoms::symlink(),
        FileKind::Gitlink => atoms::gitlink(),
    }
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut binary = NewBinary::new(env, bytes.len());
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.into()
}

fn missing_object(oid: Oid) -> Error {
    Error::new(
        ErrorCode::MissingObject,
        format!("object {oid} is missing from the object store"),
    )
}

fn error_map(env: Env<'_>, error: Error) -> NifResult<ErrorMap> {
    Ok(ErrorMap {
        code: Atom::from_str(env, error.code.as_str())?,
        message: error.message,
        retryable: error.retryable,
        limit: error.limit.map(str::to_owned),
    })
}

fn limit_atom(limit: &str) -> Option<Atom> {
    match limit {
        "timeout_ms" => Some(atoms::timeout_ms()),
        "max_objects" => Some(atoms::max_objects()),
        "max_object_bytes" => Some(atoms::max_object_bytes()),
        "max_total_object_bytes" => Some(atoms::max_total_object_bytes()),
        "max_provider_requests" => Some(atoms::max_provider_requests()),
        "max_provider_bytes" => Some(atoms::max_provider_bytes()),
        "max_tree_entries" => Some(atoms::max_tree_entries()),
        "max_results" => Some(atoms::max_results()),
        "max_diff_files" => Some(atoms::max_diff_files()),
        "max_diff_hunks" => Some(atoms::max_diff_hunks()),
        "max_diff_lines" => Some(atoms::max_diff_lines()),
        "max_result_bytes" => Some(atoms::max_result_bytes()),
        "max_delta_depth" => Some(atoms::max_delta_depth()),
        "max_bytes" => Some(atoms::max_bytes()),
        "max_total_bytes" => Some(atoms::max_total_bytes()),
        _ => None,
    }
}

mod atoms {
    rustler::atoms! {
        pong,
        not_found,
        sha1,
        sha256,
        commit,
        tree,
        blob,
        tag,
        symlink,
        gitlink,
        text,
        binary,
        limit,
        timeout_ms,
        max_objects,
        max_object_bytes,
        max_total_object_bytes,
        max_provider_requests,
        max_provider_bytes,
        max_tree_entries,
        max_results,
        max_diff_files,
        max_diff_hunks,
        max_diff_lines,
        max_result_bytes,
        max_delta_depth,
        max_bytes,
        max_total_bytes,
    }
}

rustler::init!("Elixir.Gitility.Native");
