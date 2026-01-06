# BeamLens

**You sleep. Your app doesn't. Neither does BeamLens.**

Your application runs around the clock. You can't watch it around the clock. BeamLens bridges that gap—an AI agent that continuously monitors your application's health, surfacing issues whether you're in a meeting, asleep, or on vacation.

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

BeamLens runs in your supervision tree. Schedule it with a cron expression for continuous monitoring, or call `Beamlens.run()` directly when you need it. It emits telemetry events you can consume with your existing observability stack.

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
    {Beamlens, schedules: [{:default, "*/5 * * * *"}]}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

## Manual Triggering

Run the agent on-demand without scheduling—useful for debugging, one-off checks, or integrating with your own triggers:

```elixir
case Beamlens.run() do
  {:ok, analysis} ->
    IO.puts("Status: #{analysis.status}")
    IO.puts("Summary: #{analysis.summary}")

    if analysis.concerns != [] do
      IO.puts("Concerns: #{Enum.join(analysis.concerns, ", ")}")
    end

  {:error, reason} ->
    IO.puts("Analysis failed: #{inspect(reason)}")
end
```

The `HealthAnalysis` struct contains:

| Field | Type | Description |
|-------|------|-------------|
| `status` | `:healthy \| :warning \| :critical` | Overall health status |
| `summary` | `String.t()` | Brief 1-2 sentence summary |
| `concerns` | `[String.t()]` | List of identified concerns |
| `recommendations` | `[String.t()]` | Actionable next steps |
| `events` | `[Events.t()]` | Execution trace (LLM calls, tool calls, judge reviews) |

### Quality Verification

By default, a judge agent reviews each analysis to verify conclusions are supported by collected data. If the judge finds issues, the agent automatically retries with feedback.

```elixir
# Disable judge for faster development runs
{:ok, analysis} = Beamlens.run(judge: false)

# Increase max retries (default: 2)
{:ok, analysis} = Beamlens.run(max_judge_retries: 3)
```

### Bring Your Own Model (Coming Soon)

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
  schedules: [{:default, "*/5 * * * *"}],
  circuit_breaker: [enabled: true, failure_threshold: 5, reset_timeout: 30_000]}
```

## Documentation

- `Beamlens` — Main module with full configuration options
- `Beamlens.Agent` — AI agent implementation details
- `Beamlens.Judge` — Quality verification agent
- `Beamlens.Scheduler` — Cron scheduling details
- `Beamlens.Telemetry` — Telemetry events for observability

## License

Apache-2.0
