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
| `:logger` | Application log monitoring (error rates, patterns, module analysis) |
| `:ports` | Port monitoring (file descriptors, sockets) |
| `:sup` | Supervisor tree monitoring |
| `:system` | OS-level metrics (CPU load, memory, disk usage via os_mon) |
| `:ecto` | Database monitoring (requires custom domain module, see below) |
| `:exception` | Exception tracking via Tower (error patterns, stacktraces) |

Start multiple watchers:

```elixir
{Beamlens, watchers: [:beam, :ets, :gc, :ports, :sup]}
```

Each watcher runs independently with its own LLM context, monitoring its specific domain.

### Ecto Skill

The Ecto skill requires a custom module and supporting infrastructure.

**Step 1:** Create a skill module configured with your Repo:

```elixir
defmodule MyApp.EctoSkill do
  use Beamlens.Skill.Ecto, repo: MyApp.Repo
end
```

**Step 2:** Add the required components to your supervision tree:

```elixir
def start(_type, _args) do
  children = [
    # Ecto skill infrastructure (must be started before Beamlens)
    {Registry, keys: :unique, name: Beamlens.Skill.Ecto.Registry},
    {Beamlens.Skill.Ecto.TelemetryStore, repo: MyApp.Repo},

    # Beamlens with Ecto operator
    {Beamlens, operators: [
      :beam,
      [name: :ecto, skill_module: MyApp.EctoSkill]
    ]}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

For PostgreSQL, add the optional dependency for deeper database insights:

```elixir
{:ecto_psql_extras, "~> 0.8"}
```

### Exception Skill

The Exception skill captures application exceptions via [Tower](https://github.com/mimiquate/tower).

**Step 1:** Add Tower to your dependencies:

```elixir
{:tower, "~> 0.8.6"}
```

**Step 2:** Configure Tower with the ExceptionStore reporter:

```elixir
# config/config.exs
config :tower,
  reporters: [Beamlens.Skill.Exception.ExceptionStore]
```

**Step 3:** Add the exception operator:

```elixir
{Beamlens, operators: [:beam, :exception]}
```

> **Note:** Exception messages and stacktraces may contain sensitive data (file paths, variable values). Ensure your exception handling does not expose PII before enabling this operator.

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

## Configuration

### Compaction

Watchers and the coordinator use context compaction to run indefinitely without exceeding the LLM's context window. When the context grows too large, it's summarized while preserving key information.

Configure compaction per-watcher or globally:

```elixir
{Beamlens, operators: [
  :beam,
  [name: :ets, skill_module: Beamlens.Skill.Ets,
   compaction_max_tokens: 100_000,
   compaction_keep_last: 10]
]}
```

Options:
- `:compaction_max_tokens` — Token threshold before compaction triggers (default: 50,000)
- `:compaction_keep_last` — Recent messages to keep verbatim after compaction (default: 5)

**Sizing guidance:** Set `:compaction_max_tokens` to roughly 10% of your model's context window. This leaves ample room for the compacted summary, new messages, and system prompts. For a 200k context window, 20k is reasonable. For smaller windows (e.g., 32k), reduce to 3k.

## License

Apache-2.0
