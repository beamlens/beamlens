defmodule Beamlens.Skill.Monitor.MetricStore do
  @moduledoc """
  Stores time-series metric samples in an ETS table.

  Periodically samples metrics and maintains a configurable history window.
  All operations are read-only with minimal overhead.
  """

  use GenServer

  @default_history_minutes 60
  @default_sample_interval_ms 30_000

  defstruct [:ets_table, :max_samples, :timer_ref]

  @doc """
  Start the metric store with options.
  """
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])

    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    sample_interval_ms = Keyword.get(opts, :sample_interval_ms, @default_sample_interval_ms)
    history_minutes = Keyword.get(opts, :history_minutes, @default_history_minutes)
    max_samples = div(history_minutes * 60_000, sample_interval_ms)

    ets_table = :ets.new(:beamlens_metrics, [:set, :protected])

    timer_ref = Process.send_after(self(), :prune, sample_interval_ms)

    state = %__MODULE__{
      ets_table: ets_table,
      max_samples: max_samples,
      timer_ref: timer_ref
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    :ets.delete(state.ets_table)
    :ok
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = System.system_time(:millisecond) - state.max_samples * @default_sample_interval_ms
    prune_old_samples(state.ets_table, cutoff)
    timer_ref = Process.send_after(self(), :prune, @default_sample_interval_ms)

    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_call({:add_sample, skill, metric, value}, _from, state) do
    timestamp = System.system_time(:millisecond)
    key = {skill, metric, timestamp}

    sample = %{
      timestamp: timestamp,
      skill: skill,
      metric: metric,
      value: value
    }

    :ets.insert(state.ets_table, {key, sample})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_samples, skill, metric, since_ms}, _from, state) do
    cutoff = System.system_time(:millisecond) - since_ms

    samples =
      :ets.tab2list(state.ets_table)
      |> Enum.filter(fn {{s, m, _ts}, _sample} ->
        s == skill and m == metric
      end)
      |> Enum.map(fn {_key, sample} -> sample end)
      |> Enum.filter(fn sample -> sample.timestamp >= cutoff end)
      |> Enum.sort_by(& &1.timestamp)

    {:reply, samples, state}
  end

  @impl true
  def handle_call({:get_latest, skill, metric}, _from, state) do
    latest =
      :ets.tab2list(state.ets_table)
      |> Enum.filter(fn {{s, m, _ts}, _sample} ->
        s == skill and m == metric
      end)
      |> Enum.map(fn {_key, sample} -> sample end)
      |> Enum.max_by(fn sample -> sample.timestamp end, fn -> nil end)

    {:reply, latest, state}
  end

  @impl true
  def handle_call({:clear, skill, metric}, _from, state) do
    :ets.select_delete(state.ets_table, [
      {{{skill, metric, :_}, :_}, [], [true]}
    ])

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_all_samples, _from, state) do
    all_samples =
      :ets.tab2list(state.ets_table)
      |> Enum.map(fn {_key, sample} -> sample end)

    {:reply, all_samples, state}
  end

  defp prune_old_samples(ets_table, cutoff_ms) do
    :ets.foldl(
      fn {{_skill, _metric, timestamp}, _sample}, acc ->
        if timestamp < cutoff_ms do
          [timestamp | acc]
        else
          acc
        end
      end,
      [],
      ets_table
    )
    |> Enum.each(fn timestamp ->
      :ets.select_delete(ets_table, [
        {{{:_skill, :_metric, timestamp}, :_}, [], [true]}
      ])
    end)
  end

  @doc """
  Add a metric sample.
  """
  def add_sample(store \\ __MODULE__, skill, metric, value) do
    GenServer.call(store, {:add_sample, skill, metric, value})
  end

  @doc """
  Get all samples for a skill/metric since a given time window (ms).
  """
  def get_samples(store \\ __MODULE__, skill, metric, since_ms) do
    GenServer.call(store, {:get_samples, skill, metric, since_ms})
  end

  @doc """
  Get the most recent sample for a skill/metric.
  """
  def get_latest(store \\ __MODULE__, skill, metric) do
    GenServer.call(store, {:get_latest, skill, metric})
  end

  @doc """
  Clear all samples for a specific skill/metric.
  """
  def clear(store \\ __MODULE__, skill, metric) do
    GenServer.call(store, {:clear, skill, metric})
  end

  @doc """
  Get all stored samples (for testing).
  """
  def get_all_samples(store \\ __MODULE__) do
    GenServer.call(store, :get_all_samples)
  end
end
