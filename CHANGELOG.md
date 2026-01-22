# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Overload skill for message queue overload analysis and adaptive response recommendations
- Overload classification: transient (burst), sustained (capacity exceeded), critical (cascade)
- Bottleneck detection identifying downstream blocking, CPU-bound, or contention issues
- Cascading failure detection across multiple subsystems
- Remediation recommendations based on overload type and bottleneck location
- Process relationship monitoring in Sup skill: `sup_unlinked_processes`, `sup_orphaned_processes`, `sup_tree_integrity`, `sup_zombie_children`
- Unlinked process detection for finding processes with no links or monitors (potential leaks)
- Orphaned process detection for finding processes whose parent/ancestor has died
- Supervision tree integrity checking with anomaly detection (crash loops, high undefined ratios, large supervisors)
- Zombie children detection for finding children of dead supervisors
- GC pattern analysis callbacks: `gc_find_spiky_processes`, `gc_find_lazy_gc_processes`, `gc_calculate_efficiency`, `gc_recommend_hibernation`, `gc_get_long_gcs`
- Memory variance detection for spiky process memory usage patterns
- Lazy GC process identification for memory hoarding detection
- GC efficiency ratio calculation (reclaimed vs allocated)
- Hibernation recommendations with estimated memory savings
- Long GC event history from SystemMonitor integration
- Memory allocator monitoring in Allocator skill: `allocator_summary`, `allocator_by_type`, `allocator_fragmentation`, `allocator_problematic`
- Allocator metrics: carrier utilization, block efficiency, fragmentation detection for long-running nodes
- Inet port monitoring callbacks in Ports skill: `ports_list_inet`, `ports_top_by_buffer`, `ports_inet_stats`
- Socket state tracking for TCP/UDP/SCTP ports with local/remote addresses
- Buffer size monitoring for detecting backpressure and connection issues
- Tracer skill for production-safe function call tracing with message limits and auto-shutoff
- Atom table growth monitoring callbacks in Beam skill: `beam_atom_growth_rate/1`, `beam_atom_leak_detected/0`
- AtomStore GenServer for periodic atom count sampling
- Busy port detection monitoring in SystemMonitor skill: `busy_port` and `busy_dist_port` event tracking
- Ports skill callbacks: `ports_busy_events` and `ports_busy_dist_events` for querying busy port events
- Process reduction profiling callbacks in Beam skill: `beam_top_reducers_window/2`, `beam_reduction_rate/2`, `beam_burst_detection/2`, `beam_hot_functions/2`
- ETS table growth tracking callbacks in Ets skill (`ets_growth_stats`, `ets_leak_candidates`)
- GrowthStore GenServer for periodic ETS table size sampling
- SystemMonitor skill for tracking long_gc and long_schedule events
- Scheduler utilization (wall time) tracking callbacks in Beam skill (`beam_scheduler_utilization`, `beam_scheduler_capacity_available`, `beam_scheduler_health`)
- Message queue overload detection callbacks in Beam skill: `beam_queue_processes/1`, `beam_queue_growth/2`, `beam_queue_stats/0`
- Binary memory leak detection callbacks in Beam skill (`beam_binary_leak`, `beam_binary_top_memory`, `beam_binary_info`)
- Binary memory tracking in Beam skill snapshot (`binary_memory_mb`)
- Rate limiting for `beam_binary_leak` GC calls (once per minute)
- Message queue overload detection: `beam_queue_processes/1`, `beam_queue_growth/2`, `beam_queue_stats/0`
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
