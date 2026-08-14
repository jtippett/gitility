use criterion::{BatchSize, Criterion, SamplingMode, Throughput};
use gitility_core::{Budget, HashKind, LocalOdb, LocalOdbOptions, ObjectDb, ObjectKind, Oid};
use std::collections::{HashSet, VecDeque};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

const CLONE_COMMAND: &str =
    "git clone --depth 1 https://github.com/GitoxideLabs/gitoxide.git sources/gitoxide";
const SAMPLE_SIZE: usize = 10;
const WARM_UP: Duration = Duration::from_secs(3);
const MEASUREMENT: Duration = Duration::from_secs(8);

struct RawStore {
    store: Arc<gix_odb::Store>,
}

#[derive(Clone)]
struct Workload {
    group: &'static str,
    label: &'static str,
    adapter_oids: Vec<Oid>,
    engine_oids: Vec<gix_hash::ObjectId>,
    decompressed_bytes: u64,
    max_object_bytes: usize,
}

#[derive(Clone, Copy, Default)]
struct KindStats {
    count: u64,
    decompressed_bytes: u64,
}

struct Corpus {
    git_dir: PathBuf,
    head: Oid,
    adapter: LocalOdb,
    raw: RawStore,
    tree_walk: Workload,
    blobs: Workload,
    headers: Workload,
    stats: [KindStats; 4],
}

fn main() {
    let workspace = workspace_root();
    let git_dir = workspace.join("sources/gitoxide/.git");
    if !git_dir.is_dir() {
        eprintln!(
            "verify-tax benchmark corpus is missing at {}.\nRun exactly:\n  {CLONE_COMMAND}",
            git_dir.display()
        );
        std::process::exit(2);
    }

    let corpus = Corpus::open(&git_dir).unwrap_or_else(|error| {
        eprintln!("verify-tax benchmark could not load its corpus: {error}");
        std::process::exit(2);
    });
    prewarm(&corpus);

    let criterion_dir = criterion_output_directory(&workspace);
    let mut criterion = Criterion::default()
        .sample_size(SAMPLE_SIZE)
        .warm_up_time(WARM_UP)
        .measurement_time(MEASUREMENT)
        .output_directory(&criterion_dir)
        .configure_from_args();

    bench_payload_workload(
        &mut criterion,
        &corpus.tree_walk,
        &corpus.adapter,
        &corpus.raw,
    );
    bench_payload_workload(&mut criterion, &corpus.blobs, &corpus.adapter, &corpus.raw);
    bench_header_workload(
        &mut criterion,
        &corpus.headers,
        &corpus.adapter,
        &corpus.raw,
    );
    criterion.final_summary();

    match render_results(&corpus, &criterion_dir) {
        Ok(results) => {
            let results_path = Path::new(env!("CARGO_MANIFEST_DIR")).join("benches/RESULTS.md");
            if let Err(error) = std::fs::write(&results_path, &results) {
                eprintln!(
                    "verify-tax measurements completed, but {} could not be written: {error}",
                    results_path.display()
                );
                std::process::exit(2);
            }
            println!("\n{results}");
        }
        Err(error) => {
            eprintln!(
                "verify-tax measurements completed, but results could not be rendered: {error}"
            );
            std::process::exit(2);
        }
    }
}

