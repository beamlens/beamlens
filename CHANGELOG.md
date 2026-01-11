# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `description/0` callback in Skill behaviour — brief summary for the Coordinator to understand what each operator monitors
- `system_prompt/0` callback in Skill behaviour — defines operator identity and monitoring focus (e.g., "You are a BEAM VM health monitor...")
- `Beamlens.Operator.Supervisor.configured_operators/0` — returns all configured operator names (built-in and custom) for discovery
- Custom skill creation guide in README with minimal example
- Configurable compaction for operators and coordinators (`:compaction_max_tokens`, `:compaction_keep_last`)
- Telemetry events for compaction (`[:beamlens, :compaction, :start]`, `[:beamlens, :compaction, :stop]`)
- Think tool for Operator and Coordinator agents — enables structured reasoning before taking actions
- Coordinator agent that correlates alerts across operators into unified insights
- `Beamlens.Coordinator.status/1` — get coordinator running state and alert counts
- Telemetry events for coordinator (`[:beamlens, :coordinator, *]`)
- Autonomous operator system — LLM-driven loops that monitor domains and fire alerts
- Built-in BEAM skill for VM metrics (memory, processes, schedulers, atoms, ports)
- Built-in ETS skill for table monitoring (counts, memory, top tables)
- Built-in GC skill for garbage collection statistics
- Built-in Ports skill for port/socket monitoring
- Built-in Sup skill for supervisor tree monitoring
- Built-in Ecto skill for database monitoring (query stats, slow queries, connection pool health)
- PostgreSQL extras via optional `ecto_psql_extras` dependency (index usage, cache hit ratios, locks, bloat)
- Built-in Logger skill for application log monitoring (error rates, log patterns, module-specific analysis)
- Built-in System skill for OS-level monitoring (CPU load, memory usage, disk space via os_mon)
- Built-in Exception skill for exception monitoring via optional `tower` dependency
- `Beamlens.Skill` behaviour for implementing custom monitoring skills
- `callback_docs/0` callback in Skill behaviour for dynamic LLM documentation
- `Beamlens.list_operators/0` — list all running operators with status
- `Beamlens.operator_status/1` — get details about a specific operator
- `:client_registry` option to configure custom LLM providers (OpenAI, Ollama, AWS Bedrock, Google Gemini, etc.)
- LLM provider configuration guide with retry policies, fallback chains, and round-robin patterns
- Telemetry events for observability (operator lifecycle, LLM calls, alerts)
- Lua sandbox for safe metric collection callbacks

### Changed

- `Beamlens.Skill` module documentation now includes callback naming conventions, return type requirements, arity patterns, and complete examples
- README now uses consistent "operator" terminology (previously mixed "watcher" and "operator")
- Rename "domain" to "skill" throughout the codebase — `Beamlens.Domain` is now `Beamlens.Skill`, `domain_module` option is now `skill`, `domain/0` callback is now `id/0`, `builtin_domains/0` is now `builtin_skills/0`
- Rename "watcher" to "operator" throughout the codebase — `Beamlens.Watcher` is now `Beamlens.Operator`, config key `:watchers` is now `:operators`, telemetry events use `[:beamlens, :operator, *]`
- Think telemetry events now include `thought` in metadata
- Operators and coordinator no longer have iteration limits (can run indefinitely with compaction)
- BEAM skill callbacks now prefixed: `get_memory` → `beam_get_memory`, etc.
- Skill behaviour now requires `callback_docs/0` callback
- Upgraded Puck to 0.2.7 (context compaction, automatic atom→string key conversion for Lua callbacks, fix for message content format)
- Operators now run as continuous LLM-driven loops instead of scheduled cron jobs
- Operator LLM calls now run asynchronously via `Task.async`, keeping the GenServer responsive to status queries and graceful shutdown

### Removed

- `memory_utilization_pct` from BEAM domain snapshots — the calculation was meaningless (always 85-100%) because it divided BEAM memory by itself; use `Domain.System` for OS-level memory monitoring instead
- Circuit breaker protection (use LLM provider retry policies instead)
- Judge agent quality verification
- Scheduled cron-based operator triggers and `crontab` dependency (operators now run continuously)
- Beamlens.investigate/1 — alerts now fire automatically via telemetry
- Beamlens.trigger_operator/1 — operators are self-managing
- Beamlens.pending_alerts?/0 — replaced by telemetry events

## [0.1.0] - 2025-01-03

First release!

[Unreleased]: https://github.com/beamlens/beamlens/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/beamlens/beamlens/releases/tag/v0.1.0
