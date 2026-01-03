defmodule Beamlens.Scheduler do
  @moduledoc """
  Cron-based scheduler for BeamLens health checks.

  Manages multiple named schedules, each triggering `Beamlens.Agent.run/1`
  at cron-specified times. Uses single-flight execution to prevent overlapping
  runs within the same schedule.

  ## Usage

  Add to your supervision tree (requires `Beamlens.TaskSupervisor`):

      children = [
        {Task.Supervisor, name: Beamlens.TaskSupervisor},
        {Beamlens.Scheduler, schedules: [[name: :default, cron: "*/5 * * * *"]]}
      ]

  ## Options

    * `:schedules` - List of schedule keyword lists (see below)
    * `:agent_opts` - Global options merged into all agent runs
    * `:run_fun` - Custom function to call instead of `Beamlens.Agent.run/1` (for testing)

  ## Schedule Options

  Each schedule accepts:

    * `:name` (required) - Unique atom identifying the schedule
    * `:cron` (required) - Standard cron expression (see Cron Syntax below)
    * `:agent_opts` - Per-schedule options that override global options

  ## Cron Syntax

  Standard 5-field cron expressions are supported:

      ┌───────────── minute (0-59)
      │ ┌───────────── hour (0-23)
      │ │ ┌───────────── day of month (1-31)
      │ │ │ ┌───────────── month (1-12)
      │ │ │ │ ┌───────────── day of week (0-6, Sunday=0)
      │ │ │ │ │
      * * * * *

  Examples:
    * `"*/5 * * * *"` - Every 5 minutes
    * `"0 * * * *"` - Every hour at minute 0
    * `"0 2 * * *"` - Daily at 2:00 AM
    * `"0 0 1 * *"` - First day of each month at midnight

  All times are in UTC.

  ## Runtime API

    * `list_schedules/0` - Get all schedules as maps
    * `get_schedule/1` - Get a specific schedule by name
    * `run_now/1` - Trigger immediate run (respects single-flight)

  ## Telemetry Events

  All events include `%{name: atom, cron: string}` metadata:

    * `[:beamlens, :schedule, :triggered]` - Schedule fired, includes `%{source: :scheduled | :manual}`
    * `[:beamlens, :schedule, :skipped]` - Skipped due to already running, includes `%{reason: :already_running}`
    * `[:beamlens, :schedule, :completed]` - Task finished successfully
    * `[:beamlens, :schedule, :failed]` - Task crashed, includes `%{reason: term}`
  """

  use GenServer
  require Logger

  alias Beamlens.Scheduler.Schedule
  alias Beamlens.Telemetry

  # --- Client API ---

  @doc """
  Starts the scheduler with the given options.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns all schedules as sanitized maps.
  """
  @spec list_schedules() :: [map()]
  def list_schedules do
    GenServer.call(__MODULE__, :list_schedules)
  end

  @doc """
  Returns a specific schedule by name, or nil if not found.
  """
  @spec get_schedule(atom()) :: map() | nil
  def get_schedule(name) do
    GenServer.call(__MODULE__, {:get_schedule, name})
  end

  @doc """
  Triggers an immediate run for a schedule.

  Returns `{:error, :already_running}` if the schedule is already executing.
  """
  @spec run_now(atom()) :: :ok | {:error, :not_found | :already_running}
  def run_now(name) do
    GenServer.call(__MODULE__, {:run_now, name})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    schedule_configs = Keyword.get(opts, :schedules, [])
    global_agent_opts = Keyword.get(opts, :agent_opts, [])
    run_fun = Keyword.get(opts, :run_fun, &Beamlens.Agent.run/1)

    case parse_all(schedule_configs) do
      {:ok, schedules} ->
        state = %{
          schedules: start_all_timers(schedules),
          global_agent_opts: global_agent_opts,
          run_fun: run_fun
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list_schedules, _from, state) do
    public = state.schedules |> Map.values() |> Enum.map(&Schedule.to_public_map/1)
    {:reply, public, state}
  end

  def handle_call({:get_schedule, name}, _from, state) do
    result =
      case Map.get(state.schedules, name) do
        nil -> nil
        schedule -> Schedule.to_public_map(schedule)
      end

    {:reply, result, state}
  end

  def handle_call({:run_now, name}, _from, state) do
    case Map.get(state.schedules, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{running: ref} when ref != nil ->
        {:reply, {:error, :already_running}, state}

      schedule ->
        emit_telemetry(:triggered, schedule, %{source: :manual})
        state = spawn_run(state, schedule)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:timer, name}, state) do
    schedule = Map.get(state.schedules, name)

    cond do
      schedule == nil ->
        {:noreply, state}

      # Long-delay guard: timer fired early (clamped), reschedule without running
      NaiveDateTime.compare(NaiveDateTime.utc_now(), schedule.next_run_at) == :lt ->
        state = reschedule(state, name)
        {:noreply, state}

      # Already running: skip, reschedule for next occurrence
      schedule.running != nil ->
        Logger.debug("[BeamLens] Skipping #{name} - already running")
        emit_telemetry(:skipped, schedule, %{reason: :already_running})
        state = advance_and_reschedule(state, name)
        {:noreply, state}

      # Time to run
      true ->
        emit_telemetry(:triggered, schedule, %{source: :scheduled})
        state = state |> advance_and_reschedule(name) |> spawn_run(name)
        {:noreply, state}
    end
  end

  # Handle task result message (ignore - we handle completion via :DOWN)
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_schedule_by_ref(state.schedules, ref) do
      nil ->
        {:noreply, state}

      {name, schedule} ->
        now = NaiveDateTime.utc_now()

        updated = %{
          schedule
          | running: nil,
            last_run_at: now,
            run_count: schedule.run_count + 1
        }

        event = if reason == :normal, do: :completed, else: :failed
        emit_telemetry(event, updated, %{reason: reason})

        state = put_in(state.schedules[name], updated)
        {:noreply, state}
    end
  end

  # --- Private Helpers ---

  defp parse_all(configs) do
    Enum.reduce_while(configs, {:ok, %{}}, fn config, {:ok, acc} ->
      case Schedule.new(config) do
        {:ok, schedule} ->
          if Map.has_key?(acc, schedule.name) do
            {:halt, {:error, {:duplicate_schedule, schedule.name}}}
          else
            {:cont, {:ok, Map.put(acc, schedule.name, schedule)}}
          end

        {:error, {:invalid_cron, name, reason}} ->
          {:halt, {:error, {:invalid_cron, name, reason}}}
      end
    end)
  end

  defp start_all_timers(schedules) do
    Map.new(schedules, fn {name, schedule} ->
      {name, start_timer(schedule)}
    end)
  end

  defp start_timer(schedule) do
    {ms, _type} = Schedule.ms_until_next_run(schedule)
    timer_ref = Process.send_after(self(), {:timer, schedule.name}, ms)
    %{schedule | timer_ref: timer_ref}
  end

  defp reschedule(state, name) do
    schedule = state.schedules[name]
    cancel_timer(schedule)
    updated = start_timer(schedule)
    put_in(state.schedules[name], updated)
  end

  defp advance_and_reschedule(state, name) do
    schedule = state.schedules[name]
    cancel_timer(schedule)
    next = Schedule.compute_next_run(schedule.cron)
    updated = start_timer(%{schedule | next_run_at: next})
    put_in(state.schedules[name], updated)
  end

  defp cancel_timer(%{timer_ref: nil}), do: :ok
  defp cancel_timer(%{timer_ref: ref}), do: Process.cancel_timer(ref)

  defp spawn_run(state, %Schedule{} = schedule), do: spawn_run(state, schedule.name)

  defp spawn_run(state, name) when is_atom(name) do
    schedule = state.schedules[name]
    trace_id = Telemetry.generate_trace_id()
    node = Atom.to_string(Node.self())

    # Merge global opts with per-schedule overrides
    agent_opts =
      state.global_agent_opts
      |> Keyword.merge(schedule.agent_opts)
      |> Keyword.put(:trace_id, trace_id)

    run_fun = state.run_fun

    task =
      Task.Supervisor.async_nolink(Beamlens.TaskSupervisor, fn ->
        # Wrap in agent telemetry span for parity with old Runner
        Telemetry.span(%{node: node, trace_id: trace_id}, fn ->
          case run_fun.(agent_opts) do
            {:ok, analysis} ->
              metadata = %{
                node: node,
                trace_id: trace_id,
                status: analysis.status,
                analysis: analysis,
                tool_count: 0
              }

              {{{:ok, analysis}, nil}, %{}, metadata}

            {:error, reason} ->
              {{{:error, reason}, nil}, %{}, %{node: node, trace_id: trace_id, error: reason}}
          end
        end)
      end)

    updated = %{schedule | running: task.ref}
    put_in(state.schedules[name], updated)
  end

  defp find_schedule_by_ref(schedules, ref) do
    Enum.find_value(schedules, fn {name, schedule} ->
      if schedule.running == ref, do: {name, schedule}
    end)
  end

  defp emit_telemetry(event, schedule, extra) do
    :telemetry.execute(
      [:beamlens, :schedule, event],
      %{system_time: System.system_time()},
      Map.merge(%{name: schedule.name, cron: schedule.cron_string}, extra)
    )
  end
end
