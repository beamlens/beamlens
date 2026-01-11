defmodule Beamlens do
  @moduledoc """
  BeamLens - AI-powered BEAM VM health monitoring.

  Specialized **operators** autonomously monitor BEAM VM metrics using LLM-driven
  loops, detect anomalies, and fire alerts via telemetry when issues are found.

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────────┐
  │                      Operator (Autonomous)                  │
  │  1. LLM controls timing via wait tool                       │
  │  2. Collects snapshots, analyzes patterns                   │
  │  3. Fires alerts via telemetry when anomalies detected      │
  │  4. Maintains state: healthy → observing → warning → critical│
  └─────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌────────────────────────────┐
              │     Telemetry Events       │
              │  [:beamlens, :operator, *] │
              │  - alert_fired             │
              │  - state_change            │
              │  - iteration_start         │
              └────────────────────────────┘
  ```

  ## Installation

  Add to your dependencies:

      {:beamlens, "~> 0.1.0"}

  ## Supervision Tree Setup

  Add BeamLens to your application's supervision tree:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            {Beamlens, operators: [:beam]}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ## Configuration Options

  Options passed to `Beamlens`:

    * `:operators` - List of operator configurations (see below)
    * `:client_registry` - LLM provider configuration (see below)

  ### LLM Provider Configuration

  By default, BeamLens uses Anthropic (requires `ANTHROPIC_API_KEY` env var).
  Configure a custom provider via `:client_registry`:

      {Beamlens,
        operators: [:beam],
        client_registry: %{
          primary: "Ollama",
          clients: [
            %{
              name: "Ollama",
              provider: "openai-generic",
              options: %{base_url: "http://localhost:11434/v1", model: "qwen3:4b"}
            }
          ]
        }}

  Supported providers include: `anthropic`, `openai`, `openai-generic` (Ollama),
  `aws-bedrock`, `google-ai`, `azure-openai`, and more.

  ### Operator Configuration

  Operators can be specified as atoms or keyword lists:

      # Built-in BEAM operator
      :beam

      # Custom domain module
      [name: :postgres, domain_module: MyApp.Domain.Postgres]

  ## Runtime API

      # List all running operators
      Beamlens.list_operators()

      # Get status of a specific operator
      Beamlens.operator_status(:beam)

  ## Telemetry Events

  BeamLens emits telemetry events for observability. See `Beamlens.Telemetry`
  for the full list of events.

  Subscribe to alert events:

      :telemetry.attach("beamlens-alerts", [:beamlens, :operator, :alert_fired], fn
        _event, _measurements, metadata, _config ->
          IO.inspect(metadata, label: "Alert fired")
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
  """
  defdelegate list_operators(), to: Beamlens.Operator.Supervisor

  @doc """
  Gets the status of a specific operator.

  Returns `{:ok, status}` on success, `{:error, :not_found}` if operator doesn't exist.
  """
  defdelegate operator_status(name), to: Beamlens.Operator.Supervisor
end
