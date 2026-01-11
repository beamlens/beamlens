defmodule Beamlens.Skill.Ecto.TelemetryStore do
  @moduledoc """
  Aggregates Ecto telemetry events for monitoring.

  Maintains a rolling window of query metrics including timing,
  counts, and slow query tracking. Does not store query text.
  """

  use GenServer

  @default_window_ms :timer.minutes(5)
  @default_slow_threshold_ms 100
  @default_max_events 50_000
  @prune_interval_ms :timer.seconds(30)

  defstruct [
    :repo,
    :telemetry_prefix,
    :window_ms,
    :slow_threshold_ms,
    :max_events,
    events: [],
    handler_id: nil
  ]

  def start_link(opts) do
    repo = Keyword.fetch!(opts, :repo)
    name = Keyword.get(opts, :name, via_registry(repo))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    repo = Keyword.fetch!(opts, :repo)

    %{
      id: {__MODULE__, repo},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    slow_threshold_ms = Keyword.get(opts, :slow_threshold_ms, @default_slow_threshold_ms)
    max_events = Keyword.get(opts, :max_events, @default_max_events)

    telemetry_prefix = get_telemetry_prefix(repo)
    handler_id = "beamlens-ecto-#{inspect(repo)}"

    :telemetry.detach(handler_id)

    :telemetry.attach(
      handler_id,
      telemetry_prefix ++ [:query],
      &__MODULE__.handle_telemetry_event/4,
      %{pid: self()}
    )

    schedule_prune()

    state = %__MODULE__{
      repo: repo,
      telemetry_prefix: telemetry_prefix,
      window_ms: window_ms,
      slow_threshold_ms: slow_threshold_ms,
      max_events: max_events,
      handler_id: handler_id
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, %{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end

  def handle_telemetry_event(_event, measurements, metadata, %{pid: pid}) do
    event = build_event(measurements, metadata)
    GenServer.cast(pid, {:query_event, event})
  end

  @impl true
  def handle_cast({:query_event, event}, state) do
    events = [event | state.events] |> Enum.take(state.max_events)
    {:noreply, %{state | events: events}}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = System.monotonic_time(:millisecond) - state.window_ms
    events = Enum.filter(state.events, fn e -> e.timestamp > cutoff end)
    schedule_prune()
    {:noreply, %{state | events: events}}
  end

  def query_stats(repo) do
    GenServer.call(via_registry(repo), :query_stats)
  end

  def slow_queries(repo, limit \\ 10) do
    GenServer.call(via_registry(repo), {:slow_queries, limit})
  end

  def pool_stats(repo) do
    GenServer.call(via_registry(repo), :pool_stats)
  end

  @doc """
  Ensures all pending telemetry events are processed.

  Used in tests to synchronize after emitting events.
  """
  def flush(repo) do
    GenServer.call(via_registry(repo), :flush)
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:query_stats, _from, state) do
    stats = calculate_query_stats(state.events, state.slow_threshold_ms)
    {:reply, stats, state}
  end

  @impl true
  def handle_call({:slow_queries, limit}, _from, state) do
    slow =
      state.events
      |> Enum.filter(fn e -> e.total_time_ms >= state.slow_threshold_ms end)
      |> Enum.sort_by(& &1.total_time_ms, :desc)
      |> Enum.take(limit)
      |> Enum.map(&format_slow_query/1)

    {:reply, %{queries: slow, threshold_ms: state.slow_threshold_ms}, state}
  end

  @impl true
  def handle_call(:pool_stats, _from, state) do
    stats = calculate_pool_stats(state.events)
    {:reply, stats, state}
  end

  defp build_event(measurements, metadata) do
    now = System.monotonic_time(:millisecond)

    %{
      timestamp: now,
      total_time_ms: native_to_ms(measurements[:total_time]),
      query_time_ms: native_to_ms(measurements[:query_time]),
      decode_time_ms: native_to_ms(measurements[:decode_time]),
      queue_time_ms: native_to_ms(measurements[:queue_time]),
      idle_time_ms: native_to_ms(measurements[:idle_time]),
      source: metadata[:source],
      result: result_type(metadata[:result])
    }
  end

  defp native_to_ms(nil), do: 0.0
  defp native_to_ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1000

  defp result_type({:ok, _}), do: :ok
  defp result_type({:error, _}), do: :error
  defp result_type(_), do: :unknown

  defp calculate_query_stats([], _slow_threshold_ms) do
    %{
      query_count: 0,
      avg_time_ms: 0.0,
      max_time_ms: 0.0,
      p95_time_ms: 0.0,
      slow_count: 0,
      error_count: 0
    }
  end

  defp calculate_query_stats(events, slow_threshold_ms) do
    times = Enum.map(events, & &1.total_time_ms)
    sorted_times = Enum.sort(times)
    count = length(events)

    %{
      query_count: count,
      avg_time_ms: Float.round(Enum.sum(times) / count, 2),
      max_time_ms: Float.round(Enum.max(times), 2),
      p95_time_ms: Float.round(percentile(sorted_times, 95), 2),
      slow_count: Enum.count(times, &(&1 >= slow_threshold_ms)),
      error_count: Enum.count(events, &(&1.result == :error))
    }
  end

  defp calculate_pool_stats([]) do
    %{
      avg_queue_time_ms: 0.0,
      max_queue_time_ms: 0.0,
      p95_queue_time_ms: 0.0,
      high_contention_count: 0
    }
  end

  defp calculate_pool_stats(events) do
    queue_times = Enum.map(events, & &1.queue_time_ms)
    sorted = Enum.sort(queue_times)
    count = length(events)
    high_contention_threshold = 50

    %{
      avg_queue_time_ms: Float.round(Enum.sum(queue_times) / count, 2),
      max_queue_time_ms: Float.round(Enum.max(queue_times), 2),
      p95_queue_time_ms: Float.round(percentile(sorted, 95), 2),
      high_contention_count: Enum.count(queue_times, &(&1 >= high_contention_threshold))
    }
  end

  defp percentile([], _), do: 0.0

  defp percentile(sorted_list, p) do
    k = (length(sorted_list) - 1) * p / 100
    f = floor(k)
    c = ceil(k)

    if f == c do
      Enum.at(sorted_list, trunc(f))
    else
      lower = Enum.at(sorted_list, trunc(f))
      upper = Enum.at(sorted_list, trunc(c))
      lower + (upper - lower) * (k - f)
    end
  end

  defp format_slow_query(event) do
    %{
      source: event.source,
      total_time_ms: Float.round(event.total_time_ms, 2),
      query_time_ms: Float.round(event.query_time_ms, 2),
      queue_time_ms: Float.round(event.queue_time_ms, 2),
      result: event.result
    }
  end

  defp get_telemetry_prefix(repo) do
    config = repo.config()
    Keyword.get(config, :telemetry_prefix) || default_telemetry_prefix(repo)
  end

  defp default_telemetry_prefix(repo) do
    repo
    |> Module.split()
    |> Enum.map(&Macro.underscore/1)
    |> Enum.map(&String.to_atom/1)
  end

  defp via_registry(repo) do
    {:via, Registry, {Beamlens.Skill.Ecto.Registry, repo}}
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end
end
