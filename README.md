# BeamLens

A minimal, safe AI agent that monitors BEAM VM health and generates analyses using Claude Haiku.

## Features

- **Safe by design**: Read-only metrics, no PII/PHI exposure, zero side effects
- **Cron scheduling**: Standard cron syntax for flexible scheduling
- **Structured output**: Returns typed `HealthAnalysis` structs, not raw text
- **Telemetry integration**: Emits events for observability
- **Claude-powered**: Uses Haiku for cost-effective, intelligent analysis (~$0.001/run)

## Installation

```elixir
def deps do
  [{:beamlens, github: "bradleygolden/beamlens"}]
end
```

## Quick Start

Add to your supervision tree with a `client_registry` configuration:

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
              options: %{model: "claude-haiku-4-5-20250514", api_key: System.get_env("ANTHROPIC_API_KEY")}}
          ]
        }
      ]}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

Or run manually:

```elixir
client_registry = %{
  primary: "Claude",
  clients: [
    %{name: "Claude", provider: "anthropic",
      options: %{model: "claude-haiku-4-5-20250514", api_key: System.get_env("ANTHROPIC_API_KEY")}}
  ]
}

{:ok, analysis} = Beamlens.run(client_registry: client_registry)

analysis.status          #=> :healthy
analysis.summary         #=> "BEAM VM is operating normally..."
analysis.concerns        #=> []
analysis.recommendations #=> []
```

## Documentation

See the module documentation for detailed usage:

- `Beamlens` - Main module with full configuration options
- `Beamlens.Scheduler` - Cron scheduling details
- `Beamlens.Telemetry` - Telemetry events

### Attaching to all events

```elixir
:telemetry.attach_many(
  "beamlens-logger",
  Beamlens.Telemetry.event_names(),
  &MyHandler.handle_event/4,
  nil
)
```

## What it monitors

BeamLens gathers safe, read-only VM metrics:

- OTP release version
- Scheduler count and utilization
- Memory breakdown (processes, atoms, binaries, ETS)
- Process and port counts
- System uptime

## License

MIT
