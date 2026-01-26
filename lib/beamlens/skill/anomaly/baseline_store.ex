defmodule Beamlens.Skill.Anomaly.BaselineStore do
  @moduledoc """
  Stores and manages learned metric baselines using ETS cache.

  Baselines are calculated from historical metric data and used for
  anomaly detection. This module provides fast in-memory access with
  optional DETS persistence for survival across restarts.

  All operations are read-only with minimal overhead.
  """

  use GenServer
  alias Beamlens.Skill.Anomaly.Statistics

  @default_ets_table :beamlens_baselines
  @default_auto_save_interval_ms :timer.minutes(5)

  defstruct [:ets_table, :dets_table, :dets_file, :timer_ref, :auto_save_enabled]

  @doc """
  Start the baseline store with options.

  ## Options

    * `:ets_table` - ETS table name (default: :beamlens_baselines)
    * `:dets_file` - DETS file path for persistence (optional, enables persistence)
    * `:auto_save_interval_ms` - Auto-save interval (default: 5 minutes)
  """
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])

    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    ets_table = Keyword.get(opts, :ets_table, @default_ets_table)
    dets_file = Keyword.get(opts, :dets_file)

    auto_save_interval_ms =
      Keyword.get(opts, :auto_save_interval_ms, @default_auto_save_interval_ms)

    ets_table_ref = :ets.new(ets_table, [:set, :protected, :named_table])

    state = %__MODULE__{
      ets_table: ets_table_ref,
      dets_table: nil,
      dets_file: dets_file,
      timer_ref: nil,
      auto_save_enabled: false
    }

    state =
      if dets_file do
        open_dets(dets_file, state)
      else
        state
      end

    state =
      if state.dets_table do
        start_auto_save(auto_save_interval_ms, state)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    if state.dets_table do
      :dets.close(state.dets_table)
    end

    :ets.delete(state.ets_table)
    :ok
  end

  @impl true
  def handle_call({:get_baseline, skill, metric}, _from, state) do
    baseline =
      case :ets.lookup(state.ets_table, {skill, metric}) do
        [{{_s, _m}, baseline}] -> baseline
        [] -> nil
      end

    {:reply, baseline, state}
  end

  @impl true
  def handle_call({:update_baseline, skill, metric, samples}, _from, state) do
    baseline = calculate_baseline_from_samples(skill, metric, samples)

    key = {skill, metric}
    :ets.insert(state.ets_table, {key, baseline})
    async_dets_insert(state.dets_table, key, baseline)

    {:reply, {:ok, baseline}, state}
  end

  @impl true
  def handle_call({:clear, skill, metric}, _from, state) do
    key = {skill, metric}
    :ets.delete(state.ets_table, key)
    async_dets_delete(state.dets_table, key)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_all_baselines, _from, state) do
    baselines =
      :ets.tab2list(state.ets_table)
      |> Enum.map(fn {{skill, metric}, baseline} ->
        Map.put(baseline, :skill, skill)
        |> Map.put(:metric, metric)
      end)

    {:reply, baselines, state}
  end

  @impl true
  def handle_call(:save_to_dets, _from, state) do
    result =
      if state.dets_table do
        save_all_to_dets(state)
      else
        {:error, :dets_not_enabled}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:auto_save, state) do
    if state.dets_table do
      save_all_to_dets(state)
    end

    interval =
      Application.get_env(:beamlens, :monitor, [])
      |> Keyword.get(:auto_save_interval_ms, @default_auto_save_interval_ms)

    timer_ref = Process.send_after(self(), :auto_save, interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  defp open_dets(dets_file, state) do
    dets_file_path = Path.expand(dets_file)
    dets_table_name = :"#{state.ets_table}_dets"

    case :dets.open_file(
           dets_table_name,
           [{:file, String.to_charlist(dets_file_path)}]
         ) do
      {:ok, dets_table} ->
        load_from_dets(dets_table, state)

        %{state | dets_table: dets_table}

      {:error, reason} ->
        :telemetry.execute(
          [:beamlens, :anomaly, :baseline_store, :dets_open_failed],
          %{system_time: System.system_time()},
          %{file: dets_file_path, reason: reason}
        )

        state
    end
  end

  defp load_from_dets(dets_table, state) do
    :dets.traverse(dets_table, fn {key, baseline} ->
      :ets.insert(state.ets_table, {key, baseline})
      :continue
    end)
  end

  defp save_all_to_dets(state) do
    :ets.foldl(
      fn {key, baseline}, :ok ->
        :dets.insert(state.dets_table, {key, baseline})
        :ok
      end,
      :ok,
      state.ets_table
    )
  end

  defp start_auto_save(interval_ms, state) do
    timer_ref = Process.send_after(self(), :auto_save, interval_ms)
    %{state | timer_ref: timer_ref, auto_save_enabled: true}
  end

  defp async_dets_insert(nil, _key, _value), do: :ok

  defp async_dets_insert(dets_table, key, value) do
    case Process.whereis(Beamlens.TaskSupervisor) do
      nil ->
        :ok

      _pid ->
        Task.Supervisor.start_child(Beamlens.TaskSupervisor, fn ->
          do_dets_insert(dets_table, key, value)
        end)
    end
  end

  defp do_dets_insert(dets_table, key, value) do
    case :dets.insert(dets_table, {key, value}) do
      :ok ->
        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:beamlens, :anomaly, :baseline_store, :dets_insert_failed],
          %{system_time: System.system_time()},
          %{key: key, reason: reason}
        )
    end
  end

  defp async_dets_delete(nil, _key), do: :ok

  defp async_dets_delete(dets_table, key) do
    case Process.whereis(Beamlens.TaskSupervisor) do
      nil ->
        :ok

      _pid ->
        Task.Supervisor.start_child(Beamlens.TaskSupervisor, fn ->
          do_dets_delete(dets_table, key)
        end)
    end
  end

  defp do_dets_delete(dets_table, key) do
    case :dets.delete(dets_table, key) do
      :ok ->
        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:beamlens, :anomaly, :baseline_store, :dets_delete_failed],
          %{system_time: System.system_time()},
          %{key: key, reason: reason}
        )
    end
  end

  defp calculate_baseline_from_samples(skill, metric, samples) do
    baseline = Statistics.calculate_baseline(samples)

    Map.put(baseline, :last_updated, System.system_time(:millisecond))
    |> Map.put(:skill, skill)
    |> Map.put(:metric, metric)
  end

  @doc """
  Get a baseline for a specific skill/metric.

  Returns nil if no baseline has been learned yet.
  """
  def get_baseline(store \\ __MODULE__, skill, metric) do
    GenServer.call(store, {:get_baseline, skill, metric})
  end

  @doc """
  Calculate and store a baseline from samples.

  Accepts a list of metric samples and calculates statistical baseline.
  """
  def update_baseline(store \\ __MODULE__, skill, metric, samples) do
    GenServer.call(store, {:update_baseline, skill, metric, samples})
  end

  @doc """
  Clear a baseline for a specific skill/metric.
  """
  def clear(store \\ __MODULE__, skill, metric) do
    GenServer.call(store, {:clear, skill, metric})
  end

  @doc """
  Get all stored baselines.
  """
  def get_all_baselines(store \\ __MODULE__) do
    GenServer.call(store, :get_all_baselines)
  end

  @doc """
  Manually trigger save to DETS (if persistence is enabled).
  """
  def save_to_dets(store \\ __MODULE__) do
    GenServer.call(store, :save_to_dets)
  end
end
