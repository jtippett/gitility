# Project commands. Run `just --list` to see them all.

# Interactive release: pick patch/minor/major, roll the CHANGELOG, tag & push.
release:
    elixir scripts/release.exs

# Run the test suite (builds the NIF locally).
test:
    GITILITY_BUILD=1 mix test

# Compile, forcing a from-source NIF build (no precompiled download).
build:
    GITILITY_BUILD=1 mix compile

# Format Elixir + Rust.
fmt:
    mix format
    cd crates/gitility-core && cargo fmt
    cd native/gitility && cargo fmt

# Regenerate the precompiled-NIF checksum file from a published GitHub release.
# Run AFTER release.yml has uploaded the artifacts (see UPDATE_PROCEDURE.md).
checksums:
    mix rustler_precompiled.download Gitility.Native --all --print
