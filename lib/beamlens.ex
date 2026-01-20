defmodule Beamlens do
  @moduledoc """
  BeamLens - AI-powered BEAM VM health monitoring.

  Specialized **operators** autonomously monitor BEAM VM metrics using LLM-driven
  loops, detect anomalies, and send notifications via telemetry when issues are found.

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────────┐
  │                      Operator (Autonomous)                  │
  │  1. LLM controls timing via wait tool                       │
  │  2. Collects snapshots, analyzes patterns                   │
  │  3. Sends notifications via telemetry when anomalies detected│
  │  4. Maintains state: healthy → observing → warning → critical│
  └─────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌────────────────────────────┐
              │     Telemetry Events       │
              │  [:beamlens, :operator, *] │
              │  - notification_sent       │
              │  - state_change            │
              │  - iteration_start         │
              └────────────────────────────┘
  ```

  ## Installation

  Add to your dependencies:

      {:beamlens, "~> 0.2.0"}

  ## Supervision Tree Setup

  Add BeamLens to your application's supervision tree:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            {Beamlens, skills: [Beamlens.Skill.Beam]}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ## Configuration Options

  Options passed to `Beamlens`:

    * `:skills` - List of skill modules to start (defaults to all built-ins)

  ### LLM Provider Configuration

  By default, BeamLens uses Anthropic (requires `ANTHROPIC_API_KEY` env var).
  Configure a custom provider via `:client_registry` when running investigations:

      # Ollama (local)
      {:ok, result} = Beamlens.Coordinator.run(%{reason: "memory alert"},
        client_registry: %{
          primary: "Ollama",
          clients: [
            %{
              name: "Ollama",
              provider: "openai-generic",
              options: %{base_url: "http://localhost:11434/v1", model: "qwen3:4b"}
            }
          ]
        })

      # Google AI (Gemini) - requires GOOGLE_API_KEY env var
      {:ok, result} = Beamlens.Coordinator.run(%{reason: "memory alert"},
        client_registry: %{
          primary: "Gemini",
          clients: [
            %{
              name: "Gemini",
              provider: "google-ai",
              options: %{model: "gemini-flash-lite-latest"}
            }
          ]
        })

  Supported providers include: `anthropic`, `openai`, `google-ai`, `openai-generic` (Ollama),
  `aws-bedrock`, `azure-openai`, and more.

  ### Operator Configuration

  Operators are specified as skill modules:

      # Built-in BEAM operator
      Beamlens.Skill.Beam

      # Custom skill module
      MyApp.Skill.Postgres

  ## Runtime API

      # List all running operators
      Beamlens.list_operators()

      # Get status of a specific operator
      Beamlens.operator_status(Beamlens.Skill.Beam)

  ## Telemetry Events

  BeamLens emits telemetry events for observability. See `Beamlens.Telemetry`
  for the full list of events.

  Subscribe to notification events:

      :telemetry.attach("beamlens-notifications", [:beamlens, :operator, :notification_sent], fn
        _event, _measurements, metadata, _config ->
          IO.inspect(metadata, label: "Notification sent")
      end, nil)
  """

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc false
  def start_link(opts) do
    Beamlens.Supervisor.start_link(opts)
  end

  @doc """
  Lists all running operators with their status.

  Returns a list of maps with operator information including:
    * `:name` - Operator name
    * `:operator` - Domain being monitored
    * `:state` - Current operator state (healthy, observing, warning, critical)
    * `:running` - Whether the operator loop is running
    * `:title` - Human-readable title from skill module
    * `:description` - Brief description from skill module
  """
  defdelegate list_operators(), to: Beamlens.Operator.Supervisor

  @doc """
  Gets the status of a specific operator.

  Returns `{:ok, status}` on success, `{:error, :not_found}` if operator doesn't exist.
  """
  defdelegate operator_status(name), to: Beamlens.Operator.Supervisor
end
