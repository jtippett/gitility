# Only reproduced and triaged Gitility divergences belong here.
#
# An entry applies only when id, operation, fixture_repo, and query all match
# the actual differential case exactly. Entry shape:
# %{
#   id: :stable_case_id,
#   operation: :blame,
#   fixture_repo: "sha1-history.git",
#   query: %{revision: "main", path: <<"src/tale.txt">>},
#   classification: :known_engine_deviation,
#   explanation: "Why this exact case differs and why it is accepted.",
#   git_version_triaged: "2.55.0",
#   expected_results: %{git: ["..."], gitility: ["..."]}
# }
[
  %{
    id: :history_graph_criss_left_no_follow,
    operation: :history,
    fixture_repo: "sha1-graph.git",
    query: %{
      revision: "1f2a9863daceff8dc457bf124f41dd3c3b0d3e66",
      path: "criss-left.txt",
      follow_renames: false
    },
    classification: :merge_rule,
    explanation:
      "gitility emits a merge iff the path differs from its FIRST parent; git --full-history emits when not TREESAME to ANY parent. Decision: m3d-review-fixes.md M1/M2 (2026-08-17).",
    git_version_triaged: "2.55.0",
    expected_results: %{
      git: [
        "2ac3b4677f2b53dc190fd434150f9f5a0d12cbae",
        "e7977ecba17ff49e4989c3cb5a495fe67a65a339",
        "82314f9d1af321a043f36bb30c110f03cf1f6559"
      ],
      gitility: [
        "2ac3b4677f2b53dc190fd434150f9f5a0d12cbae",
        "82314f9d1af321a043f36bb30c110f03cf1f6559"
      ]
    }
  },
  %{
    id: :history_branches_left_no_follow,
    operation: :history,
    fixture_repo: "sha1-history.git",
    query: %{
      revision: "bee53e651ebe689718613fdb917bf90dc860a4dc",
      path: "branches/left.txt",
      follow_renames: false
    },
    classification: :merge_rule,
    explanation:
      "gitility emits a merge iff the path differs from its FIRST parent; git --full-history emits when not TREESAME to ANY parent. Decision: m3d-review-fixes.md M1/M2 (2026-08-17).",
    git_version_triaged: "2.55.0",
    expected_results: %{
      git: [
        "b1fb2757f2aac73deb95c00d8ea1cf4d7691b43b",
        "dc569db93ce7ed63c3cb57d80e9b1ae8dd1d9232",
        "9ab892f2b38925fb65d0d5e06785c798e8eb09e2"
      ],
      gitility: [
        "b1fb2757f2aac73deb95c00d8ea1cf4d7691b43b",
        "9ab892f2b38925fb65d0d5e06785c798e8eb09e2"
      ]
    }
  },
  %{
    id: :history_candidates_selected_follow,
    operation: :history,
    fixture_repo: "sha1-history.git",
    query: %{
      revision: "bee53e651ebe689718613fdb917bf90dc860a4dc",
      path: "candidates/selected.txt",
      follow_renames: true
    },
    classification: :follow_copy_detection,
    explanation:
      "git log --follow enables copy detection when re-targeting across file creation; gitility's rename pass considers rename sources only (design R3). Decision: m3d-review-fixes.md M1/M2 (2026-08-17).",
    git_version_triaged: "2.55.0",
    expected_results: %{
      git: [
        "bee53e651ebe689718613fdb917bf90dc860a4dc",
        "24c859b0cba6a286298a7db00ec7e3723c6cd8c2",
        "a5961234c4a3572e10a5ad92cf1a6a7b753d2461",
        "7f2e4b5d5dfbc2b8fc17f9a5beb50a732a7cd8db"
      ],
      gitility: [
        "bee53e651ebe689718613fdb917bf90dc860a4dc",
        "24c859b0cba6a286298a7db00ec7e3723c6cd8c2"
      ]
    }
  }
]
