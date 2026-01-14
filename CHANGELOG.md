# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Run operators on-demand and get results back immediately via `Beamlens.Operator.run/2`
- Wait for on-demand operator results with configurable timeout via `Beamlens.Operator.await/2`
- Pass trigger context (e.g., alert reason) to operators via `:context` option
- On-demand operators signal when analysis is complete via the `done` tool
- Skills can define human-readable titles for UI display via `title/0` callback
- Operator listings now include titles and descriptions from skill modules
- All skills have access to common callbacks: current time and node info via `Beamlens.Skill.Base`
- Skills can define descriptions for Coordinator context via `description/0` callback
- Skills can define their own system prompt for LLM identity via `system_prompt/0` callback
- List configured operator names via `Beamlens.Operator.Supervisor.configured_operators/0`
- Custom skill creation guide in README
- Configurable conversation compaction to manage memory in long-running operators
- Compaction telemetry events (`[:beamlens, :compaction, :start]`, `[:beamlens, :compaction, :stop]`)
- Think tool for reasoning before actions
- Coordinator agent that correlates notifications across operators into unified insights
- `Beamlens.Coordinator.run/2` for one-shot coordinator analysis with operator invocation
- `Beamlens.Coordinator.run/2` accepts `:skills` option to specify skills without pre-configuration
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
- Skills can provide dynamic documentation for LLM callbacks via `callback_docs/0`
- List all running operators with status via `Beamlens.list_operators/0`
- Get details about a specific operator via `Beamlens.operator_status/1`
- `:client_registry` option to configure custom LLM providers (OpenAI, Ollama, AWS Bedrock, Google Gemini, etc.)
- LLM provider configuration guide with retry policies, fallback chains, and round-robin patterns
- Telemetry events for observability (operator lifecycle, LLM calls, notifications)
- Skills run callbacks in a safe Lua sandbox environment
- Deployment guide for scheduled monitoring scenarios

### Changed

- Simplified `Coordinator.run` API: context is now first positional argument, options like `notifications` and `client_registry` passed as keyword list
- Simplified `Operator.run` API: context is now second positional argument, `client_registry` moves to options keyword list
- Ecto and Exception skills are now marked as experimental
- Improved `Beamlens.Skill` module documentation
- README uses consistent "operator" terminology
- Renamed "domain" to "skill" throughout the API (modules, options, callbacks)
- Renamed "watcher" to "operator" throughout the API (modules, options)
- Renamed "alert" to "notification" throughout the API (structs, tools, telemetry events)
- Think telemetry events include `thought` in metadata
- Operators and coordinator can run indefinitely with compaction
- BEAM skill callbacks are now prefixed (e.g., `beam_get_memory`) so they don't conflict with callbacks from other skills
- Skills must now implement `callback_docs/0` (required callback)
- Upgraded Puck to 0.2.7
- Operators run LLM-driven analysis loops instead of scheduled jobs
- Operator LLM calls now run in the background for better performance

### Removed

- Cluster support via PubSub — cross-node notification broadcasting is no longer available
- `phoenix_pubsub` and `highlander` optional dependencies
- Continuous mode for operators and coordinator — use `run/2` for on-demand analysis
- `NotificationForwarder` module
- Three telemetry events: `[:beamlens, :coordinator, :remote_notification_received]`, `[:beamlens, :coordinator, :takeover]`, `[:beamlens, :coordinator, :pubsub_notification_received]`
- Automatic operator startup functions (`start_operators/0`, `start_operators_with_opts/2`) — use `start_operator/3` instead
- `:mode` option for operators and coordinator — only on-demand mode via `run/2` is supported
- `memory_utilization_pct` from BEAM snapshots (use System skill for OS-level memory)
- Circuit breaker protection (use LLM provider retry policies instead)
- Judge agent quality verification
- Beamlens.investigate/1 — notifications now sent automatically via telemetry
- Beamlens.trigger_operator/1 — operators are self-managing
- Beamlens.pending_notifications?/0 — replaced by telemetry events

## [0.1.0] - 2025-01-03

First release!

[Unreleased]: https://github.com/beamlens/beamlens/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/beamlens/beamlens/releases/tag/v0.1.0