impl Corpus {
    fn open(git_dir: &Path) -> Result<Self, String> {
        let git_dir = git_dir
            .canonicalize()
            .map_err(|error| format!("could not resolve {}: {error}", git_dir.display()))?;
        let (adapter, layout) = LocalOdb::open(&git_dir, LocalOdbOptions::default())
            .map_err(|error| format!("LocalOdb::open failed: {error}"))?;
        let raw = RawStore::open(&git_dir, layout.object_hash)?;
        let head = resolve_head(&git_dir)?;
        if head.kind() != layout.object_hash {
            return Err("HEAD uses a different hash kind than the object store".into());
        }

        let handle = raw.store.to_handle_arc();
        let head_engine = to_engine_oid(&head)?;
        let mut buffer = Vec::new();
        let commit = find_raw(&handle, &head_engine, &mut buffer)?;
        if commit.kind != gix_object::Kind::Commit {
            return Err("HEAD does not resolve to a commit object".into());
        }
        let root_tree = parse_root_tree(commit.data, layout.object_hash)?;
        let commit_bytes = commit.data.len() as u64;

        let mut stats = [KindStats::default(); 4];
        record_kind(&mut stats, ObjectKind::Commit, commit_bytes);

        let mut tree_engine = vec![head_engine];
        let mut tree_adapter = vec![head];
        let mut tree_bytes = commit_bytes;
        let mut tree_max = commit.data.len();
        let mut blob_engine = Vec::new();
        let mut blob_adapter = Vec::new();
        let mut seen_trees = HashSet::new();
        let mut seen_blobs = HashSet::new();
        let mut pending_trees = VecDeque::from([root_tree]);

        while let Some(tree_oid) = pending_trees.pop_front() {
            if !seen_trees.insert(tree_oid) {
                continue;
            }
            let tree = find_raw(&handle, &tree_oid, &mut buffer)?;
            if tree.kind != gix_object::Kind::Tree {
                return Err(format!(
                    "{} is referenced as a tree but is not one",
                    tree_oid
                ));
            }
            let entries = parse_tree_entries(tree.data, layout.object_hash)?;
            let len = tree.data.len();
            tree_bytes += len as u64;
            tree_max = tree_max.max(len);
            tree_engine.push(tree_oid);
            tree_adapter.push(to_adapter_oid(&tree_oid, layout.object_hash)?);
            record_kind(&mut stats, ObjectKind::Tree, len as u64);

            for entry in entries {
                match entry.kind {
                    TreeEntryKind::Tree => pending_trees.push_back(entry.oid),
                    TreeEntryKind::Blob => {
                        if seen_blobs.insert(entry.oid) {
                            blob_adapter.push(to_adapter_oid(&entry.oid, layout.object_hash)?);
                            blob_engine.push(entry.oid);
                        }
                    }
                    TreeEntryKind::Gitlink => {}
                }
            }
        }

        let mut blob_bytes = 0u64;
        let mut blob_max = 0usize;
        for oid in &blob_engine {
            let blob = find_raw(&handle, oid, &mut buffer)?;
            if blob.kind != gix_object::Kind::Blob {
                return Err(format!("{oid} is referenced as a blob but is not one"));
            }
            let len = blob.data.len();
            blob_bytes += len as u64;
            blob_max = blob_max.max(len);
            record_kind(&mut stats, ObjectKind::Blob, len as u64);
        }

        let mut all_adapter = tree_adapter.clone();
        all_adapter.extend_from_slice(&blob_adapter);
        let mut all_engine = tree_engine.clone();
        all_engine.extend_from_slice(&blob_engine);

        Ok(Self {
            git_dir,
            head,
            adapter,
            raw,
            tree_walk: Workload {
                group: "verify_tax_tree_walk",
                label: "tree walk (commit + trees)",
                adapter_oids: tree_adapter,
                engine_oids: tree_engine,
                decompressed_bytes: tree_bytes,
                max_object_bytes: tree_max,
            },
            blobs: Workload {
                group: "verify_tax_blob_sweep",
                label: "blob sweep",
                adapter_oids: blob_adapter,
                engine_oids: blob_engine,
                decompressed_bytes: blob_bytes,
                max_object_bytes: blob_max,
            },
            headers: Workload {
                group: "verify_tax_header_sweep",
                label: "header sweep",
                adapter_oids: all_adapter,
                engine_oids: all_engine,
                decompressed_bytes: tree_bytes + blob_bytes,
                max_object_bytes: 0,
            },
            stats,
        })
    }
}

impl RawStore {
    fn open(git_dir: &Path, hash: HashKind) -> Result<Self, String> {
        let objects = git_dir.join("objects");
        let mut replacements = std::iter::empty::<(gix_hash::ObjectId, gix_hash::ObjectId)>();
        let store = gix_odb::Store::at_opts(
            objects,
            &mut replacements,
            gix_odb::store::init::Options {
                object_hash: to_engine_hash(hash),
                ..gix_odb::store::init::Options::default()
            },
        )
        .map_err(|error| format!("could not open parallel raw gix store: {error}"))?;
        Ok(Self {
            store: Arc::new(store),
        })
    }
}

