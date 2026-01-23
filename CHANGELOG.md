# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

#### New Skills

- **Anomaly** — Statistical anomaly detection with self-learning baselines. Optionally auto-triggers Coordinator when anomalies escalate (`auto_trigger: true`).
- **Overload** — Message queue overload analysis with bottleneck detection and remediation recommendations.
- **Allocator** — Memory allocator fragmentation monitoring for long-running nodes.
- **Tracer** — Production-safe function call tracing with message limits and auto-shutoff.

#### Skill Enhancements

- **Beam** — Scheduler utilization tracking, atom table growth monitoring, binary memory leak detection, message queue overload detection, process reduction profiling
- **Ets** — Table growth tracking and leak candidate detection
- **Gc** — Memory variance detection, lazy GC identification, hibernation recommendations with estimated savings
- **Ports** — Queue saturation monitoring with prediction, busy port detection, inet socket tracking with buffer monitoring
- **Supervisor** — Orphaned/unlinked process detection, tree integrity checking, zombie child detection
- **VmEvents** — Long GC, long schedule, and busy port event tracking

#### Infrastructure

- Operators and Coordinator are now always-running supervised processes
- `Operator.run_async/3` for background analysis with progress notifications
- Google AI (Gemini) provider support

### Changed

- **Breaking:** Skills renamed for clarity:
  - `Beamlens.Skill.Monitor` → `Beamlens.Skill.Anomaly`
  - `Beamlens.Skill.Sup` → `Beamlens.Skill.Supervisor`
  - `Beamlens.Skill.System` → `Beamlens.Skill.Os`
  - `Beamlens.Skill.SystemMonitor` → `Beamlens.Skill.VmEvents`
- **Breaking:** Atom shortcuts updated: `:monitor` → `:anomaly`, `:sup` → `:supervisor`, `:system` → `:os`, `:system_monitor` → `:vm_events`
- **Breaking:** Configuration option renamed from `:operators` to `:skills`
  ```elixir
  # Before
  {Beamlens, operators: [Beamlens.Skill.Beam]}

  # After
  {Beamlens, skills: [Beamlens.Skill.Beam]}
  ```
- **Breaking:** `Operator.run/2` and `Coordinator.run/2` raise `ArgumentError` if not configured in supervision tree

### Removed

- `Operator.Supervisor.start_operator/2` — configure via `:skills` option instead
- `Operator.Supervisor.stop_operator/2` — operators now remain running

### Fixed

- Exception skill snapshot data now serializes correctly to JSON

## [0.2.0] - 2026-01-14

See the updated [README.md](README.md)!

## [0.1.0] - 2025-01-03

First release!

[Unreleased]: https://github.com/beamlens/beamlens/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/beamlens/beamlens/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/beamlens/beamlens/releases/tag/v0.1.0
