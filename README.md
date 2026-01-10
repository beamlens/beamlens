# BeamLens

An AI agent that continuously monitors your Elixir application.

## The Problem

Your alerting fires at 3am. Memory is spiking. By the time you open your laptop and start investigating, the spike has passed. Now you're correlating dashboards with log timestamps, piecing together what happened.

Even when you have the data, you're the one connecting the dots—cross-referencing metrics with logs, building the picture manually.

BeamLens closes that gap for application-level issues. Autonomous watchers monitor specific domains using LLM-driven loops. When one detects an anomaly, it investigates immediately—gathering snapshots, executing diagnostic code, and firing alerts while the system state is still live. You get structured alerts with supporting evidence, not scattered data points to assemble yourself.

This isn't distributed tracing across services. It's deep introspection within your application—runtime context that generic APM tools can't access. Every operation is read-only by design. Your data stays in your infrastructure. You choose the model provider you trust.

## What You Get

Raw metrics require interpretation. BeamLens gives you analysis:

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

## How It Works

Each watcher runs a continuous LLM-driven loop. The LLM monitors snapshots, investigates anomalies using Lua code execution in a sandbox, and fires alerts via telemetry when issues are detected.

```
Watcher → LLM Loop → Telemetry Events
```

The watcher maintains state reflecting its current assessment:
- **healthy** — Everything is normal
- **observing** — Something looks off, gathering more data
- **warning** — Elevated concern, not yet critical
- **critical** — Active issue requiring attention

**What makes this different:**

- **Deep runtime access** — Watchers can see what generic APM tools can't: BEAM internals, database connection states, queue depths, whatever the domain exposes
- **Supplements your stack** — Works alongside Prometheus, Datadog, AppSignal, Sentry
- **Bring your own model** — Anthropic, OpenAI, Ollama, AWS Bedrock, and more

## Installation

```elixir
def deps do
  [{:beamlens, "~> 0.1.0"}]
end
```

## Quick Start

Set your Anthropic API key (or configure an [alternative provider](docs/providers.md)):

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

Add to your supervision tree:

```elixir
def start(_type, _args) do
  children = [
    {Beamlens, watchers: [:beam]}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

## Built-in Watchers

| Watcher | Description |
|---------|-------------|
| `:beam` | BEAM VM metrics (memory, processes, schedulers, atoms) |
| `:ets` | ETS table monitoring (counts, memory, largest tables) |
| `:gc` | Garbage collection statistics |
| `:ports` | Port monitoring (file descriptors, sockets) |
| `:sup` | Supervisor tree monitoring |

Start multiple watchers:

```elixir
{Beamlens, watchers: [:beam, :ets, :gc, :ports, :sup]}
```

Each watcher runs independently with its own LLM context, monitoring its specific domain.

Subscribe to alerts via telemetry:

```elixir
:telemetry.attach("my-alerts", [:beamlens, :watcher, :alert_fired], fn
  _event, _measurements, %{alert: alert}, _config ->
    Logger.warning("BeamLens alert: #{alert.summary}")
end, nil)
```

## Alert Correlation

The Coordinator receives alerts from all watchers and correlates them into unified insights. When multiple alerts occur together, the Coordinator identifies patterns and produces insights explaining how they're related.

Correlation types:
- **temporal** — Alerts occurred close in time, possibly related
- **causal** — One alert directly caused another
- **symptomatic** — Alerts share a common hidden cause

Subscribe to insights:

```elixir
:telemetry.attach("my-insights", [:beamlens, :coordinator, :insight_produced], fn
  _event, _measurements, %{insight: insight}, _config ->
    Logger.info("Insight: #{insight.summary}")
end, nil)
```

## License

Apache-2.0
