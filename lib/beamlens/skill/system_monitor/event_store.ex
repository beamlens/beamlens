defmodule Beamlens.Skill.SystemMonitor.EventStore do
  @moduledoc """
  In-memory ring buffer for system monitor events.

  Captures long_gc and long_schedule events via :erlang.system_monitor/2
  to track performance anomalies before they become outages.

  ## Event Types

  - `:long_gc` - Garbage collection took longer than threshold
  - `:long_schedule` - Process was scheduled longer than threshold

  ## Usage

  Start this GenServer in your supervision tree to begin capturing events:

      {Beamlens.Skill.SystemMonitor.EventStore, []}

  Events are automatically captured when the process is running and
  system_monitor is configured to send messages to it.
  """

  use GenServer

  @default_max_size 500
  @window_ms :timer.minutes(5)
  @prune_interval_ms :timer.seconds(30)
  @default_long_gc 500
  @default_long_schedule 500

  defstruct [
    :max_size,
    events: :queue.new(),
    count: 0
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @impl true
  def init(opts) do
    max_size = Keyword.get(opts, :max_size, @default_max_size)
    long_gc = Keyword.get(opts, :long_gc, @default_long_gc)
    long_schedule = Keyword.get(opts, :long_schedule, @default_long_schedule)

    pid = self()

    monitor_opts = [
      {:long_gc, long_gc},
      {:long_schedule, long_schedule}
    ]

    :erlang.system_monitor(pid, monitor_opts)

    schedule_prune()

    state = %__MODULE__{
      max_size: max_size
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:long_gc, gc_info, pid}, state) do
    entry = build_long_gc_entry(gc_info, pid)
    {events, count} = add_to_ring(state.events, state.count, state.max_size, entry)
    {:noreply, %{state | events: events, count: count}}
  end

  @impl true
  def handle_info({:long_schedule, sched_info, pid}, state) do
    entry = build_long_schedule_entry(sched_info, pid)
    {events, count} = add_to_ring(state.events, state.count, state.max_size, entry)
    {:noreply, %{state | events: events, count: count}}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    events = prune_old_entries(state.events, cutoff)
    count = :queue.len(events)
    schedule_prune()
    {:noreply, %{state | events: events, count: count}}
  end

  @impl true
  def terminate(_reason, _state) do
    :erlang.system_monitor(self(), [])
    :ok
  end

  @doc """
  Flushes all pending handle_info messages.

  Returns :ok after processing all pending messages.
  """
  def flush(name \\ __MODULE__) do
    case Process.whereis(name) do
      nil -> :ok
      _pid -> GenServer.call(name, :flush)
    end
  end

  @doc """
  Returns system monitor statistics over the rolling window.

  Returns a map with:
  - `:long_gc_count_5m` - Total long_gc events in window
  - `:long_schedule_count_5m` - Total long_schedule events in window
  - `:affected_process_count` - Unique processes affected
  - `:max_gc_duration_ms` - Longest GC duration seen
  - `:max_schedule_duration_ms` - Longest schedule duration seen
  """
  def get_stats(name \\ __MODULE__) do
    case Process.whereis(name) do
      nil -> empty_stats()
      _pid -> GenServer.call(name, :get_stats)
    end
  end

  @doc """
  Returns recent system monitor events.

  ## Options
  - `:type` - Filter by event type ("long_gc", "long_schedule", or nil for all)
  - `:limit` - Maximum number of events to return (default: 50)
  """
  def get_events(name \\ __MODULE__, opts \\ []) do
    case Process.whereis(name) do
      nil -> []
      _pid -> GenServer.call(name, {:get_events, opts})
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = calculate_stats(state.events)
    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_events, opts}, _from, state) do
    type = Keyword.get(opts, :type)
    limit = Keyword.get(opts, :limit, 50)

    events =
      state.events
      |> :queue.to_list()
      |> filter_by_type(type)
      |> Enum.take(limit)
      |> Enum.map(&format_entry/1)

    {:reply, events, state}
  end

  defp build_long_gc_entry(gc_info, pid) do
    {ms, heap_size, heap_fragmentation, old_heap_size, mnesia_spare} =
      gc_info

    %{
      id: make_ref(),
      timestamp: System.monotonic_time(:millisecond),
      type: :long_gc,
      pid: pid,
      duration_ms: ms,
      heap_size: heap_size,
      heap_fragmentation: heap_fragmentation,
      old_heap_size: old_heap_size,
      mnesia_spare: mnesia_spare
    }
  end

  defp build_long_schedule_entry(sched_info, pid) do
    {ms, runtime_reductions} = sched_info

    %{
      id: make_ref(),
      timestamp: System.monotonic_time(:millisecond),
      type: :long_schedule,
      pid: pid,
      duration_ms: ms,
      runtime_reductions: runtime_reductions
    }
  end

  defp add_to_ring(queue, count, max_size, entry) do
    new_queue = :queue.in(entry, queue)

    if count >= max_size do
      {{:value, _}, trimmed} = :queue.out(new_queue)
      {trimmed, count}
    else
      {new_queue, count + 1}
    end
  end

  defp prune_old_entries(queue, cutoff) do
    queue
    |> :queue.to_list()
    |> Enum.filter(fn entry -> entry.timestamp > cutoff end)
    |> :queue.from_list()
  end

  defp calculate_stats(events) do
    entries = :queue.to_list(events)

    long_gc_entries = Enum.filter(entries, &(&1.type == :long_gc))
    long_schedule_entries = Enum.filter(entries, &(&1.type == :long_schedule))

    gc_durations = Enum.map(long_gc_entries, & &1.duration_ms)
    sched_durations = Enum.map(long_schedule_entries, & &1.duration_ms)

    affected_pids =
      entries
      |> Enum.map(& &1.pid)
      |> Enum.uniq()
      |> length()

    max_gc = if gc_durations == [], do: 0, else: Enum.max(gc_durations)
    max_sched = if sched_durations == [], do: 0, else: Enum.max(sched_durations)

    %{
      long_gc_count_5m: length(long_gc_entries),
      long_schedule_count_5m: length(long_schedule_entries),
      affected_process_count: affected_pids,
      max_gc_duration_ms: max_gc,
      max_schedule_duration_ms: max_sched
    }
  end

  defp filter_by_type(entries, nil), do: entries

  defp filter_by_type(entries, type) when is_binary(type) do
    atom_type = String.to_existing_atom(type)
    Enum.filter(entries, &(&1.type == atom_type))
  rescue
    ArgumentError -> entries
  end

  defp filter_by_type(entries, type) when is_atom(type) do
    Enum.filter(entries, &(&1.type == type))
  end

  defp format_entry(entry) do
    base = %{
      datetime: format_timestamp(entry.timestamp),
      type: Atom.to_string(entry.type),
      duration_ms: entry.duration_ms,
      pid: inspect(entry.pid)
    }

    case entry.type do
      :long_gc ->
        Map.merge(base, %{
          heap_size: entry.heap_size,
          old_heap_size: entry.old_heap_size
        })

      :long_schedule ->
        Map.merge(base, %{
          runtime_reductions: entry.runtime_reductions
        })
    end
  end

  defp format_timestamp(timestamp) do
    timestamp
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp empty_stats do
    %{
      long_gc_count_5m: 0,
      long_schedule_count_5m: 0,
      affected_process_count: 0,
      max_gc_duration_ms: 0,
      max_schedule_duration_ms: 0
    }
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end
end