fn bench_payload_workload(
    criterion: &mut Criterion,
    workload: &Workload,
    adapter: &LocalOdb,
    raw: &RawStore,
) {
    let mut group = criterion.benchmark_group(workload.group);
    group.sampling_mode(SamplingMode::Flat);
    group.throughput(Throughput::Elements(workload.adapter_oids.len() as u64));

    group.bench_function("adapter", |bencher| {
        bencher.iter_batched_ref(
            || {
                (
                    Budget::unlimited(),
                    Vec::with_capacity(workload.max_object_bytes),
                )
            },
            |(budget, buffer)| sweep_adapter_payload(adapter, workload, budget, buffer),
            BatchSize::LargeInput,
        );
    });
    group.bench_function("raw_engine", |bencher| {
        bencher.iter_batched_ref(
            || Vec::with_capacity(workload.max_object_bytes),
            |buffer| sweep_raw_payload(raw, workload, buffer),
            BatchSize::LargeInput,
        );
    });
    group.finish();
}

fn bench_header_workload(
    criterion: &mut Criterion,
    workload: &Workload,
    adapter: &LocalOdb,
    raw: &RawStore,
) {
    let mut group = criterion.benchmark_group(workload.group);
    group.sampling_mode(SamplingMode::Flat);
    group.throughput(Throughput::Elements(workload.adapter_oids.len() as u64));

    group.bench_function("adapter", |bencher| {
        bencher.iter_batched_ref(
            Budget::unlimited,
            |budget| sweep_adapter_headers(adapter, workload, budget),
            BatchSize::LargeInput,
        );
    });
    group.bench_function("raw_engine", |bencher| {
        bencher.iter_batched_ref(
            || (),
            |()| sweep_raw_headers(raw, workload),
            BatchSize::LargeInput,
        );
    });
    group.finish();
}

fn sweep_adapter_payload(
    adapter: &LocalOdb,
    workload: &Workload,
    budget: &Budget,
    buffer: &mut Vec<u8>,
) {
    for oid in &workload.adapter_oids {
        let kind = adapter
            .try_find(oid, buffer, budget)
            .unwrap_or_else(|error| panic!("adapter payload read failed for {oid}: {error}"))
            .unwrap_or_else(|| panic!("adapter payload object disappeared: {oid}"));
        std::hint::black_box((kind, buffer.len()));
    }
}

fn sweep_raw_payload(raw: &RawStore, workload: &Workload, buffer: &mut Vec<u8>) {
    for oid in &workload.engine_oids {
        buffer.clear();
        let handle = raw.store.to_handle_arc();
        let header = gix_object::FindHeader::try_header(&handle, oid.as_ref())
            .unwrap_or_else(|error| panic!("raw header read failed for {oid}: {error}"))
            .unwrap_or_else(|| panic!("raw payload header disappeared: {oid}"));
        let data = gix_object::Find::try_find(&handle, oid.as_ref(), buffer)
            .unwrap_or_else(|error| panic!("raw payload read failed for {oid}: {error}"))
            .unwrap_or_else(|| panic!("raw payload object disappeared: {oid}"));
        assert_eq!(data.kind, header.kind, "raw kind changed for {oid}");
        assert_eq!(
            data.data.len() as u64,
            header.size,
            "raw size changed for {oid}"
        );
        std::hint::black_box((data.kind, data.data.len()));
    }
}

fn sweep_adapter_headers(adapter: &LocalOdb, workload: &Workload, budget: &Budget) {
    for oid in &workload.adapter_oids {
        let header = adapter
            .try_header(oid, budget)
            .unwrap_or_else(|error| panic!("adapter header read failed for {oid}: {error}"))
            .unwrap_or_else(|| panic!("adapter header object disappeared: {oid}"));
        std::hint::black_box(header);
    }
}

fn sweep_raw_headers(raw: &RawStore, workload: &Workload) {
    for oid in &workload.engine_oids {
        let handle = raw.store.to_handle_arc();
        let header = gix_object::FindHeader::try_header(&handle, oid.as_ref())
            .unwrap_or_else(|error| panic!("raw header read failed for {oid}: {error}"))
            .unwrap_or_else(|| panic!("raw header object disappeared: {oid}"));
        std::hint::black_box(header);
    }
}

fn prewarm(corpus: &Corpus) {
    let budget = Budget::unlimited();
    let mut buffer = Vec::with_capacity(
        corpus
            .tree_walk
            .max_object_bytes
            .max(corpus.blobs.max_object_bytes),
    );
    sweep_adapter_payload(&corpus.adapter, &corpus.tree_walk, &budget, &mut buffer);
    sweep_adapter_payload(&corpus.adapter, &corpus.blobs, &budget, &mut buffer);
    sweep_adapter_headers(&corpus.adapter, &corpus.headers, &budget);

    sweep_raw_payload(&corpus.raw, &corpus.tree_walk, &mut buffer);
    sweep_raw_payload(&corpus.raw, &corpus.blobs, &mut buffer);
    sweep_raw_headers(&corpus.raw, &corpus.headers);
}

