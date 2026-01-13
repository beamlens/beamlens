# BeamLens

Autonomous supervision for the BEAM.

## The Problem

External tools like Datadog or Prometheus see your application from the outside. They tell you *that* memory is spiking, but not *why*.

To find the root cause, you might SSH in and attach an `iex` shell. By the time you do, the transient state—the stuck process, the bloated mailbox, the expensive query—is often gone.

## The Solution

BeamLens is an Elixir library that runs inside your BEAM application. You add its `Operator` to your own supervision tree, giving it the same access to the runtime that you would have. It observes your system from the inside, with full context of its live state.

## How It Works

The system is built on standard OTP principles.

- **Operator**: A `GenServer` you add to your application's supervision tree. It runs a simple, LLM-driven loop:
    1. Collect a snapshot of system state using a `Skill`.
    2. The LLM analyzes the snapshot and selects a tool (e.g., investigate deeper, send a notification, or wait).
    3. The tool is executed and the loop continues.

    The `Operator` is just another process. If it crashes, your supervisor restarts it.

- **Skills**: Elixir `Behaviours` that expose functinality to the `Operator`. You implement the `Beamlens.Skill` behaviour to provide access to application-specific state, such as ETS table sizes, process mailboxes, or Ecto query statistics.

- **Execution**: Tool execution is sandboxed in a Lua environment by default, preventing unintended side effects.

- **Data Privacy**: You choose your own LLM provider. Telemetry data is processed within your infrastructure and is never sent to BeamLens.

## Execution Modes

Operators support two execution modes:

### Continuous Mode

For always-on monitoring, add operators to your supervision tree:

```elixir
{Beamlens, operators: [:beam]}
```

The LLM controls timing via `wait()` between iterations. This is the default for supervised operators.

### On-Demand Mode

For scheduled or triggered analysis (e.g., Oban workers, alerts):

```elixir
{:ok, notifications} = Beamlens.Operator.run(:beam, client_registry(),
  context: %{reason: "high memory detected"}
)
```

The LLM investigates and calls `done()` when finished, returning notifications generated during analysis. Useful for triggered investigations without running a continuous process.

## Installation

```elixir
def deps do
  [{:beamlens, "~> 0.1.0"}]
end
```

## Quick Start

Set your API key (or configure an [alternative provider](docs/providers.md)):

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

Add to your supervision tree:

```elixir
def start(_type, _args) do
  children = [
    {Beamlens, operators: [:beam]}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

## Built-in Operators

| Operator | Description |
|---------|-------------|
| `:beam` | BEAM VM metrics (memory, processes, schedulers, atoms) |
| `:ets` | ETS table monitoring (counts, memory, largest tables) |
| `:gc` | Garbage collection statistics |
| `:logger` | Application log monitoring (error rates, patterns) |
| `:ports` | Port monitoring (file descriptors, sockets) |
| `:sup` | Supervisor tree monitoring |
| `:system` | OS-level metrics (CPU, memory, disk via `os_mon`) |
| `:ecto` | Database monitoring (requires setup, see below) |
| `:exception` | Exception tracking via Tower |

Start multiple operators:

```elixir
{Beamlens, operators: [:beam, :ets, :gc, :ports, :sup]}
```

Each operator runs independently with its own LLM context.

### Ecto Skill

The Ecto skill requires a custom module:

```elixir
defmodule MyApp.EctoSkill do
  use Beamlens.Skill.Ecto, repo: MyApp.Repo
end
```

Add infrastructure to your supervision tree:

```elixir
children = [
  {Registry, keys: :unique, name: Beamlens.Skill.Ecto.Registry},
  {Beamlens.Skill.Ecto.TelemetryStore, repo: MyApp.Repo},

  {Beamlens, operators: [
    :beam,
    [name: :ecto, skill: MyApp.EctoSkill]
  ]}
]
```

For PostgreSQL, add `{:ecto_psql_extras, "~> 0.8"}` for deeper insights.

### Exception Skill

Requires [Tower](https://github.com/mimiquate/tower):

```elixir
# mix.exs
{:tower, "~> 0.8.6"}

