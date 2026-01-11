defmodule Beamlens.Skill.Gc do
  @moduledoc """
  Garbage collection monitoring skill.

  Provides callback functions for monitoring GC activity.
  All functions are read-only with zero side effects.
  No PII/PHI exposure - only aggregate GC statistics.
  """

  @behaviour Beamlens.Skill

  @impl true
  def id, do: :gc

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
      "gc_top_processes" => &top_gc_processes/1
    }
  end

  @impl true
  def callback_docs do
    """
    ### gc_stats()
    Global GC statistics: total_gcs, words_reclaimed, bytes_reclaimed_mb

    ### gc_top_processes(limit)
    Processes with largest heaps (potential GC pressure): pid, name, heap_size_kb, total_heap_size_kb, minor_gcs, fullsweep_after, message_queue_len
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
end
