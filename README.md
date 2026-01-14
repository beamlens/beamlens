# beamlens

Adaptive runtime intelligence for the BEAM.
 
Move beyond static supervision. Give your application the capability to self-diagnose incidents, analyze traffic patterns, and optimize its own performance.

## The Result

beamlens translates opaque runtime metrics into semantic explanations.

```elixir
# You trigger an investigation when telemetry spikes
{:ok, result} = Beamlens.Coordinator.run(%{reason: "memory > 90%"})

# beamlens returns the specific root cause based on runtime introspection
result.insights
# => [
#      "Analysis: Process <0.450.0> (MyApp.ImageWorker) is holding 2.1GB binary heap.",
#      "Context: Correlates with 450 concurrent uploads in the last minute.",
#      "Root Cause: Worker pool exhausted; processes are not hibernating after large binary handling."
#    ]
```

## Installation

Add `beamlens` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:beamlens, "~> 0.1.0"}
  ]
end
```

## Quick Start

**1. Select a [provider](docs/providers.md)** or use the default Anthropic one by setting your API key:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

**2. Add to your supervision tree** in `application.ex`:

```elixir
def start(_type, _args) do
  children = [
    # ... your other children
    {Beamlens, client_registry: client_registry()}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end

defp client_registry do
  %{
    primary: "Anthropic",
    clients: [
      %{
        name: "Anthropic",
        provider: "anthropic",
        options: %{model: "claude-haiku-4-5-20251001"}
      }
    ]
  }
end
```

**3. Run a diagnosis** (from an alert handler, Oban job, or IEx):

```elixir
{:ok, result} = Beamlens.Coordinator.run(%{reason: "memory alert..."})
```

## The Problem

OTP is a masterpiece of reliability, but it is static. You define pool sizes, timeouts, and supervision strategies at compile time (or config time).

But production is dynamic. User behavior changes. Traffic patterns shift. A configuration that worked yesterday might be a bottleneck today.

Standard monitoring tools show you what is happening (metrics), but they don't understand why. They cannot tell you that your user traffic has shifted from "write-heavy" to "read-heavy," requiring a different architecture.

## The Solution

beamlens is an investigation engine that lives inside your supervision tree. It doesn't replace your monitoring; it answers the questions your monitoring raises.

You wire it into your system triggers (Telemetry, Oban, or manual administration), and it performs the deep analysis for you.

1. Deep Context: When triggered, it captures internal state that external monitors miss—ETS key distribution, process dictionary size, and scheduler utilization.

2. Semantic Analysis: It uses an LLM to interpret that raw data. Instead of just showing you a graph, it explains why the graph looks that way.

3. Adaptive Feedback: Over time, you can use these insights to optimize configurations or refactor bottlenecks based on actual production behavior.

## Features

* **Sandboxed Analysis**: All investigation logic runs in a restricted environment. The "brain" observes without interfering with the "body."

* **Privacy-First**: Telemetry data is processed within your infrastructure. You choose the LLM provider; your application state is never sent to beamlens servers.

* **Extensible Skills**: Teach beamlens to understand your domain. If you are building a video platform, give it a skill to analyze `ffmpeg` process metrics.

* **Low Overhead**: Agents are dormant until triggered.

## Examples

**1. Triggering from Telemetry**

```elixir
# In your Telemetry handler
def handle_event([:my_app, :memory, :high], _measurements, _metadata, _config) do
  # Trigger an investigation immediately
  {:ok, result} = Beamlens.Coordinator.run(%{reason: "memory alert..."})

  # Log the insights
  Logger.error("Memory Alert Diagnosis: #{inspect(result.insights)}")
end
```

**2. Creating Custom Skills**

You can teach beamlens to understand your specific business logic. For example, if you use a GenServer to batch requests, generic metrics won't help. You need a custom skill.

```elixir
defmodule MyApp.Skills.Batcher do
  @behaviour Beamlens.Skill

  def system_prompt do
    "You are checking the Batcher process. Watch for 'queue_size' > 5000."
  end

  def snapshot do
    %{
      queue_size: MyApp.Batcher.queue_size(),
      pending_jobs: MyApp.Batcher.pending_count()
    }
  end
end
```

**3. Periodic Health Checks (Optimization)**

You can schedule beamlens to run periodically to spot trends before they become alerts.

```elixir
# In a scheduled job (e.g., Oban)
def perform(_job) do
  {:ok, result} = Beamlens.Coordinator.run(%{reason: "daily check..."})
  # Store insights for review
  MyApp.InsightStore.save(result)
end
```

**4. Automated Remediation (Advanced)**

Once you trust the diagnosis, you can authorize beamlens to fix specific issues. This turns beamlens from a passive observer into an active supervisor.

**Note:** This requires explicit opt-in via the callbacks function.

```elixir
defmodule MyApp.Skills.Healer do
  @behaviour Beamlens.Skill

  # Explicitly allow the operator to kill a process
  @impl Beamlens.Skill
  def callbacks do
    %{
      "kill_process" => fn pid_str ->
        Process.exit(pid(pid_str), :kill)
      end
    }
  end
end
```

## License

Apache-2.0
