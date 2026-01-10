# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Configurable compaction for watchers and coordinators (`:compaction_max_tokens`, `:compaction_keep_last`)
- Telemetry events for compaction (`[:beamlens, :compaction, :start]`, `[:beamlens, :compaction, :stop]`)
- Think tool for Watcher and Coordinator agents — enables structured reasoning before taking actions
- Coordinator agent that correlates alerts across watchers into unified insights
- `Beamlens.Coordinator.status/1` — get coordinator running state and alert counts
- Telemetry events for coordinator (`[:beamlens, :coordinator, *]`)
- Autonomous watcher system — LLM-driven loops that monitor domains and fire alerts
- Built-in BEAM domain for VM metrics (memory, processes, schedulers, atoms, ports)
- Built-in ETS domain for table monitoring (counts, memory, top tables)
- Built-in GC domain for garbage collection statistics
- Built-in Ports domain for port/socket monitoring
- Built-in Sup domain for supervisor tree monitoring
- Built-in Ecto domain for database monitoring (query stats, slow queries, connection pool health)
- PostgreSQL extras via optional `ecto_psql_extras` dependency (index usage, cache hit ratios, locks, bloat)
- Built-in Logger domain for application log monitoring (error rates, log patterns, module-specific analysis)
- Built-in System domain for OS-level monitoring (CPU load, memory usage, disk space via os_mon)
- Built-in Exception domain for exception monitoring via optional `tower` dependency
- `Beamlens.Domain` behaviour for implementing custom monitoring domains
- `callback_docs/0` callback in Domain behaviour for dynamic LLM documentation
- `Beamlens.list_watchers/0` — list all running watchers with status
- `Beamlens.watcher_status/1` — get details about a specific watcher
- `:client_registry` option to configure custom LLM providers (OpenAI, Ollama, AWS Bedrock, Google Gemini, etc.)
- LLM provider configuration guide with retry policies, fallback chains, and round-robin patterns
- Telemetry events for observability (watcher lifecycle, LLM calls, alerts)
- Lua sandbox for safe metric collection callbacks

### Changed

- Think telemetry events now include `thought` in metadata
- Watchers and coordinator no longer have iteration limits (can run indefinitely with compaction)
- BEAM domain callbacks now prefixed: `get_memory` → `beam_get_memory`, etc.
- Domain behaviour now requires `callback_docs/0` callback
- Upgraded Puck to 0.2.7 (context compaction, automatic atom→string key conversion for Lua callbacks, fix for message content format)
- Watchers now run as continuous LLM-driven loops instead of scheduled cron jobs
- Watcher LLM calls now run asynchronously via `Task.async`, keeping the GenServer responsive to status queries and graceful shutdown

### Removed

- `memory_utilization_pct` from BEAM domain snapshots — the calculation was meaningless (always 85-100%) because it divided BEAM memory by itself; use `Domain.System` for OS-level memory monitoring instead
- Circuit breaker protection (use LLM provider retry policies instead)
- Judge agent quality verification
- Scheduled cron-based watcher triggers and `crontab` dependency (watchers now run continuously)
- Beamlens.investigate/1 — alerts now fire automatically via telemetry
- Beamlens.trigger_watcher/1 — watchers are self-managing
- Beamlens.pending_alerts?/0 — replaced by telemetry events

## [0.1.0] - 2025-01-03

First release!

[Unreleased]: https://github.com/beamlens/beamlens/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/beamlens/beamlens/releases/tag/v0.1.0