fn render_results(corpus: &Corpus, criterion_dir: &Path) -> Result<String, String> {
    let workloads = [&corpus.tree_walk, &corpus.blobs, &corpus.headers];
    let mut measurements = Vec::with_capacity(workloads.len());
    for workload in workloads {
        let adapter_ns = read_mean_ns(criterion_dir, workload.group, "adapter")?;
        let raw_ns = read_mean_ns(criterion_dir, workload.group, "raw_engine")?;
        measurements.push((workload, adapter_ns, raw_ns));
    }

    let chip = machine_value("sysctl", &["-n", "machdep.cpu.brand_string"])
        .or_else(|| system_profiler_value("Chip"))
        .unwrap_or_else(|| "unknown".into());
    let physical =
        machine_value("sysctl", &["-n", "hw.physicalcpu"]).unwrap_or_else(|| "unknown".into());
    let logical = machine_value("sysctl", &["-n", "hw.logicalcpu"])
        .or_else(|| {
            std::thread::available_parallelism()
                .ok()
                .map(|value| value.to_string())
        })
        .unwrap_or_else(|| "unknown".into());
    let macos = machine_value("sw_vers", &["-productVersion"]).unwrap_or_else(|| "unknown".into());
    let build = machine_value("sw_vers", &["-buildVersion"]).unwrap_or_else(|| "unknown".into());

    let total_count: u64 = corpus.stats.iter().map(|stats| stats.count).sum();
    let total_bytes: u64 = corpus
        .stats
        .iter()
        .map(|stats| stats.decompressed_bytes)
        .sum();
    let mut output = String::new();
    writeln!(output, "# Milestone 1 verify-tax results\n").unwrap();
    writeln!(output, "## Machine\n").unwrap();
    writeln!(output, "- Chip: {chip}").unwrap();
    writeln!(output, "- Cores: {physical} physical / {logical} logical").unwrap();
    writeln!(output, "- macOS: {macos} ({build})\n").unwrap();
    writeln!(output, "## Corpus\n").unwrap();
    writeln!(
        output,
        "- Repository: `{}` (opened read-only)",
        corpus.git_dir.display()
    )
    .unwrap();
    writeln!(output, "- HEAD: `{}`", corpus.head).unwrap();
    writeln!(
        output,
        "- Scope: HEAD commit, every unique tree reachable from its root tree, and every unique blob referenced by those trees\n"
    )
    .unwrap();
    writeln!(output, "| Kind | Objects | Decompressed bytes |").unwrap();
    writeln!(output, "| --- | ---: | ---: |").unwrap();
    for (kind, index) in [
        ("commit", kind_index(ObjectKind::Commit)),
        ("tree", kind_index(ObjectKind::Tree)),
        ("blob", kind_index(ObjectKind::Blob)),
        ("tag", kind_index(ObjectKind::Tag)),
    ] {
        let stats = corpus.stats[index];
        writeln!(
            output,
            "| {kind} | {} | {} |",
            stats.count, stats.decompressed_bytes
        )
        .unwrap();
    }
    writeln!(
        output,
        "| **total** | **{total_count}** | **{total_bytes}** |\n"
    )
    .unwrap();

    writeln!(output, "## Measurements\n").unwrap();
    writeln!(
        output,
        "Criterion 0.7.0; {SAMPLE_SIZE} flat samples, {} s warm-up, {} s measurement per arm. Each sample times complete object sweeps. A fresh unlimited `Budget` is constructed outside the timed adapter sweep for every iteration. The raw arm mirrors the adapter's gix call shape (a fresh handle per object and, for payloads, header then payload) but omits Gitility verification, budget accounting, conversion, and error translation. Both stores were pre-warmed in the same process. MB/s uses decimal MB (1,000,000 bytes); header MB/s is equivalent corpus throughput because header reads do not decompress payloads.\n",
        WARM_UP.as_secs(),
        MEASUREMENT.as_secs()
    )
    .unwrap();
    writeln!(
        output,
        "| Workload | Objects | Bytes | A adapter ns/object | A MB/s | B raw engine ns/object | B MB/s | A - B ns/object | Verify share of A |"
    )
    .unwrap();
    writeln!(
        output,
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
    )
    .unwrap();
    for (workload, adapter_sweep_ns, raw_sweep_ns) in &measurements {
        let objects = workload.adapter_oids.len() as f64;
        let adapter_ns_per_object = adapter_sweep_ns / objects;
        let raw_ns_per_object = raw_sweep_ns / objects;
        let delta = adapter_ns_per_object - raw_ns_per_object;
        let share = delta / adapter_ns_per_object * 100.0;
        writeln!(
            output,
            "| {} | {} | {} | {:.1} | {:.1} | {:.1} | {:.1} | {:+.1} | {:+.1}% |",
            workload.label,
            workload.adapter_oids.len(),
            workload.decompressed_bytes,
            adapter_ns_per_object,
            mb_per_second(workload.decompressed_bytes, *adapter_sweep_ns),
            raw_ns_per_object,
            mb_per_second(workload.decompressed_bytes, *raw_sweep_ns),
            delta,
            share,
        )
        .unwrap();
    }

    let (_, adapter_header_ns, raw_header_ns) = measurements[2];
    let header_difference = (adapter_header_ns - raw_header_ns).abs() / adapter_header_ns * 100.0;
    if header_difference <= 5.0 {
        writeln!(
            output,
            "\nHeader A≈B (a {header_difference:.1}% difference). Gitility verification does not run for `try_header`, so this control is already verify-tax-free."
        )
        .unwrap();
    } else {
        writeln!(
            output,
            "\nHeader A and B are not approximately equal (a {header_difference:.1}% difference). Gitility verification does not run for `try_header`, so this gap is adapter or measurement overhead, not verification cost."
        )
        .unwrap();
    }

    Ok(output)
}

