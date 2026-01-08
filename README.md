# BeamLens

An AI agent that continuously monitors your application.

## The Problem

Scheduler utilization spikes. Memory grows. A GenServer queue backs up.

You open your dashboards—Prometheus, Datadog, AppSignal. The data is there. But before you can investigate, you're correlating metrics, cross-referencing logs, building context.

BeamLens assembles that context for you—a starting point to verify, not a black box to trust.

## Start With Context, Not Just Metrics

```
Without BeamLens:
memory_total: 12582912000
memory_processes: 4194304000
memory_ets: 6815744000
process_count: 50000

With BeamLens:
"ETS memory at 54% of total system memory—well above typical levels.
Investigate ETS table growth, potentially from cache or session storage."
```

## Why BeamLens

- **BEAM-Native Tooling** — Direct access to BEAM instrumentation: schedulers, memory, processes, atoms. The context generic APM tools can't see.

- **Read-Only by Design** — Zero writes to your system. Type-safe outputs. Your data stays in your infrastructure.

- **Supplements Your Stack** — Works alongside Prometheus, Datadog, AppSignal, Sentry—whatever you're already using.

- **Bring Your Own Model** (Coming Soon) — Anthropic (available now), with OpenAI, AWS Bedrock, Google Gemini, Azure OpenAI, Ollama, and more coming in future releases.

## How It Works

BeamLens uses an **orchestrator-workers** architecture. Watchers continuously monitor specific domains (BEAM VM, databases, etc.) on cron schedules. When they detect anomalies, an AI agent investigates and correlates findings.

**Key features:**
- **LLM-based baseline learning** — Watchers learn normal behavior over time, no manual thresholds needed
- **Automatic anomaly detection** — Deviations from baseline trigger investigation
- **Telemetry integration** — All events flow through your existing observability stack

No separate services to deploy. Just an Elixir library.

## Installation

```elixir
def deps do
  [{:beamlens, "~> 0.1.0"}]
end
```

## Quick Start

Set your Anthropic API key:

```bash
export ANTHROPIC_API_KEY="your-api-key"
```

Add to your supervision tree:

```elixir
def start(_type, _args) do
  children = [
    {Beamlens, watchers: [{:beam, "*/5 * * * *"}]}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

The `:beam` watcher monitors BEAM VM metrics (memory, processes, schedulers). It learns baseline behavior automatically and reports anomalies when detected.

## Watcher Management

Monitor and control watchers at runtime:

```elixir
# List all running watchers
Beamlens.list_watchers()
#=> [%{watcher: :beam, cron: "*/5 * * * *", run_count: 12, ...}]

# Manually trigger a watcher check
Beamlens.trigger_watcher(:beam)

# Get detailed status for a watcher
Beamlens.watcher_status(:beam)

# Check if alerts are pending investigation
Beamlens.pending_alerts?()

# Investigate pending alerts
{:ok, analysis} = Beamlens.investigate()
```

## Quality Verification

A judge agent reviews each analysis to verify conclusions are supported by collected data. If the judge finds issues, the agent automatically retries with feedback.

## Bring Your Own Model (Coming Soon)

Custom LLM provider configuration will be available in a future release. Currently, BeamLens uses Claude Haiku via Anthropic's API.

Planned support includes:
- Ollama (run completely offline)
- AWS Bedrock
- OpenAI
- Google Gemini
- Azure OpenAI
- OpenRouter, Together AI, and more

## What It Observes

BeamLens gathers safe, read-only runtime metrics:

- Scheduler utilization and run queues
- Memory breakdown (processes, binaries, ETS, code)
- Process and port counts with limits
- Atom table metrics
- Persistent term usage
- OTP release and uptime

## Circuit Breaker

Opt-in protection against LLM provider failures:

```elixir
{Beamlens,
  watchers: [{:beam, "*/5 * * * *"}],
  circuit_breaker: [enabled: true, failure_threshold: 5, reset_timeout: 30_000]}
```

## Documentation

- `Beamlens` — Main module with full configuration options
- `Beamlens.Agent` — AI agent implementation details
- `Beamlens.Judge` — Quality verification agent
- `Beamlens.Watchers.Watcher` — Behaviour for implementing custom watchers
- `Beamlens.Watchers.BeamWatcher` — Built-in BEAM VM watcher
- `Beamlens.Alert` — Watcher anomaly alerts
- `Beamlens.Telemetry` — Telemetry events for observability

## License

Apache-2.0
