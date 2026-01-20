# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Static supervision for Operator and Coordinator processes
- `Operator.run_async/3` for async invocation with notification callbacks
- Invocation queue for handling concurrent requests to static processes
- Google AI (Gemini) provider support for integration tests

### Changed

- Operators and Coordinator now start as static, always-running supervised processes
- `Operator.Supervisor` changed from DynamicSupervisor to static Supervisor

### Removed

- `Operator.Supervisor.start_operator/2` - operators are now configured statically
- `Operator.Supervisor.stop_operator/2` - operators remain running

### Fixed

- Unit tests no longer make LLM provider calls

## [0.2.0] - 2026-01-14

See the updated [README.md](README.md)!

## [0.1.0] - 2025-01-03

First release!

[Unreleased]: https://github.com/beamlens/beamlens/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/beamlens/beamlens/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/beamlens/beamlens/releases/tag/v0.1.0
