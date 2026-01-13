# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Beamlens.Operator.run/3` for on-demand analysis that returns when complete
- `Beamlens.Operator.await/2` to wait for on-demand operator results
- `:context` option to pass trigger context (e.g., alert reason) to operators
- `done` tool allowing LLM to signal analysis completion in on-demand mode
- `title/0` callback in Skill behaviour for frontend-friendly display names
- `list_operators/0` now includes `title` and `description` from skill modules
- `Beamlens.Skill.Base` module with common callbacks for all skills (`get_current_time`, `get_node_info`)
- `description/0` callback in Skill behaviour for operator summaries
- `system_prompt/0` callback in Skill behaviour for operator identity
- `Beamlens.Operator.Supervisor.configured_operators/0` to list operator names
- Custom skill creation guide in README
- Configurable compaction (`:compaction_max_tokens`, `:compaction_keep_last`)
- Compaction telemetry events (`[:beamlens, :compaction, :start]`, `[:beamlens, :compaction, :stop]`)
- Think tool for reasoning before actions
- Coordinator agent that correlates notifications across operators into unified insights
- `Beamlens.Coordinator.status/1` — get coordinator running state and notification counts
- Telemetry events for coordinator (`[:beamlens, :coordinator, *]`)
- Autonomous operator system — LLM-driven loops that monitor domains and send notifications
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
- Telemetry events for observability (operator lifecycle, LLM calls, notifications)
- Lua sandbox for safe metric collection callbacks

### Changed

- Operators support two modes: `:on_demand` (returns results) and `:continuous` (runs forever)
- Supervisor-started operators default to `:continuous` mode
- Improved `Beamlens.Skill` module documentation
- README uses consistent "operator" terminology
- Renamed "domain" to "skill": `Beamlens.Domain` → `Beamlens.Skill`, `domain_module` → `skill`, `domain/0` → `id/0`
- Renamed "watcher" to "operator": `Beamlens.Watcher` → `Beamlens.Operator`, `:watchers` → `:operators`
- Renamed "alert" to "notification": `Alert` → `Notification`, `fire_alert` → `send_notification`, `alert_fired` → `notification_sent`
- Think telemetry events include `thought` in metadata
- Operators and coordinator can run indefinitely with compaction
- BEAM skill callbacks prefixed: `get_memory` → `beam_get_memory`
- Skill behaviour requires `callback_docs/0` callback
- Upgraded Puck to 0.2.7
- Operators run as continuous loops instead of scheduled jobs
- Operator LLM calls run asynchronously via `Task.async`

### Removed

- `memory_utilization_pct` from BEAM snapshots (use System skill for OS-level memory)
- Circuit breaker protection (use LLM provider retry policies instead)
- Judge agent quality verification
- Scheduled cron-based operator triggers and `crontab` dependency (operators now run continuously)
- Beamlens.investigate/1 — notifications now sent automatically via telemetry
- Beamlens.trigger_operator/1 — operators are self-managing
- Beamlens.pending_notifications?/0 — replaced by telemetry events

## [0.1.0] - 2025-01-03

First release!

[Unreleased]: https://github.com/beamlens/beamlens/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/beamlens/beamlens/releases/tag/v0.1.0
