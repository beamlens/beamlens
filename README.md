# BeamLens

**Your BEAM Expert, Always On**

An AI agent that runs alongside your Elixir app—observing your runtime, explaining what it sees, giving you context to investigate faster.

## The Problem

Scheduler utilization spikes. Memory grows. A GenServer queue backs up.

You open your dashboards—Prometheus, Datadog, AppSignal. The data is there. But before you can investigate, you're correlating metrics, cross-referencing logs, building context.

BeamLens assembles that context for you—a starting point to verify, not a black box to trust.

## Start With Context, Not Just Metrics

```
Without BeamLens:
scheduler_utilization: 0.87
memory_total: 2147483648
process_count: 12847

With BeamLens:
"Scheduler utilization at 87%. Memory usage elevated but stable.
Process count within normal range. No immediate concerns detected."
```

## Why BeamLens

- **BEAM-Native Tooling** — Direct access to BEAM instrumentation: schedulers, memory, processes, atoms. The context generic APM tools can't see.

- **Read-Only by Design** — Zero writes to your system. Type-safe outputs. Your data stays in your infrastructure.

- **Supplements Your Stack** — Works alongside Prometheus, Datadog, AppSignal, Sentry—whatever you're already using.

- **Bring Your Own Model** — Anthropic, OpenAI, AWS Bedrock, Google Gemini, Azure OpenAI, Ollama, OpenRouter, Together AI. Your keys, your infrastructure.

## Prerequisites

**Rust toolchain** is required to compile `baml_elixir` from source (temporary requirement until precompiled NIFs are available):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

## Installation

```elixir
def deps do
  [{:beamlens, "~> 0.1.0"}]
end
```

## Quick Start

BeamLens uses BAML's [ClientRegistry](https://docs.boundaryml.com/guide/baml-advanced/client-registry) to configure LLM providers at runtime.

Add to your supervision tree:

```elixir
def start(_type, _args) do
  children = [
    {Beamlens,
      schedules: [{:default, "*/5 * * * *"}],
      agent_opts: [
        client_registry: %{
          primary: "Claude",
          clients: [
            %{name: "Claude", provider: "anthropic",
              options: %{model: "claude-haiku-4-5-20251001", api_key: System.get_env("ANTHROPIC_API_KEY")}}
          ]
        }
      ]}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

Or run manually:

```elixir
{:ok, analysis} = Beamlens.run(client_registry: client_registry)

analysis.status          #=> :healthy
analysis.summary         #=> "BEAM VM is operating normally..."
analysis.concerns        #=> []
analysis.recommendations #=> []
```

### Bring Your Own Model

```elixir
# Ollama (run completely offline)
%{primary: "Ollama", clients: [
  %{name: "Ollama", provider: "openai-generic",
    options: %{base_url: "http://localhost:11434/v1", model: "llama4"}}
]}

# AWS Bedrock
%{primary: "Bedrock", clients: [
  %{name: "Bedrock", provider: "aws-bedrock",
    options: %{model: "anthropic.claude-haiku-4-5-v1:0", region: "us-east-1"}}
]}

# OpenAI
%{primary: "OpenAI", clients: [
  %{name: "OpenAI", provider: "openai",
    options: %{model: "gpt-4o-mini", api_key: System.get_env("OPENAI_API_KEY")}}
]}
```

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
- `Beamlens.Scheduler` — Cron scheduling details
- `Beamlens.Telemetry` — Telemetry events for observability

## License

Apache-2.0
