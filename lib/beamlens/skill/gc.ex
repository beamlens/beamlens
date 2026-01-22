defmodule Beamlens.Skill.Gc do
  @moduledoc """
  Garbage collection monitoring skill.

  Provides callback functions for monitoring GC activity.
  All functions are read-only with zero side effects.
  No PII/PHI exposure - only aggregate GC statistics.
  """

  @behaviour Beamlens.Skill

  @impl true
  def title, do: "Garbage Collection"

  @impl true
  def description, do: "Garbage collection: heap sizes, GC frequency, memory pressure"

  @impl true
  def system_prompt do
    """
    You are a garbage collection analyst. You monitor GC activity to detect
    memory pressure and inefficient allocation patterns.

    ## Your Domain
    - Global GC statistics (collection count, words reclaimed)
    - Per-process heap sizes and GC frequency
    - Processes with large heaps causing GC pressure

    ## What to Watch For
    - Processes with unusually large heaps
    - High minor GC counts: frequent small allocations
    - Large total_heap vs heap_size: fragmentation
    - Message queue growth with large heaps: process falling behind
    - Processes avoiding fullsweep: potential memory bloat
    """
  end

  @impl true
  def snapshot do
    {gcs, words, _} = :erlang.statistics(:garbage_collection)
    word_size = :erlang.system_info(:wordsize)

    %{
      total_gcs: gcs,
      words_reclaimed: words,
      bytes_reclaimed_mb: bytes_to_mb(words * word_size)
    }
  end

  @impl true
  def callbacks do
    %{
      "gc_stats" => fn -> snapshot() end,
      "gc_top_processes" => &top_gc_processes/1,
      "gc_find_spiky_processes" => &find_spiky_processes/1,
      "gc_find_lazy_gc_processes" => &find_lazy_gc_processes/2,
      "gc_calculate_efficiency" => &calculate_efficiency/1,
      "gc_recommend_hibernation" => fn -> recommend_hibernation() end,
      "gc_get_long_gcs" => &get_long_gcs/1
    }
  end

  @impl true
  def callback_docs do
    """
    ### gc_stats()
    Global GC statistics: total_gcs, words_reclaimed, bytes_reclaimed_mb

    ### gc_top_processes(limit)
    Processes with largest heaps (potential GC pressure): pid, name, heap_size_kb, total_heap_size_kb, minor_gcs, fullsweep_after, message_queue_len

    ### gc_find_spiky_processes(threshold_mb)
    Processes with high memory variance (spiky memory usage): pid, name, heap_size_kb, total_heap_size_kb, variance_mb, stack_size_kb

    ### gc_find_lazy_gc_processes(min_heap_mb, max_gc_age_minutes)
    Processes with large heaps but infrequent GC (potential memory hoarding): pid, name, heap_size_mb, total_heap_size_mb, last_gc_minutes_ago, minor_gcs

    ### gc_calculate_efficiency(pid)
    GC effectiveness for a process (reclaimed vs allocated ratio): pid, efficiency_ratio, total_reclaimed_mb, total_allocated_mb, minor_gcs

    ### gc_recommend_hibernation()
    Processes that should hibernate with estimated memory savings: pid, name, heap_size_mb, message_queue_len, estimated_savings_mb, current_function

    ### gc_get_long_gcs(limit)
    Long GC events from system monitor (duration_ms, heap_size, old_heap_size): datetime, pid, duration_ms, heap_size, old_heap_size
    """
  end

  defp top_gc_processes(limit) when is_number(limit) do
    limit = min(limit, 50)
    word_size = :erlang.system_info(:wordsize)

    Process.list()
    |> Enum.map(&process_gc_info(&1, word_size))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.total_heap_size_kb, :desc)
    |> Enum.take(limit)
  end

  defp process_gc_info(pid, word_size) do
    info_keys = [
      :heap_size,
      :total_heap_size,
      :garbage_collection,
      :message_queue_len,
      :registered_name,
      :dictionary
    ]

    case Process.info(pid, info_keys) do
      nil ->
        nil

      info ->
        gc_info = info[:garbage_collection] || []

        %{
          pid: inspect(pid),
          name: process_name(info),
          heap_size_kb: words_to_kb(info[:heap_size], word_size),
          total_heap_size_kb: words_to_kb(info[:total_heap_size], word_size),
          minor_gcs: gc_info[:minor_gcs] || 0,
          fullsweep_after: gc_info[:fullsweep_after] || 0,
          message_queue_len: info[:message_queue_len] || 0
        }
    end
  end

  defp process_name(info) do
    cond do
      is_atom(info[:registered_name]) and info[:registered_name] != [] ->
        Atom.to_string(info[:registered_name])

      label = info[:dictionary][:"$process_label"] ->
        inspect(label)

      initial = info[:dictionary][:"$initial_call"] ->
        format_mfa(initial)

      true ->
        nil
    end
  end

  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp format_mfa(_), do: nil

  defp words_to_kb(words, word_size), do: div(words * word_size, 1024)
  defp bytes_to_mb(bytes), do: Float.round(bytes / 1_048_576, 2)

  defp find_spiky_processes(threshold_mb) when is_number(threshold_mb) do
    word_size = :erlang.system_info(:wordsize)

    Process.list()
    |> Enum.map(&process_spiky_info(&1, word_size, threshold_mb))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.variance_mb, :desc)
  end

  defp process_spiky_info(pid, word_size, threshold_mb) do
    info_keys = [:heap_size, :total_heap_size, :stack_size, :registered_name, :dictionary]

    with info when not is_nil(info) <- Process.info(pid, info_keys),
         heap_size when heap_size > 0 <- info[:heap_size],
         total_heap_size when not is_nil(total_heap_size) <- info[:total_heap_size],
         variance <- total_heap_size - heap_size,
         variance_mb <- words_to_mb(variance, word_size),
         true <- variance_mb >= threshold_mb do
      %{
        pid: inspect(pid),
        name: process_name(info),
        heap_size_kb: words_to_kb(heap_size, word_size),
        total_heap_size_kb: words_to_kb(total_heap_size, word_size),
        variance_mb: variance_mb,
        stack_size_kb: words_to_kb(info[:stack_size] || 0, word_size)
      }
    else
      _ -> nil
    end
  end

  defp find_lazy_gc_processes(min_heap_mb, max_gc_age_minutes)
       when is_number(min_heap_mb) and is_number(max_gc_age_minutes) do
    word_size = :erlang.system_info(:wordsize)
    min_heap_words = trunc(min_heap_mb * 1_048_576 / word_size)
    current_time = System.monotonic_time(:millisecond)

    Process.list()
    |> Enum.map(
      &process_lazy_gc_info(&1, word_size, min_heap_words, max_gc_age_minutes, current_time)
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.heap_size_mb, :desc)
  end

  defp process_lazy_gc_info(pid, word_size, min_heap_words, max_gc_age_minutes, current_time) do
    info_keys = [
      :heap_size,
      :total_heap_size,
      :garbage_collection,
      :registered_name,
      :dictionary
    ]

    with info when not is_nil(info) <- Process.info(pid, info_keys),
         heap_size when heap_size >= min_heap_words <- info[:heap_size] || 0,
         total_heap_size when not is_nil(total_heap_size) <- info[:total_heap_size],
         gc_info when is_list(gc_info) <- info[:garbage_collection],
         last_gc_time <- gc_info[:last_gc] || 0,
         gc_age_ms <- current_time - last_gc_time,
         last_gc_minutes_ago <- gc_age_ms / (60 * 1000),
         true <- last_gc_minutes_ago >= max_gc_age_minutes do
      %{
        pid: inspect(pid),
        name: process_name(info),
        heap_size_mb: words_to_mb(heap_size, word_size),
        total_heap_size_mb: words_to_mb(total_heap_size, word_size),
        last_gc_minutes_ago: Float.round(last_gc_minutes_ago, 2),
        minor_gcs: gc_info[:minor_gcs] || 0
      }
    else
      _ -> nil
    end
  end

  defp calculate_efficiency(pid_str) when is_binary(pid_str) do
    case pid_to_pid(pid_str) do
      nil -> %{pid: pid_str, error: "process_not_found"}
      pid -> calculate_efficiency(pid)
    end
  end

  defp calculate_efficiency(pid) when is_pid(pid) do
    word_size = :erlang.system_info(:wordsize)

    with info when not is_nil(info) <-
           Process.info(pid, [:garbage_collection, :heap_size, :total_heap_size]),
         gc_info <- info[:garbage_collection] || [],
         heap_size <- info[:heap_size] || 0,
         minor_gcs <- gc_info[:minor_gcs] || 0,
         reclaimed_words <- gc_info[:reclaimed] || 0,
         total_reclaimed_mb <- words_to_mb(reclaimed_words, word_size),
         total_allocated_mb <- words_to_mb(heap_size + reclaimed_words, word_size),
         efficiency_ratio <- calculate_efficiency_ratio(total_reclaimed_mb, total_allocated_mb) do
      %{
        pid: inspect(pid),
        efficiency_ratio: efficiency_ratio,
        total_reclaimed_mb: total_reclaimed_mb,
        total_allocated_mb: total_allocated_mb,
        minor_gcs: minor_gcs
      }
    else
      _ ->
        %{
          pid: inspect(pid),
          error: "process_not_found"
        }
    end
  end

  defp calculate_efficiency_ratio(total_reclaimed_mb, total_allocated_mb) do
    if total_allocated_mb > 0 do
      Float.round(total_reclaimed_mb / total_allocated_mb, 4)
    else
      0.0
    end
  end

  defp recommend_hibernation do
    word_size = :erlang.system_info(:wordsize)
    min_heap_words = trunc(1 * 1_048_576 / word_size)

    Process.list()
    |> Enum.map(&process_hibernation_info(&1, word_size, min_heap_words))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.estimated_savings_mb, :desc)
  end

  defp process_hibernation_info(pid, word_size, min_heap_words) do
    info_keys = [
      :heap_size,
      :total_heap_size,
      :message_queue_len,
      :registered_name,
      :dictionary,
      :current_function
    ]

    with info when not is_nil(info) <- Process.info(pid, info_keys),
         heap_size when heap_size >= min_heap_words <- info[:heap_size] || 0,
         total_heap_size when not is_nil(total_heap_size) <- info[:total_heap_size],
         0 <- info[:message_queue_len] || 0,
         true <- has_registered_name?(info[:registered_name]),
         estimated_savings <- words_to_mb(total_heap_size, word_size) * 0.9 do
      %{
        pid: inspect(pid),
        name: process_name(info),
        heap_size_mb: words_to_mb(heap_size, word_size),
        message_queue_len: 0,
        estimated_savings_mb: Float.round(estimated_savings, 2),
        current_function: format_current_function(info[:current_function])
      }
    else
      _ -> nil
    end
  end

  defp has_registered_name?(name)
       when is_atom(name) and name != [] and name != :undefined,
       do: true

  defp has_registered_name?(_), do: false

  defp get_long_gcs(limit) when is_number(limit) do
    alias Beamlens.Skill.SystemMonitor.EventStore

    case Process.whereis(EventStore) do
      nil ->
        []

      _pid ->
        EventStore.get_events(EventStore, type: "long_gc", limit: limit)
        |> Enum.map(fn event ->
          %{
            datetime: event.datetime,
            pid: event.pid,
            duration_ms: event.duration_ms,
            heap_size: event.heap_size,
            old_heap_size: event.old_heap_size
          }
        end)
    end
  end

  defp words_to_mb(words, word_size) do
    Float.round(words * word_size / 1_048_576, 2)
  end

  defp format_current_function({m, f, a}) do
    "#{inspect(m)}.#{f}/#{a}"
  end

  defp format_current_function(_), do: nil

  defp pid_to_pid(pid_str) do
    pid_str
    |> String.replace(~r/[<>\s]/, "")
    |> String.split(".")
    |> case do
      ["0", node_id, serial] when is_binary(node_id) and is_binary(serial) ->
        node_int = String.to_integer(node_id)
        serial_int = String.to_integer(serial)

        try do
          :erlang.list_to_pid([0, node_int, serial_int])
        rescue
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
