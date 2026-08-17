use super::{parse, ParseError};
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

const PINNED_GIT_VERSION: &str = "git version 2.55.0";

#[derive(Debug, Clone, PartialEq, Eq)]
struct ConfigRecord {
    key: Vec<u8>,
    value: Option<Vec<u8>>,
}

#[derive(Debug)]
enum OracleResult {
    Accepted(Vec<ConfigRecord>),
    Rejected(Vec<u8>),
}

#[derive(Debug, Default)]
struct MatchCounts {
    accepted: usize,
    rejected: usize,
}

struct GitOracle {
    repository: PathBuf,
}

impl GitOracle {
    fn new(label: &str) -> Self {
        assert_pinned_git();
        static NEXT_ID: AtomicU64 = AtomicU64::new(0);
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let repository = std::env::temp_dir().join(format!(
            "gitility-config-oracle-{label}-{}-{id}",
            std::process::id()
        ));
        let output = Command::new("git")
            .args(["init", "--bare", "--quiet"])
            .arg(&repository)
            .output()
            .expect("git config oracle repository initializes");
        assert!(
            output.status.success(),
            "git init failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        Self { repository }
    }

    fn parse(&self, payload: &[u8]) -> OracleResult {
        let mut hash = Command::new("git")
            .args(["-C"])
            .arg(&self.repository)
            .args(["hash-object", "-w", "--stdin"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("git hash-object oracle starts");
        hash.stdin
            .take()
            .expect("hash-object stdin is piped")
            .write_all(payload)
            .expect("oracle payload writes");
        let hash = hash.wait_with_output().expect("hash-object oracle exits");
        assert!(
            hash.status.success(),
            "git hash-object failed: {}",
            String::from_utf8_lossy(&hash.stderr)
        );
        let oid = std::str::from_utf8(&hash.stdout)
            .expect("hash-object output is ASCII")
            .trim();

        // SECURITY: `git config --blob` follows `[include]` paths even though
        // Git's real `.gitmodules` consumer does not. That makes the command a
        // local-file-read primitive. Every caller below constructs payloads
        // without include sections; the include fixture is tested only through
        // our parser/API and must never be sent to this oracle.
        assert!(!has_include_section(payload));
        let output = Command::new("git")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env("LC_ALL", "C")
            .args(["-C"])
            .arg(&self.repository)
            .args(["config", "--blob", oid, "--list", "--null"])
            .output()
            .expect("git config blob oracle runs");
        if !output.status.success() {
            return OracleResult::Rejected(output.stderr);
        }

        OracleResult::Accepted(parse_oracle_records(&output.stdout))
    }
}

impl Drop for GitOracle {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.repository);
    }
}

fn assert_pinned_git() {
    static CHECK: OnceLock<()> = OnceLock::new();
    CHECK.get_or_init(|| {
        let output = Command::new("git")
            .arg("--version")
            .output()
            .expect("pinned Git is installed");
        assert!(output.status.success(), "git --version succeeds");
        assert_eq!(
            String::from_utf8(output.stdout)
                .expect("git version is UTF-8")
                .trim(),
            PINNED_GIT_VERSION,
            "the differential oracle is intentionally pinned"
        );
    });
}

fn parse_ours(payload: &[u8]) -> Result<Vec<ConfigRecord>, ParseError> {
    let mut records = Vec::new();
    parse(payload, |key, value| {
        records.push(ConfigRecord {
            key: key.to_vec(),
            value: value.map(<[u8]>::to_vec),
        });
    })?;
    Ok(records)
}

fn parse_oracle_records(output: &[u8]) -> Vec<ConfigRecord> {
    output
        .split(|byte| *byte == 0)
        .filter(|record| !record.is_empty())
        .map(|record| {
            // `--list --null` emits `key\0`, with no newline separator, for a
            // valueless key. A valued record is `key\nvalue\0`; split only on
            // the first newline because escaped `\n` is legal in the value.
            let separator = record.iter().position(|byte| *byte == b'\n');
            match separator {
                Some(separator) => ConfigRecord {
                    key: record[..separator].to_vec(),
                    value: Some(record[separator + 1..].to_vec()),
                },
                None => ConfigRecord {
                    key: record.to_vec(),
                    value: None,
                },
            }
        })
        .collect()
}

fn compare_case(oracle: &GitOracle, label: &str, payload: &[u8], counts: &mut MatchCounts) {
    match (parse_ours(payload), oracle.parse(payload)) {
        (Ok(actual), OracleResult::Accepted(expected)) => {
            assert_eq!(actual, expected, "silent value mismatch in {label}");
            counts.accepted += 1;
        }
        (Err(_), OracleResult::Rejected(stderr)) => {
            // The exact prefix contains an object ID and has changed before.
            // Pinning Git above plus the stable diagnostic substring keeps the
            // assertion precise without coupling it to that brittle prefix.
            assert!(
                stderr
                    .windows(b"bad config line".len())
                    .any(|window| window == b"bad config line"),
                "unexpected Git rejection in {label}: {}",
                String::from_utf8_lossy(&stderr)
            );
            counts.rejected += 1;
        }
        (actual, expected) => panic!(
            "acceptance mismatch in {label}\npayload={payload:?}\nours={actual:?}\ngit={expected:?}"
        ),
    }
}

#[test]
fn curated_corpus_matches_git_2_55_blob_reader() {
    let oracle = GitOracle::new("curated");
    let corpus = curated_corpus();
    assert!(
        (90..=120).contains(&corpus.len()),
        "the checked-in corpus should stay near one hundred cases"
    );
    let mut counts = MatchCounts::default();
    for (label, payload) in &corpus {
        compare_case(&oracle, label, payload, &mut counts);
    }
    eprintln!(
        "git-config curated: {} accepted matches, {} reject-agree, 0 silent value mismatches ({} total)",
        counts.accepted,
        counts.rejected,
        corpus.len()
    );
}

#[test]
fn deterministic_mutation_fuzz_matches_git_2_55_blob_reader() {
    const ITERATIONS: usize = 512;
    const SEED: u64 = 0x6a09_e667_f3bc_c909;
    let oracle = GitOracle::new("mutation");
    let seeds = [
        b"[submodule \"name\"]\npath = lib/name\nurl = ../name.git\n".as_slice(),
        b"[SuBmOdUlE.Name]\nPaTh=\"a b\" # tail\nbranch = topic\n",
        b"# comment\r\n[submodule \"esc\\\"aped\"]\r\npath = one\\\ntwo\r\n",
        b"[core]\nkey\nother = value\n[submodule \"x\"]\npath=\n",
    ];
    let alphabet = b"[]\"\\=#;.-_/ abcdefghnoprstuvxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\t\r\n\x0b\x0c\xfe\xff";
    let chunks = [
        b"\\\n".as_slice(),
        b"\n\n",
        b" # comment",
        b";tail",
        b"\"\"",
        b" = ",
        b"\\b",
        b"\\q",
    ];
    let mut rng = XorShift64(SEED);
    let mut counts = MatchCounts::default();
    let mut compared = 0usize;
    while compared < ITERATIONS {
        let mut payload = seeds[rng.index(seeds.len())].to_vec();
        for _ in 0..=rng.index(4) {
            match rng.index(5) {
                0 => {
                    let at = rng.index(payload.len() + 1);
                    payload.insert(at, alphabet[rng.index(alphabet.len())]);
                }
                1 if !payload.is_empty() => {
                    let at = rng.index(payload.len());
                    payload.remove(at);
                }
                2 if !payload.is_empty() => {
                    let at = rng.index(payload.len());
                    payload[at] = alphabet[rng.index(alphabet.len())];
                }
                3 => {
                    let at = rng.index(payload.len() + 1);
                    let chunk = chunks[rng.index(chunks.len())];
                    payload.splice(at..at, chunk.iter().copied());
                }
                _ if !payload.is_empty() => {
                    payload.truncate(rng.index(payload.len() + 1));
                }
                _ => {}
            }
        }
        if payload.len() > 512 || has_include_section(&payload) {
            continue;
        }
        compare_case(
            &oracle,
            &format!("mutation-{compared}-seed-{SEED:#x}"),
            &payload,
            &mut counts,
        );
        compared += 1;
    }
    eprintln!(
        "git-config mutation fuzz seed {SEED:#x}: {} accepted matches, {} reject-agree, 0 silent value mismatches ({} total)",
        counts.accepted,
        counts.rejected,
        ITERATIONS
    );
}

#[test]
fn exhaustive_3456_value_sweep_matches_git_2_55_blob_reader() {
    if std::env::var("GITILITY_EXHAUSTIVE_ORACLE").as_deref() != Ok("1") {
        eprintln!(
            "git-config exhaustive sweep skipped; set GITILITY_EXHAUSTIVE_ORACLE=1 to run 3,456 oracle cases"
        );
        return;
    }

    let prefixes = [
        b"".as_slice(),
        b" ",
        b"\t",
        b"\"",
        b"\" ",
        b"a",
        b"a ",
        b"a\t",
        b"\\",
        b"\\t",
        b"#",
        b";",
    ];
    let atoms = [
        b"".as_slice(),
        b"a",
        b"ab",
        b"a b",
        b"a\tb",
        b"\"a\"",
        b"\\t",
        b"\\b",
        b"\\n",
        b"\\\\",
        b"\\\"",
        b"#",
        b";",
        b"true",
        b"../evil",
        b"/absolute",
        b"trailing/",
        b" ",
        b"\t",
        b"0",
        b"A",
        b"\xc3\xa9",
        b"\xfe",
        b"\"",
    ];
    let suffixes = [
        b"".as_slice(),
        b"\n",
        b"\n\n",
        b" ",
        b"  \n",
        b"\"\n",
        b"#c\n",
        b";c\n",
        b"\\",
        b"\\\n",
        b"\\\n\n",
        b"\r\n",
    ];
    assert_eq!(prefixes.len() * atoms.len() * suffixes.len(), 3_456);

    let oracle = GitOracle::new("exhaustive");
    let mut counts = MatchCounts::default();
    let mut case = 0usize;
    for prefix in prefixes {
        for atom in atoms {
            for suffix in suffixes {
                let mut payload = b"[submodule \"s\"]\npath = ".to_vec();
                payload.extend_from_slice(prefix);
                payload.extend_from_slice(atom);
                payload.extend_from_slice(suffix);
                compare_case(
                    &oracle,
                    &format!("exhaustive-{case}"),
                    &payload,
                    &mut counts,
                );
                case += 1;
            }
        }
    }
    eprintln!(
        "git-config exhaustive: {} accepted matches, {} reject-agree, 0 silent value mismatches ({} total)",
        counts.accepted,
        counts.rejected,
        case
    );
}

fn curated_corpus() -> Vec<(String, Vec<u8>)> {
    let cases: &[(&str, &[u8])] = &[
        ("empty", b""),
        ("newline", b"\n"),
        ("crlf", b"\r\n"),
        ("lone-cr", b"\r"),
        ("spaces", b" \t\x0b\x0c\r\n"),
        ("hash-comment", b"# comment"),
        ("semicolon-comment", b"; comment\n"),
        ("basic", b"[submodule \"n\"]\npath = p\n"),
        ("case-fold", b"[SuBmOdUlE \"N\"]\nPaTh = P\n"),
        ("quoted-case", b"[submodule \"Name\"]\npath=p\n"),
        ("dotted-lower", b"[submodule.Name]\npath=p\n"),
        ("dotted-many", b"[submodule.Name.More]\npath=p\n"),
        ("empty-subsection", b"[submodule \"\"]\npath=p\n"),
        ("escaped-quote-name", b"[submodule \"a\\\"b\"]\npath=p\n"),
        ("escaped-slash-name", b"[submodule \"a\\\\b\"]\npath=p\n"),
        ("escaped-q-name", b"[submodule \"a\\qb\"]\npath=p\n"),
        ("tab-before-name", b"[submodule\t\"n\"]\npath=p\n"),
        ("many-spaces-before-name", b"[submodule   \"n\"]\npath=p\n"),
        ("no-subsection", b"[submodule]\npath=p\n"),
        ("key-before-section", b"key=value\n"),
        ("valueless", b"[core]\nkey\n"),
        ("valueless-eof", b"[core]\nkey"),
        ("empty-value", b"[core]\nkey=\n"),
        ("quoted-empty", b"[core]\nkey=\"\"\n"),
        ("leading-value-space", b"[core]\nkey=   value\n"),
        ("trailing-value-space", b"[core]\nkey=value   \n"),
        ("internal-value-space", b"[core]\nkey=a   b\n"),
        ("quoted-spaces", b"[core]\nkey=\"  a  \"\n"),
        ("quote-concatenation", b"[core]\nkey=a\" b \"c\n"),
        ("hash-in-quotes", b"[core]\nkey=\"a#b\"\n"),
        ("semicolon-in-quotes", b"[core]\nkey=\"a;b\"\n"),
        ("hash-comment-after", b"[core]\nkey=value#comment\n"),
        ("semicolon-comment-after", b"[core]\nkey=value;comment\n"),
        ("comment-after-space", b"[core]\nkey=value  # comment\n"),
        ("escape-tab", b"[core]\nkey=a\\tb\n"),
        ("escape-backspace", b"[core]\nkey=a\\bb\n"),
        ("escape-newline", b"[core]\nkey=a\\nb\n"),
        ("escape-slash", b"[core]\nkey=a\\\\b\n"),
        ("escape-quote", b"[core]\nkey=a\\\"b\n"),
        ("bad-escape-r", b"[core]\nkey=a\\rb\n"),
        ("bad-escape-q", b"[core]\nkey=a\\qb\n"),
        ("continuation", b"[core]\nkey=a\\\nb\n"),
        ("continuation-crlf", b"[core]\r\nkey=a\\\r\nb\r\n"),
        ("trailing-slash-eof", b"[core]\nkey=survives\\"),
        ("trailing-slash-before-blank", b"[core]\nkey=survives\\\n\n"),
        ("continuation-indented", b"[core]\nkey=a\\\n  b\n"),
        ("missing-final-newline", b"[core]\nkey=value"),
        ("quoted-missing-final-newline", b"[core]\nkey=\"value\""),
        ("unterminated-quote", b"[core]\nkey=\"value\n"),
        ("unterminated-section-quote", b"[submodule \"n]\npath=p\n"),
        ("unterminated-section", b"[submodule"),
        ("empty-section", b"[]\n"),
        ("section-space-before-close", b"[core ]\nkey=value\n"),
        ("section-tail", b"[core]key=value\n"),
        ("bad-section-tail", b"[core]1=value\n"),
        ("bad-line-equals", b"=value\n"),
        ("bad-line-digit", b"1key=value\n"),
        ("bad-key-underscore", b"[core]\nbad_key=value\n"),
        ("bad-key-dot", b"[core]\nbad.key=value\n"),
        ("hyphen-key", b"[core]\nbad-key=value\n"),
        ("digit-after-first", b"[core]\nkey2=value\n"),
        ("equals-after-tab", b"[core]\nkey\t=\tvalue\n"),
        ("vertical-before-equals", b"[core]\nkey\x0b=value\n"),
        ("form-before-equals", b"[core]\nkey\x0c=value\n"),
        ("lone-cr-in-value", b"[core]\nkey=a\rb\n"),
        ("duplicate-last", b"[core]\nkey=one\nkey=two\n"),
        ("repeated-sections", b"[core]\nkey=one\n[core]\nkey=two\n"),
        ("blank-between", b"[core]\n\nkey=value\n"),
        ("comment-between", b"[core]\n# c\nkey=value\n"),
        ("bom", b"\xef\xbb\xbf[core]\nkey=value\n"),
        ("partial-bom-one", b"\xef[core]\nkey=value\n"),
        ("partial-bom-two", b"\xef\xbb[core]\nkey=value\n"),
        ("ff-at-start", b"\xff[core]\nkey=value\n"),
        ("ff-in-section", b"[submodule \"a\xffb\"]\npath=p\n"),
        ("ff-in-value", b"[core]\nkey=a\xff"),
        ("fe-in-value", b"[core]\nkey=a\xfeb\n"),
        ("fe-in-section", b"[submodule \"a\xfeb\"]\npath=p\n"),
    ];
    let mut corpus = cases
        .iter()
        .map(|(label, payload)| ((*label).to_owned(), payload.to_vec()))
        .collect::<Vec<_>>();

    let indents = [b"".as_slice(), b" ", b"  ", b"\t", b"\x0b", b"\x0c"];
    let entries = [
        b"path=value\n".as_slice(),
        b"path = value\n",
        b"PATH\t=\t\"value\"\n",
        b"path\n",
        b"path =\n",
        b"path=value # tail\n",
    ];
    for (indent_index, indent) in indents.into_iter().enumerate() {
        for (entry_index, entry) in entries.into_iter().enumerate() {
            let mut payload = b"[submodule \"matrix\"]\n".to_vec();
            payload.extend_from_slice(indent);
            payload.extend_from_slice(entry);
            corpus.push((format!("matrix-{indent_index}-{entry_index}"), payload));
        }
    }
    corpus
}

fn has_include_section(payload: &[u8]) -> bool {
    payload.windows(b"[include".len()).any(|window| {
        window
            .iter()
            .zip(b"[include")
            .all(|(left, right)| left.to_ascii_lowercase() == *right)
    })
}

struct XorShift64(u64);

impl XorShift64 {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn index(&mut self, upper: usize) -> usize {
        (self.next() as usize) % upper
    }
}