# config/config.exs
config :tower, reporters: [Beamlens.Skill.Exception.ExceptionStore]
```

Then add the operator:

```elixir
{Beamlens, operators: [:beam, :exception]}
```

## Creating Custom Skills

Implement the `Beamlens.Skill` behaviour to monitor your own domains:

```elixir
defmodule MyApp.Skills.Redis do
  @behaviour Beamlens.Skill

  @impl true
  def id, do: :redis

  @impl true
  def description, do: "Redis cache: hit rates, memory, key distribution"

  @impl true
  def system_prompt do
    """
    You are a Redis cache monitor. You track cache health, memory usage,
    and key distribution patterns.

    ## Your Domain
    - Cache hit rates and efficiency
    - Memory usage and eviction pressure

    ## What to Watch For
    - Hit rate < 90%: cache may be ineffective
    - Memory usage > 80%: eviction pressure increasing
    """
  end

  @impl true
  def snapshot do
    %{
      connected: Redix.command!(:redix, ["PING"]) == "PONG",
      memory_used_mb: get_memory_mb(),
      connected_clients: get_client_count()
    }
  end

  @impl true
  def callbacks do
    %{
      "redis_info" => fn -> get_info() end,
      "redis_slowlog" => fn count -> get_slowlog(count) end
    }
  end

  @impl true
  def callback_docs do
    """
    ### redis_info()
    Full Redis INFO as a map.

    ### redis_slowlog(count)
    Recent slow queries. `count` limits results.
    """
  end

  defp get_info, do: # ...
  defp get_slowlog(count), do: # ...
  defp get_memory_mb, do: # ...
  defp get_client_count, do: # ...
end
```

Register your skill:

```elixir
{Beamlens, operators: [
  :beam,
  [name: :redis, skill: MyApp.Skills.Redis]
]}
```

**Guidelines:**

- Write a clear `system_prompt`—it defines the operator's identity and focus
- Prefix callbacks with your skill name (`redis_info`, not `info`)
- Return JSON-safe values (strings, numbers, booleans, lists, maps)
- Keep snapshots fast—they're called frequently
- Write clear `callback_docs`—the LLM uses them to understand your API

## Telemetry

Subscribe to notifications:

```elixir
:telemetry.attach("my-notifications", [:beamlens, :operator, :notification_sent], fn
  _event, _measurements, %{notification: notification}, _config ->
    Logger.warning("BeamLens: #{notification.summary}")
end, nil)
```

## Notification Correlation

The Coordinator receives notifications from all operators and correlates them. When multiple notifications are sent together, it identifies patterns:

- **temporal** — Notifications occurred close in time
- **causal** — One notification caused another
- **symptomatic** — Notifications share a common hidden cause

Subscribe to insights:

```elixir
:telemetry.attach("my-insights", [:beamlens, :coordinator, :insight_produced], fn
  _event, _measurements, %{insight: insight}, _config ->
    Logger.info("Insight: #{insight.summary}")
end, nil)
```

## Configuration

### Compaction

Operators use context compaction to run indefinitely. When the context grows too large, it's summarized:

```elixir
{Beamlens, operators: [
  :beam,
  [name: :ets, skill: Beamlens.Skill.Ets,
   compaction_max_tokens: 100_000,
   compaction_keep_last: 10]
]}
```

- `:compaction_max_tokens` — Threshold before compaction (default: 50,000)
- `:compaction_keep_last` — Recent messages to preserve (default: 5)

Set to ~10% of your model's context window.

### Model Providers

Default is Anthropic Claude Haiku. See [providers.md](docs/providers.md) for OpenAI, Ollama, AWS Bedrock, Google Gemini, and others.

## License

Apache-2.0
