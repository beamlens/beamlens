defmodule Beamlens.Runner do
  @moduledoc """
  Periodic runner for BeamLens health checks.

  Runs the agent at configurable intervals and logs results.
  Each run is assigned a unique `trace_id` for correlation.
  """

  use GenServer
  require Logger

  alias Beamlens.Telemetry

  defstruct interval: :timer.minutes(5),
            mode: :periodic,
            client_registry: nil,
            last_run_at: nil,
            running: false

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = struct!(__MODULE__, opts)

    if state.mode != :manual do
      schedule_run(5_000)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:run, %{running: true, interval: interval} = state) do
    Logger.warning("[BeamLens] Skipping run - previous run still in progress")
    schedule_run(interval)
    {:noreply, state}
  end

  def handle_info(:run, %{client_registry: client_registry} = state) do
    state = %{state | running: true}
    node = Atom.to_string(Node.self())
    trace_id = Telemetry.generate_trace_id()

    {_result, new_state} =
      Telemetry.span(%{node: node, trace_id: trace_id}, fn ->
        case Beamlens.Agent.run(trace_id: trace_id, client_registry: client_registry) do
          {:ok, analysis} ->
            Logger.info("[BeamLens] Health Analysis: #{analysis.status}",
              trace_id: trace_id
            )

            metadata = %{
              node: node,
              trace_id: trace_id,
              status: analysis.status,
              analysis: analysis,
              tool_count: 0
            }

            new_state = %{state | last_run_at: DateTime.utc_now(), running: false}
            {{{:ok, analysis}, new_state}, %{}, metadata}

          {:error, reason} ->
            Logger.warning("[BeamLens] Agent failed: #{inspect(reason)}",
              trace_id: trace_id
            )

            new_state = %{state | running: false}
            {{{:error, reason}, new_state}, %{}, %{node: node, trace_id: trace_id, error: reason}}
        end
      end)

    schedule_run(state.interval)
    {:noreply, new_state}
  end

  defp schedule_run(interval) do
    Process.send_after(self(), :run, interval)
  end
end