fn read_mean_ns(criterion_dir: &Path, group: &str, arm: &str) -> Result<f64, String> {
    let path = criterion_dir
        .join(group)
        .join(arm)
        .join("new/estimates.json");
    let json = std::fs::read_to_string(&path)
        .map_err(|error| format!("could not read {}: {error}", path.display()))?;
    let mean = json
        .find("\"mean\"")
        .ok_or_else(|| format!("{} has no mean estimate", path.display()))?;
    let point_key = "\"point_estimate\":";
    let point = json[mean..]
        .find(point_key)
        .map(|offset| mean + offset + point_key.len())
        .ok_or_else(|| format!("{} has no mean point estimate", path.display()))?;
    let value = json[point..]
        .split([',', '}'])
        .next()
        .ok_or_else(|| format!("{} has an empty mean point estimate", path.display()))?;
    value.trim().parse::<f64>().map_err(|error| {
        format!(
            "{} has an invalid mean point estimate: {error}",
            path.display()
        )
    })
}

fn mb_per_second(bytes: u64, nanoseconds: f64) -> f64 {
    bytes as f64 * 1_000.0 / nanoseconds
}

fn find_raw<'a, H>(
    handle: &H,
    oid: &gix_hash::ObjectId,
    buffer: &'a mut Vec<u8>,
) -> Result<gix_object::Data<'a>, String>
where
    H: gix_object::Find,
{
    gix_object::Find::try_find(handle, oid.as_ref(), buffer)
        .map_err(|error| format!("raw read failed for {oid}: {error}"))?
        .ok_or_else(|| format!("object is missing from the shallow corpus: {oid}"))
}

fn parse_root_tree(payload: &[u8], hash: HashKind) -> Result<gix_hash::ObjectId, String> {
    let line = payload
        .split(|byte| *byte == b'\n')
        .find(|line| line.starts_with(b"tree "))
        .ok_or_else(|| "HEAD commit has no root tree".to_string())?;
    let hex = std::str::from_utf8(&line[5..])
        .map_err(|_| "HEAD root tree ID is not UTF-8".to_string())?;
    let oid = Oid::parse_hex(hex).map_err(|error| format!("invalid HEAD root tree ID: {error}"))?;
    if oid.kind() != hash {
        return Err("HEAD root tree uses the wrong hash kind".into());
    }
    to_engine_oid(&oid)
}

enum TreeEntryKind {
    Tree,
    Blob,
    Gitlink,
}

struct ParsedTreeEntry {
    kind: TreeEntryKind,
    oid: gix_hash::ObjectId,
}

