# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Binary memory leak detection callbacks in Beam skill (`beam_binary_leak`, `beam_binary_top_memory`)
- Operators and Coordinator are now always-running supervised processes
- New `Operator.run_async/3` for running analysis in the background with progress notifications
- Multiple analysis requests to the same operator are queued and processed in order
- Google AI (Gemini) provider support for integration tests

### Changed

- **Breaking:** Configuration option renamed from `:operators` to `:skills`
  ```elixir
  # Before
  {Beamlens, operators: [Beamlens.Skill.Beam]}

  # After
  {Beamlens, skills: [Beamlens.Skill.Beam]}
  ```
- **Breaking:** `Operator.run/2` raises `ArgumentError` if the operator is not configured in the supervision tree
- **Breaking:** `Coordinator.run/2` raises `ArgumentError` if Beamlens is not in the supervision tree

### Removed

- `Operator.Supervisor.start_operator/2` - configure operators via `:skills` option instead
- `Operator.Supervisor.stop_operator/2` - operators now remain running

### Fixed

- Exception skill snapshot data now serializes correctly to JSON
- Unit tests no longer make LLM provider calls
- Eval tests now respect `BEAMLENS_TEST_PROVIDER` configuration

## [0.2.0] - 2026-01-14

See the updated [README.md](README.md)!

## [0.1.0] - 2025-01-03

First release!

[Unreleased]: https://github.com/beamlens/beamlens/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/beamlens/beamlens/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/beamlens/beamlens/releases/tag/v0.1.0
