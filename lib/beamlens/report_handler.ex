defmodule Beamlens.ReportHandler do
  @moduledoc """
  Handles watcher reports by triggering Agent investigation.

  A thin GenServer that subscribes to ReportQueue and calls
  `Beamlens.Agent.investigate/2` when reports arrive.

  ## Trigger Modes

    * `:on_report` - Automatically investigate when reports arrive (default)
    * `:manual` - Only investigate via `investigate/1`

  ## Example

      # In supervision tree
      {Beamlens.ReportHandler, trigger: :on_report}

      # Manual investigation
      Beamlens.ReportHandler.investigate()
  """

  use GenServer

  alias Beamlens.{Agent, ReportQueue}

  defstruct [:trigger_mode, :agent_opts]

  @doc """
  Starts the ReportHandler GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Manually triggers investigation of pending reports.

  Returns `{:ok, analysis}` if reports were processed,
  `{:ok, :no_reports}` if no reports were pending.
  """
  def investigate(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:investigate, opts}, :timer.minutes(5))
  end

  @doc """
  Checks if there are pending reports to investigate.
  """
  def pending?(server \\ __MODULE__) do
    GenServer.call(server, :pending?)
  end

  @impl true
  def init(opts) do
    trigger_mode = Keyword.get(opts, :trigger, :on_report)
    agent_opts = Keyword.get(opts, :agent_opts, [])

    if trigger_mode == :on_report do
      ReportQueue.subscribe()
    end

    emit_telemetry(:started, %{trigger_mode: trigger_mode})

    {:ok, %__MODULE__{trigger_mode: trigger_mode, agent_opts: agent_opts}}
  end

  @impl true
  def handle_call({:investigate, opts}, _from, state) do
    merged_opts = Keyword.merge(state.agent_opts, opts)
    reports = ReportQueue.take_all()
    result = Agent.investigate(reports, merged_opts)
    {:reply, result, state}
  end

  def handle_call(:pending?, _from, state) do
    {:reply, ReportQueue.pending?(), state}
  end

  @impl true
  def handle_info({:report_available, _report}, %{trigger_mode: :on_report} = state) do
    reports = ReportQueue.take_all()

    case Agent.investigate(reports, state.agent_opts) do
      {:ok, :no_reports} ->
        :ok

      {:ok, analysis} ->
        emit_telemetry(:investigation_completed, %{status: analysis.status})

      {:error, reason} ->
        emit_telemetry(:investigation_failed, %{reason: reason})
    end

    {:noreply, state}
  end

  def handle_info({:report_available, _report}, state) do
    {:noreply, state}
  end

  defp emit_telemetry(event, extra) do
    :telemetry.execute(
      [:beamlens, :report_handler, event],
      %{system_time: System.system_time()},
      extra
    )
  end
end
