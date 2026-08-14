# Milestone 1 verify-tax results

## Machine

- Chip: Apple M1 Max
- Cores: 10 physical / 10 logical
- macOS: 26.6.1 (25G76)

## Corpus

- Repository: `/Users/james/Desktop/elixir/gitility/sources/gitoxide/.git` (opened read-only)
- HEAD: `80580b3b935d0c6f425961837684b97fbd8e38e4`
- Scope: HEAD commit, every unique tree reachable from its root tree, and every unique blob referenced by those trees

| Kind | Objects | Decompressed bytes |
| --- | ---: | ---: |
| commit | 1 | 1204 |
| tree | 782 | 157626 |
| blob | 2766 | 122324829 |
| tag | 0 | 0 |
| **total** | **3549** | **122483659** |

## Measurements

Criterion 0.7.0; 10 flat samples, 3 s warm-up, 8 s measurement per arm. Each sample times complete object sweeps. A fresh unlimited `Budget` is constructed outside the timed adapter sweep for every iteration. The raw arm mirrors the adapter's gix call shape (a fresh handle per object and, for payloads, header then payload) but omits Gitility verification, budget accounting, conversion, and error translation. Both stores were pre-warmed in the same process. MB/s uses decimal MB (1,000,000 bytes); header MB/s is equivalent corpus throughput because header reads do not decompress payloads.

| Workload | Objects | Bytes | A adapter ns/object | A MB/s | B raw engine ns/object | B MB/s | A - B ns/object | Verify share of A |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| tree walk (commit + trees) | 783 | 158830 | 2179.5 | 93.1 | 1504.7 | 134.8 | +674.8 | +31.0% |
| blob sweep | 2766 | 122324829 | 246419.1 | 179.5 | 159232.2 | 277.7 | +87187.0 | +35.4% |
| header sweep | 3549 | 122483659 | 896.9 | 38477.6 | 865.4 | 39878.8 | +31.5 | +3.5% |

Header A≈B (a 3.5% difference). Gitility verification does not run for `try_header`, so this control is already verify-tax-free.
