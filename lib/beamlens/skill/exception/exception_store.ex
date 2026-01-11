if Code.ensure_loaded?(Tower) do
  defmodule Beamlens.Skill.Exception.ExceptionStore do
    @moduledoc """
    In-memory ring buffer for application exceptions.

    Captures exceptions via Tower's reporter behaviour and provides query APIs
    for the LLM to investigate exception patterns, types, and stacktraces.

    Requires Tower to be installed and configured with this module as a reporter:

        config :tower,
          reporters: [Beamlens.Skill.Exception.ExceptionStore]

    """

    @behaviour Tower.Reporter

    use GenServer

    @default_max_size 500
    @window_ms :timer.minutes(5)
    @prune_interval_ms :timer.seconds(30)
    @max_message_size 2048

    defstruct [
      :max_size,
      exceptions: :queue.new(),
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

      schedule_prune()

      state = %__MODULE__{
        max_size: max_size
      }

      {:ok, state}
    end

    @impl Tower.Reporter
    def report_event(%Tower.Event{} = event) do
      GenServer.cast(__MODULE__, {:exception_event, event})
    end

    @impl true
    def handle_cast({:exception_event, event}, state) do
      entry = build_entry(event)
      {exceptions, count} = add_to_ring(state.exceptions, state.count, state.max_size, entry)
      {:noreply, %{state | exceptions: exceptions, count: count}}
    end

    @impl true
    def handle_info(:prune, state) do
      cutoff = System.monotonic_time(:millisecond) - @window_ms
      exceptions = prune_old_entries(state.exceptions, cutoff)
      count = :queue.len(exceptions)
      schedule_prune()
      {:noreply, %{state | exceptions: exceptions, count: count}}
    end

    @doc """
    Returns exception statistics over the rolling window.

    Returns a map with:
    - `:total_count` - Total exceptions in window
    - `:by_kind` - Counts by exception kind (:error, :exit, :throw, :message)
    - `:by_level` - Counts by log level
    - `:top_types` - Top 10 exception types with counts
    - `:type_count` - Number of unique exception types
    """
    def get_stats(name \\ __MODULE__) do
      case whereis(name) do
        nil -> empty_stats()
        _pid -> GenServer.call(name, :get_stats)
      end
    end

    @doc """
    Returns recent exceptions, optionally filtered.

    ## Options
    - `:kind` - Filter by exception kind ("error", "exit", "throw")
    - `:level` - Filter by log level
    - `:limit` - Maximum number of exceptions to return (default: 50)
    """
    def get_exceptions(name \\ __MODULE__, opts \\ []) do
      case whereis(name) do
        nil -> []
        _pid -> GenServer.call(name, {:get_exceptions, opts})
      end
    end

    @doc """
    Returns exceptions matching the given type name.

    The type name is matched as a substring (e.g., "ArgumentError" matches
    "Elixir.ArgumentError").
    """
    def get_by_type(name \\ __MODULE__, exception_type, limit \\ 20) do
      case whereis(name) do
        nil -> []
        _pid -> GenServer.call(name, {:by_type, exception_type, limit})
      end
    end

    @doc """
    Searches exception messages by regex pattern.

    Returns an empty list if the pattern is invalid.
    """
    def search(name \\ __MODULE__, pattern, opts \\ []) do
      case whereis(name) do
        nil -> []
        _pid -> GenServer.call(name, {:search, pattern, opts})
      end
    end

    @doc """
    Returns the full stacktrace for a specific exception by ID.

    Returns nil if the exception is not found.
    """
    def get_stacktrace(name \\ __MODULE__, exception_id) do
      case whereis(name) do
        nil -> nil
        _pid -> GenServer.call(name, {:get_stacktrace, exception_id})
      end
    end

    @doc "Ensures all pending events are processed. Used in tests."
    def flush(name \\ __MODULE__) do
      GenServer.call(name, :flush)
    end

    @impl true
    def handle_call(:flush, _from, state) do
      {:reply, :ok, state}
    end

    @impl true
    def handle_call(:get_stats, _from, state) do
      stats = calculate_stats(state.exceptions)
      {:reply, stats, state}
    end

    @impl true
    def handle_call({:get_exceptions, opts}, _from, state) do
      kind = Keyword.get(opts, :kind)
      level = Keyword.get(opts, :level)
      limit = Keyword.get(opts, :limit, 50)

      exceptions =
        state.exceptions
        |> :queue.to_list()
        |> filter_by_kind(kind)
        |> filter_by_level(level)
        |> Enum.take(limit)
        |> Enum.map(&format_entry/1)

      {:reply, exceptions, state}
    end

    @impl true
    def handle_call({:by_type, exception_type, limit}, _from, state) do
      exceptions =
        state.exceptions
        |> :queue.to_list()
        |> Enum.filter(fn entry ->
          entry.type && type_matches?(entry.type, exception_type)
        end)
        |> Enum.take(limit)
        |> Enum.map(&format_entry/1)

      {:reply, exceptions, state}
    end

    @impl true
    def handle_call({:search, pattern, opts}, _from, state) do
      limit = Keyword.get(opts, :limit, 20)

      results =
        case Regex.compile(pattern) do
          {:ok, regex} ->
            state.exceptions
            |> :queue.to_list()
            |> Enum.filter(fn entry -> Regex.match?(regex, entry.message) end)
            |> Enum.take(limit)
            |> Enum.map(&format_entry/1)

          {:error, _} ->
            []
        end

      {:reply, results, state}
    end

    @impl true
    def handle_call({:get_stacktrace, exception_id}, _from, state) do
      result =
        state.exceptions
        |> :queue.to_list()
        |> Enum.find(fn entry -> entry.id == exception_id end)
        |> case do
          nil -> nil
          entry -> format_stacktrace(entry.stacktrace)
        end

      {:reply, result, state}
    end

    defp build_entry(%Tower.Event{} = event) do
      %{
        id: event.id,
        timestamp: System.monotonic_time(:millisecond),
        datetime: event.datetime,
        level: event.level,
        kind: event.kind,
        type: extract_type(event.reason),
        message: extract_message(event.reason),
        stacktrace: event.stacktrace,
        metadata: event.metadata
      }
    end

    defp extract_type(%{__struct__: struct}), do: inspect(struct)
    defp extract_type(%{__exception__: true} = ex), do: inspect(ex.__struct__)
    defp extract_type(_), do: nil

    defp extract_message(%{__exception__: true} = ex) do
      Exception.message(ex) |> truncate_message()
    end

    defp extract_message(reason) when is_binary(reason), do: truncate_message(reason)
    defp extract_message(reason), do: inspect(reason) |> truncate_message()

    defp truncate_message(msg) when byte_size(msg) > @max_message_size do
      String.slice(msg, 0, @max_message_size) <> "... (truncated)"
    end

    defp truncate_message(msg), do: msg

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

    defp calculate_stats(exceptions) do
      entries = :queue.to_list(exceptions)
      total = length(entries)

      by_kind =
        Enum.reduce(entries, %{error: 0, exit: 0, throw: 0, message: 0}, fn entry, acc ->
          Map.update(acc, entry.kind, 1, &(&1 + 1))
        end)

      by_level =
        Enum.reduce(entries, %{}, fn entry, acc ->
          Map.update(acc, entry.level, 1, &(&1 + 1))
        end)

      type_counts =
        entries
        |> Enum.map(& &1.type)
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()

      top_types =
        type_counts
        |> Enum.sort_by(fn {_type, count} -> count end, :desc)
        |> Enum.take(10)

      %{
        total_count: total,
        by_kind: by_kind,
        by_level: by_level,
        top_types: top_types,
        type_count: map_size(type_counts)
      }
    end

    defp filter_by_kind(entries, nil), do: entries

    defp filter_by_kind(entries, kind) when is_binary(kind) do
      atom_kind = String.to_existing_atom(kind)
      Enum.filter(entries, &(&1.kind == atom_kind))
    rescue
      ArgumentError -> entries
    end

    defp filter_by_kind(entries, kind) when is_atom(kind) do
      Enum.filter(entries, &(&1.kind == kind))
    end

    defp filter_by_level(entries, nil), do: entries

    defp filter_by_level(entries, level) when is_binary(level) do
      atom_level = String.to_existing_atom(level)
      Enum.filter(entries, &(&1.level == atom_level))
    rescue
      ArgumentError -> entries
    end

    defp filter_by_level(entries, level) when is_atom(level) do
      Enum.filter(entries, &(&1.level == level))
    end

    defp format_entry(entry) do
      %{
        id: entry.id,
        datetime: format_datetime(entry.datetime),
        kind: entry.kind,
        level: entry.level,
        type: entry.type,
        message: entry.message
      }
    end

    defp format_datetime(nil), do: nil
    defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

    defp format_stacktrace(nil), do: nil

    defp format_stacktrace(stacktrace) when is_list(stacktrace) do
      Enum.map(stacktrace, fn
        {mod, fun, arity, location} when is_integer(arity) ->
          %{
            module: inspect(mod),
            function: "#{fun}/#{arity}",
            file: Keyword.get(location, :file) |> to_string(),
            line: Keyword.get(location, :line)
          }

        {mod, fun, args, location} when is_list(args) ->
          %{
            module: inspect(mod),
            function: "#{fun}/#{length(args)}",
            file: Keyword.get(location, :file) |> to_string(),
            line: Keyword.get(location, :line)
          }

        other ->
          %{raw: inspect(other)}
      end)
    end

    defp type_matches?(type, pattern) when is_binary(type) and is_binary(pattern) do
      String.contains?(type, pattern)
    end

    defp type_matches?(_, _), do: false

    defp whereis(name) when is_atom(name), do: Process.whereis(name)
    defp whereis({:via, _, _} = name), do: GenServer.whereis(name)
    defp whereis(pid) when is_pid(pid), do: pid

    defp empty_stats do
      %{
        total_count: 0,
        by_kind: %{error: 0, exit: 0, throw: 0, message: 0},
        by_level: %{},
        top_types: [],
        type_count: 0
      }
    end

    defp schedule_prune do
      Process.send_after(self(), :prune, @prune_interval_ms)
    end
  end
end
