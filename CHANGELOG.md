# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Repository scaffold: house packaging pattern (precompiled NIF via
  `rustler_precompiled`, CI + gated release workflows, `justfile`, release
  script), two-crate Rust layout (`crates/gitility-core` engine-independent
  core + `native/gitility` NIF adapter), and the full library design at
  `docs/plans/2026-08-14-gitility-design.md`. No public API yet.
