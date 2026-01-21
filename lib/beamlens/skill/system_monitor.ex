defmodule Beamlens.Skill.SystemMonitor do
  @moduledoc """
  System Monitor Event skill.

  Tracks long_gc and long_schedule events from the BEAM VM to detect
  performance anomalies before they become outages.

  Requires EventStore to be running in supervision tree.
  All functions are read-only with zero side effects.
  """

  @behaviour Beamlens.Skill

  alias Beamlens.Skill.SystemMonitor.EventStore

  @impl true
  def title, do: "System Monitor"

  @impl true
  def description, do: "System monitor: long_gc, long_schedule events"

  @impl true
  def system_prompt do
    """
    You are a system monitor analyst. You track long garbage collections and
    long scheduling events to detect performance degradation early.

    ## Your Domain
    - Long GC events (>500ms garbage collections)
    - Long schedule events (>500ms scheduling delays)
    - Process heap sizes and GC behavior
    - Scheduler anomalies

    ## What to Watch For
    - long_gc > 1000ms: process with huge heap, memory pressure
    - long_schedule with low reductions: NIF or blocking operation
    - Recurring events from same process: chronic issue
    - Spikes in event frequency: system-wide degradation

    ## Analysis Patterns
    - Large heap + long GC: process memory leak or inefficient data structures
    - Long schedule + low reductions: NIF blocking or port I/O contention
    - Many processes affected: system-wide overload or resource contention
    - Single process affected: that process is the bottleneck

    Correlate with:
    - GC skill: heap sizes of affected processes
    - Beam skill: reductions and current_function
    - Process info: what is the process doing?
    """
  end

  @impl true
  def snapshot do
    stats = EventStore.get_stats()

    %{
      long_gc_events_5m: stats.long_gc_count_5m,
      long_schedule_events_5m: stats.long_schedule_count_5m,
      max_gc_duration_ms: stats.max_gc_duration_ms,
      max_schedule_duration_ms: stats.max_schedule_duration_ms,
      affected_process_count: stats.affected_process_count
    }
  end

  @impl true
  def callbacks do
    %{
      "sysmon_stats" => fn -> EventStore.get_stats() end,
      "sysmon_events" => &get_events_wrapper/2
    }
  end

  @impl true
  def callback_docs do
    """
    ### sysmon_stats()
    System monitor statistics: long_gc_count_5m, long_schedule_count_5m, affected_process_count, max_gc_duration_ms, max_schedule_duration_ms

    ### sysmon_events(type, limit)
    Recent system monitor events. Type: "long_gc", "long_schedule", or nil for all.
    Returns: datetime, type, duration_ms, pid, heap_size (for long_gc), runtime_reductions (for long_schedule)

    Example: `sysmon_events("long_gc", 10)` returns last 10 long GC events
    """
  end

  defp get_events_wrapper(type, limit) when is_number(limit) do
    type_opt = if is_binary(type) and type != "", do: type, else: nil
    EventStore.get_events(EventStore, type: type_opt, limit: limit)
  end
end
