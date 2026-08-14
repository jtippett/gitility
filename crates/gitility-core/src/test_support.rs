use crate::object::Oid;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

static FIXTURE_OIDS: OnceLock<HashMap<String, String>> = OnceLock::new();

pub(crate) fn fixture_repo(name: &str) -> PathBuf {
    ensure_fixtures();
    workspace_root().join("fixtures/generated").join(name)
}

pub(crate) fn fixture_oid(name: &str) -> Oid {
    let values = FIXTURE_OIDS.get_or_init(load_fixtures);
    Oid::parse_hex(
        values
            .get(name)
            .unwrap_or_else(|| panic!("fixture OIDS has no {name} entry")),
    )
    .expect("fixture generator writes valid object IDs")
}

pub(crate) fn read_ref_oid(repository: &Path, name: &str) -> Oid {
    let contents = std::fs::read(repository.join(name)).expect("fixture ref is readable");
    let hex = std::str::from_utf8(&contents)
        .expect("fixture ref is ASCII")
        .trim();
    Oid::parse_hex(hex).expect("fixture ref contains a full object ID")
}

fn ensure_fixtures() {
    let _ = FIXTURE_OIDS.get_or_init(load_fixtures);
}

fn load_fixtures() -> HashMap<String, String> {
    let root = workspace_root();
    let marker = root.join("fixtures/generated/OIDS");
    if !marker.is_file() {
        let status = Command::new("bash")
            .arg(root.join("fixtures/generate.sh"))
            .current_dir(&root)
            .status()
            .expect("fixture generator can be started");
        assert!(status.success(), "fixture generator must succeed");
    }
    let contents = std::fs::read_to_string(marker).expect("fixture OIDS marker is readable");
    contents
        .lines()
        .filter_map(|line| line.split_once('='))
        .map(|(key, value)| (key.to_owned(), value.to_owned()))
        .collect()
}

fn workspace_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("core crate is nested under workspace/crates")
        .to_path_buf()
}
