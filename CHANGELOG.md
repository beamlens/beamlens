# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Judge agent that double-checks AI conclusions against raw data
- Automatic retry when the judge finds issues with an analysis
- `:judge` option to enable/disable quality checks (enabled by default)
- `:max_judge_retries` option to control retry attempts (default: 2)
- `JudgeCall` event type in `HealthAnalysis.events` for audit trail
- Telemetry events for judge lifecycle: `[:beamlens, :judge, :start | :stop | :exception]`
- Event tracking to trace how AI reached its conclusions
- `HealthAnalysis.events` field with ordered list of all events during analysis
- `get_overview` tool for quick health snapshot with utilization percentages
- `reasoning` field in `HealthAnalysis` explaining how the agent reached its assessment
- `get_top_processes` tool for drilling into process-level details
- Tools can now accept parameters from the AI for focused data collection
- Watcher system — background monitors that run on schedules and report problems
- AI-based baseline learning — watchers learn what "normal" looks like, no manual thresholds
- Built-in BEAM watcher for VM metrics (memory, processes, schedulers)
- `Beamlens.investigate/1` — analyze pending watcher alerts using AI
- `Beamlens.list_watchers/0` — list all running watchers with status
- `Beamlens.trigger_watcher/1` — manually trigger a specific watcher
- `Beamlens.watcher_status/1` — get details about a specific watcher
- `Beamlens.pending_alerts?/0` — check if alerts are waiting for investigation
- `Watcher` behaviour for implementing custom monitors
- Alert system (`Alert`, `AlertQueue`, `AlertHandler`) for watcher communication
- Watcher investigation loop — after detecting anomalies, watchers investigate deeper using tools
- `WatcherFindings` struct with root cause analysis and recommendations
- Telemetry events for watcher lifecycle: `[:beamlens, :watcher, :started | :triggered | :check_start | :check_stop]`
- Telemetry events for investigation: `[:beamlens, :watcher, :investigation, :start | :complete | :tool_call | :error | :timeout]`
- `:alert_handler` config option with `:on_alert` (auto) and `:manual` trigger modes
- Alert cooldown — watchers suppress re-alerts on the same metric category for an LLM-determined duration
- Telemetry event `[:beamlens, :watcher, :baseline_anomaly_suppressed]` when duplicate alerts are suppressed
- `:snapshot` option for `Beamlens.Agent` to use pre-computed metrics instead of live data

### Changed

- Upgraded Puck from 0.1.0 to 0.2.0 (adds context compaction support)
- Standardized telemetry events to follow Phoenix/Oban conventions
- All exception events now include `kind`, `reason`, and `stacktrace` metadata
- All stop events now include `duration` measurement and result data
- Tool execute functions now receive a params map, enabling tools to accept LLM-provided parameters
- Agent now collects a complete snapshot of all metrics upfront, reducing LLM roundtrips for typical analyses
- Configuration uses `:watchers` instead of `:schedules`
- `list_schedules/0` → `list_watchers/0`
- `get_schedule/1` → `watcher_status/1`
- `run_now/1` → `trigger_watcher/1`

## [0.1.0] - 2025-01-03

First release!

[Unreleased]: https://github.com/beamlens/beamlens/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/beamlens/beamlens/releases/tag/v0.1.0