fn parse_tree_entries(payload: &[u8], hash: HashKind) -> Result<Vec<ParsedTreeEntry>, String> {
    let digest_len = hash.digest_len();
    let mut entries = Vec::new();
    let mut cursor = 0usize;
    while cursor < payload.len() {
        let mode_end = payload[cursor..]
            .iter()
            .position(|byte| *byte == b' ')
            .map(|offset| cursor + offset)
            .ok_or_else(|| "tree entry has no mode terminator".to_string())?;
        let name_end = payload[mode_end + 1..]
            .iter()
            .position(|byte| *byte == 0)
            .map(|offset| mode_end + 1 + offset)
            .ok_or_else(|| "tree entry has no name terminator".to_string())?;
        let oid_start = name_end + 1;
        let oid_end = oid_start
            .checked_add(digest_len)
            .filter(|end| *end <= payload.len())
            .ok_or_else(|| "tree entry has a truncated object ID".to_string())?;
        let oid = gix_hash::ObjectId::try_from(&payload[oid_start..oid_end])
            .map_err(|error| format!("tree entry has an invalid object ID: {error}"))?;
        let mode = &payload[cursor..mode_end];
        let kind = match mode {
            b"40000" | b"040000" => TreeEntryKind::Tree,
            b"160000" => TreeEntryKind::Gitlink,
            _ => TreeEntryKind::Blob,
        };
        entries.push(ParsedTreeEntry { kind, oid });
        cursor = oid_end;
    }
    Ok(entries)
}

fn resolve_head(git_dir: &Path) -> Result<Oid, String> {
    let head = std::fs::read_to_string(git_dir.join("HEAD"))
        .map_err(|error| format!("could not read HEAD: {error}"))?;
    let value = head.trim();
    if let Some(reference) = value.strip_prefix("ref: ") {
        let loose = git_dir.join(reference);
        if let Ok(oid) = std::fs::read_to_string(&loose) {
            return Oid::parse_hex(oid.trim())
                .map_err(|error| format!("invalid HEAD reference: {error}"));
        }
        let packed = std::fs::read_to_string(git_dir.join("packed-refs"))
            .map_err(|error| format!("could not resolve {reference}: {error}"))?;
        for line in packed.lines().filter(|line| !line.starts_with(['#', '^'])) {
            if let Some((oid, name)) = line.split_once(' ') {
                if name == reference {
                    return Oid::parse_hex(oid)
                        .map_err(|error| format!("invalid packed HEAD reference: {error}"));
                }
            }
        }
        return Err(format!("HEAD reference does not exist: {reference}"));
    }
    Oid::parse_hex(value).map_err(|error| format!("invalid detached HEAD: {error}"))
}

fn record_kind(stats: &mut [KindStats; 4], kind: ObjectKind, bytes: u64) {
    let entry = &mut stats[kind_index(kind)];
    entry.count += 1;
    entry.decompressed_bytes += bytes;
}

const fn kind_index(kind: ObjectKind) -> usize {
    match kind {
        ObjectKind::Commit => 0,
        ObjectKind::Tree => 1,
        ObjectKind::Blob => 2,
        ObjectKind::Tag => 3,
    }
}

fn to_adapter_oid(oid: &gix_hash::ObjectId, hash: HashKind) -> Result<Oid, String> {
    Oid::new(hash, oid.as_bytes()).map_err(|error| format!("could not convert object ID: {error}"))
}

fn to_engine_oid(oid: &Oid) -> Result<gix_hash::ObjectId, String> {
    gix_hash::ObjectId::try_from(oid.as_bytes())
        .map_err(|error| format!("could not convert object ID for gix: {error}"))
}

const fn to_engine_hash(hash: HashKind) -> gix_hash::Kind {
    match hash {
        HashKind::Sha1 => gix_hash::Kind::Sha1,
        HashKind::Sha256 => gix_hash::Kind::Sha256,
    }
}

fn workspace_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("gitility-core is in <workspace>/crates/gitility-core")
        .to_path_buf()
}

fn criterion_output_directory(workspace: &Path) -> PathBuf {
    std::env::var_os("CRITERION_HOME")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("CARGO_TARGET_DIR")
                .map(PathBuf::from)
                .map(|path| path.join("criterion"))
        })
        .unwrap_or_else(|| workspace.join("target/criterion"))
}

fn machine_value(command: &str, arguments: &[&str]) -> Option<String> {
    let output = Command::new(command).args(arguments).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?;
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn system_profiler_value(key: &str) -> Option<String> {
    let output = machine_value("system_profiler", &["SPHardwareDataType"])?;
    output.lines().find_map(|line| {
        let (candidate, value) = line.trim().split_once(':')?;
        (candidate == key).then(|| value.trim().to_string())
    })
}
