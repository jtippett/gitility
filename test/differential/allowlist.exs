# Only reproduced and triaged Gitility divergences belong here. Keep this list
# empty until an engine-backed differential test demonstrates a real mismatch.
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
#   git_version_triaged: "2.55.0"
# }
[]
