defmodule Beamlens.Domain.Logger.LogStore do
  @moduledoc """
  In-memory ring buffer for application logs.

  Captures logs via an Erlang `:logger` handler and provides query APIs
  for the LLM to investigate log patterns, errors, and module-specific issues.
  """

  use GenServer

  @default_max_size 1000
  @window_ms :timer.minutes(1)
  @prune_interval_ms :timer.seconds(30)
  @max_message_size 2048

  defstruct [
    :max_size,
    :handler_id,
    logs: :queue.new(),
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
    handler_id = :"beamlens_logger_#{:erlang.unique_integer([:positive])}"

    handler_config = %{
      config: %{pid: self()},
      level: :all
    }

    :logger.add_handler(handler_id, __MODULE__, handler_config)

    schedule_prune()

    state = %__MODULE__{
      max_size: max_size,
      handler_id: handler_id
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, %{handler_id: handler_id}) do
    :logger.remove_handler(handler_id)
    :ok
  end

  def log(%{level: level, msg: msg, meta: meta}, %{config: %{pid: pid}}) do
    if node(Map.get(meta, :gl, self())) == node() do
      entry = build_entry(level, msg, meta)
      GenServer.cast(pid, {:log_event, entry})
    end
  end

  @impl true
  def handle_cast({:log_event, entry}, state) do
    {logs, count} = add_to_ring(state.logs, state.count, state.max_size, entry)
    {:noreply, %{state | logs: logs, count: count}}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    logs = prune_old_entries(state.logs, cutoff)
    count = :queue.len(logs)
    schedule_prune()
    {:noreply, %{state | logs: logs, count: count}}
  end

  def get_stats(name \\ __MODULE__) do
    case whereis(name) do
      nil -> empty_stats()
      _pid -> GenServer.call(name, :get_stats)
    end
  end

  def get_logs(name \\ __MODULE__, opts \\ []) do
    case whereis(name) do
      nil -> []
      _pid -> GenServer.call(name, {:get_logs, opts})
    end
  end

  def recent_errors(name \\ __MODULE__, limit \\ 10) do
    case whereis(name) do
      nil -> []
      _pid -> GenServer.call(name, {:recent_errors, limit})
    end
  end

  def search(name \\ __MODULE__, pattern, opts \\ []) do
    case whereis(name) do
      nil -> []
      _pid -> GenServer.call(name, {:search, pattern, opts})
    end
  end

  def get_logs_by_module(name \\ __MODULE__, module_name, limit \\ 20) do
    case whereis(name) do
      nil -> []
      _pid -> GenServer.call(name, {:by_module, module_name, limit})
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
    stats = calculate_stats(state.logs)
    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_logs, opts}, _from, state) do
    level = Keyword.get(opts, :level)
    limit = Keyword.get(opts, :limit, 50)

    logs =
      state.logs
      |> :queue.to_list()
      |> filter_by_level(level)
      |> Enum.take(limit)
      |> Enum.map(&format_entry/1)

    {:reply, logs, state}
  end

  @impl true
  def handle_call({:recent_errors, limit}, _from, state) do
    errors =
      state.logs
      |> :queue.to_list()
      |> Enum.filter(&(&1.level == :error))
      |> Enum.take(limit)
      |> Enum.map(&format_entry/1)

    {:reply, errors, state}
  end

  @impl true
  def handle_call({:search, pattern, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)

    results =
      case Regex.compile(pattern) do
        {:ok, regex} ->
          state.logs
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
  def handle_call({:by_module, module_name, limit}, _from, state) do
    logs =
      state.logs
      |> :queue.to_list()
      |> Enum.filter(fn entry ->
        entry.module && module_matches?(entry.module, module_name)
      end)
      |> Enum.take(limit)
      |> Enum.map(&format_entry/1)

    {:reply, logs, state}
  end

  defp build_entry(level, msg, meta) do
    {mod, fun, arity} = Map.get(meta, :mfa, {nil, nil, nil})

    %{
      timestamp: System.monotonic_time(:millisecond),
      wall_time: Map.get(meta, :time),
      level: level,
      message: format_message(msg),
      module: mod,
      function: if(fun, do: "#{fun}/#{arity}"),
      line: Map.get(meta, :line),
      pid: Map.get(meta, :pid),
      domain: Map.get(meta, :domain, [])
    }
  end

  defp format_message({:string, msg}), do: msg |> IO.chardata_to_string() |> truncate_message()
  defp format_message({:report, report}), do: report |> inspect() |> truncate_message()
  defp format_message(msg) when is_binary(msg), do: truncate_message(msg)

  defp format_message(msg) when is_list(msg),
    do: msg |> IO.chardata_to_string() |> truncate_message()

  defp format_message(_), do: ""

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

  defp calculate_stats(logs) do
    entries = :queue.to_list(logs)
    total = length(entries)

    level_counts =
      Enum.reduce(entries, %{error: 0, warning: 0, info: 0, debug: 0}, fn entry, acc ->
        Map.update(acc, entry.level, 1, &(&1 + 1))
      end)

    error_modules =
      entries
      |> Enum.filter(&(&1.level == :error))
      |> Enum.map(& &1.module)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> length()

    error_rate =
      if total > 0 do
        Float.round(level_counts.error / total * 100, 2)
      else
        0.0
      end

    %{
      total_count: total,
      error_count: level_counts.error,
      warning_count: level_counts.warning,
      info_count: level_counts.info,
      debug_count: level_counts.debug,
      error_rate: error_rate,
      error_module_count: error_modules
    }
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
      timestamp: format_timestamp(entry.wall_time),
      level: entry.level,
      message: entry.message,
      module: if(entry.module, do: inspect(entry.module)),
      function: entry.function,
      line: entry.line,
      domain: entry.domain
    }
  end

  defp format_timestamp(nil), do: nil

  defp format_timestamp(microseconds) when is_integer(microseconds) do
    microseconds
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp module_matches?(module, pattern) when is_atom(module) do
    module_string = inspect(module)
    String.contains?(module_string, pattern)
  end

  defp module_matches?(_, _), do: false

  defp whereis(name) when is_atom(name), do: Process.whereis(name)
  defp whereis({:via, _, _} = name), do: GenServer.whereis(name)
  defp whereis(pid) when is_pid(pid), do: pid

  defp empty_stats do
    %{
      total_count: 0,
      error_count: 0,
      warning_count: 0,
      info_count: 0,
      debug_count: 0,
      error_rate: 0.0,
      error_module_count: 0
    }
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end
end
