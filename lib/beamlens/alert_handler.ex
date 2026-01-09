defmodule Beamlens.AlertHandler do
  @moduledoc """
  Handles watcher alerts by triggering Agent investigation.

  A thin GenServer that subscribes to AlertQueue and calls
  `Beamlens.Agent.investigate/2` when alerts arrive.

  ## Trigger Modes

    * `:on_alert` - Automatically investigate when alerts arrive (default)
    * `:manual` - Only investigate via `investigate/1`

  ## Example

      # In supervision tree
      {Beamlens.AlertHandler, trigger: :on_alert}

      # Manual investigation
      Beamlens.AlertHandler.investigate()
  """

  use GenServer

  alias Beamlens.{Agent, AlertQueue}

  defstruct [:trigger_mode, :agent_opts]

  @doc """
  Starts the AlertHandler GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Manually triggers investigation of pending alerts.

  Returns `{:ok, analysis}` if alerts were processed,
  `{:ok, :no_alerts}` if no alerts were pending.
  """
  def investigate(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:investigate, opts}, :timer.minutes(5))
  end

  @doc """
  Checks if there are pending alerts to investigate.
  """
  def pending?(server \\ __MODULE__) do
    GenServer.call(server, :pending?)
  end

  @impl true
  def init(opts) do
    trigger_mode = Keyword.get(opts, :trigger, :on_alert)
    agent_opts = Keyword.get(opts, :agent_opts, [])

    if trigger_mode == :on_alert do
      AlertQueue.subscribe()
    end

    emit_telemetry(:started, %{trigger_mode: trigger_mode})

    {:ok, %__MODULE__{trigger_mode: trigger_mode, agent_opts: agent_opts}}
  end

  @impl true
  def handle_call({:investigate, opts}, _from, state) do
    merged_opts = Keyword.merge(state.agent_opts, opts)
    alerts = AlertQueue.take_all()
    result = Agent.investigate(alerts, merged_opts)
    {:reply, result, state}
  end

  def handle_call(:pending?, _from, state) do
    {:reply, AlertQueue.pending?(), state}
  end

  @impl true
  def handle_info({:alert_available, _alert}, %{trigger_mode: :on_alert} = state) do
    alerts = AlertQueue.take_all()

    case Agent.investigate(alerts, state.agent_opts) do
      {:ok, :no_alerts} ->
        :ok

      {:ok, analysis} ->
        emit_investigation_telemetry(:complete, %{status: analysis.status})

      {:error, reason} ->
        emit_investigation_telemetry(:error, %{reason: reason})
    end

    {:noreply, state}
  end

  def handle_info({:alert_available, _alert}, state) do
    {:noreply, state}
  end

  defp emit_telemetry(event, extra) do
    :telemetry.execute(
      [:beamlens, :alert_handler, event],
      %{system_time: System.system_time()},
      extra
    )
  end

  defp emit_investigation_telemetry(event, extra) do
    :telemetry.execute(
      [:beamlens, :alert_handler, :investigation, event],
      %{system_time: System.system_time()},
      extra
    )
  end
end
