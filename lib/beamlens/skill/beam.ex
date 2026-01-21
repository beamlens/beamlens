defmodule Beamlens.Skill.Beam do
  @moduledoc """
  BEAM VM metrics skill.

  Provides callback functions for collecting BEAM runtime metrics.
  Used by operators and can be called directly.

  All functions are read-only with zero side effects.
  No PII/PHI exposure - only aggregate system statistics.
  """

  @behaviour Beamlens.Skill

  @impl true
  def title, do: "BEAM VM"

  @impl true
  def description, do: "BEAM VM health: memory, processes, schedulers, atoms"

  @impl true
  def system_prompt do
    """
    You are a BEAM VM health monitor. You continuously watch the Erlang runtime
    for resource exhaustion, scheduler contention, and process anomalies.

    ## Your Domain
    - Memory usage (processes, binaries, ETS, atoms)
    - Process/port utilization against limits
    - Scheduler run queues and CPU saturation
    - Atom table growth (can crash the VM if exhausted)

    ## What to Watch For
    - Process utilization > 70%: investigate which processes are spawning
    - Atom utilization > 50%: critical, atoms are never garbage collected
    - Run queue > 2x schedulers: scheduler contention
    - Binary memory growth: potential memory leak from large binaries
    - Message queue buildup: processes falling behind

    ## Binary Memory Leaks
    - Binary memory growing > 50MB/hour without load increase: potential leak
    - Router/proxy processes with high binary counts: hold refs unnecessarily
    - Use beam_binary_leak(10) to identify processes holding refs after GC
    - Remediation: binary:copy/1 for small fragments, hibernation, temporary worker processes
    """
  end

  @doc """
  High-level utilization percentages for quick health assessment.

  Returns just enough information for an LLM to decide if deeper
  investigation is needed. Call individual metric functions for details.
  """
  @impl true
  def snapshot do
    %{
      process_utilization_pct:
        Float.round(
          :erlang.system_info(:process_count) / :erlang.system_info(:process_limit) * 100,
          2
        ),
      port_utilization_pct:
        Float.round(:erlang.system_info(:port_count) / :erlang.system_info(:port_limit) * 100, 2),
      atom_utilization_pct:
        Float.round(:erlang.system_info(:atom_count) / :erlang.system_info(:atom_limit) * 100, 2),
      scheduler_run_queue: :erlang.statistics(:run_queue),
      schedulers_online: :erlang.system_info(:schedulers_online)
    }
  end

  @doc """
  Returns the Lua sandbox callback map for BEAM metrics.

  These functions are registered with Puck.Sandbox.Eval and can be
  called from LLM-generated Lua code.
  """
  @impl true
  def callbacks do
    %{
      "beam_get_memory" => &memory_stats/0,
      "beam_get_processes" => &process_stats/0,
      "beam_get_schedulers" => &scheduler_stats/0,
      "beam_get_atoms" => &atom_stats/0,
      "beam_get_system" => &system_info/0,
      "beam_get_persistent_terms" => &persistent_terms/0,
      "beam_top_processes" => &top_processes_wrapper/2,
      "beam_binary_leak" => &binary_leak_wrapper/1,
      "beam_binary_top_memory" => &binary_top_memory_wrapper/1
    }
  end

  @impl true
  def callback_docs do
    """
    ### beam_get_memory()
    Memory stats in MB: total_mb, processes_mb, processes_used_mb, system_mb, binary_mb, ets_mb, code_mb

    ### beam_get_processes()
    Process/port counts: process_count, process_limit, port_count, port_limit

    ### beam_get_schedulers()
    Scheduler stats: schedulers, schedulers_online, dirty_cpu_schedulers_online, dirty_io_schedulers, run_queue

    ### beam_get_atoms()
    Atom table: atom_count, atom_limit, atom_mb, atom_used_mb

    ### beam_get_system()
    System info: node, otp_release, elixir_version, uptime_seconds, schedulers_online

    ### beam_get_persistent_terms()
    Persistent terms: count, memory_mb

    ### beam_top_processes(limit, sort_by)
    Top N processes by "memory", "message_queue", or "reductions". Returns: total_processes, showing, offset, limit, sort_by, processes list with pid, name, memory_kb, message_queue, reductions, current_function

    ### beam_binary_leak(limit)
    Detects binary memory leaks by forcing global GC and measuring binary reference deltas. Returns top N processes by binary_delta (positive delta = potential leak). Includes: total_processes, showing, processes list with pid, name, binary_delta, binary_count, binary_memory_kb, current_function. **Note: Forces garbage collection on all processes.**

    ### beam_binary_top_memory(limit)
    Returns top N processes by current binary memory usage. Includes: total_processes, showing, processes list with pid, name, binary_count, binary_memory_kb, current_function. Does not force GC.
    """
  end

  defp system_info do
    %{
      node: Atom.to_string(Node.self()),
      otp_release: to_string(:erlang.system_info(:otp_release)),
      elixir_version: System.version(),
      uptime_seconds: uptime_seconds(),
      schedulers_online: :erlang.system_info(:schedulers_online)
    }
  end

  defp memory_stats do
    memory = :erlang.memory()

    %{
      total_mb: bytes_to_mb(memory[:total]),
      processes_mb: bytes_to_mb(memory[:processes]),
      processes_used_mb: bytes_to_mb(memory[:processes_used]),
      system_mb: bytes_to_mb(memory[:system]),
      binary_mb: bytes_to_mb(memory[:binary]),
      ets_mb: bytes_to_mb(memory[:ets]),
      code_mb: bytes_to_mb(memory[:code])
    }
  end

  defp process_stats do
    %{
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      port_limit: :erlang.system_info(:port_limit)
    }
  end

  defp scheduler_stats do
    %{
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      dirty_cpu_schedulers_online: :erlang.system_info(:dirty_cpu_schedulers_online),
      dirty_io_schedulers: :erlang.system_info(:dirty_io_schedulers),
      run_queue: :erlang.statistics(:run_queue)
    }
  end

  defp atom_stats do
    memory = :erlang.memory()

    %{
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit),
      atom_mb: bytes_to_mb(memory[:atom]),
      atom_used_mb: bytes_to_mb(memory[:atom_used])
    }
  end

  defp persistent_terms do
    info = :persistent_term.info()

    %{
      count: info[:count],
      memory_mb: bytes_to_mb(info[:memory])
    }
  end

  defp top_processes(opts) do
    limit = min(Map.get(opts, :limit) || 10, 50)
    offset = Map.get(opts, :offset) || 0
    sort_by = normalize_sort_by(Map.get(opts, :sort_by) || "memory")

    processes =
      Process.list()
      |> Stream.map(&process_info/1)
      |> Stream.reject(&is_nil/1)
      |> Enum.sort_by(&Map.get(&1, sort_by), :desc)
      |> Enum.drop(offset)
      |> Enum.take(limit)

    %{
      total_processes: :erlang.system_info(:process_count),
      showing: length(processes),
      offset: offset,
      limit: limit,
      sort_by: to_string(sort_by),
      processes: processes
    }
  end

  defp bytes_to_mb(bytes), do: Float.round(bytes / 1_048_576, 2)

  defp uptime_seconds do
    {wall_clock_ms, _} = :erlang.statistics(:wall_clock)
    div(wall_clock_ms, 1000)
  end

  @process_keys [
    :memory,
    :reductions,
    :message_queue_len,
    :current_function,
    :registered_name,
    :dictionary
  ]

  defp process_info(pid) do
    case Process.info(pid, @process_keys) do
      nil ->
        nil

      info ->
        %{
          pid: inspect(pid),
          name: process_name(info),
          memory_kb: div(info[:memory], 1024),
          message_queue: info[:message_queue_len],
          reductions: info[:reductions],
          current_function: format_mfa(info[:current_function])
        }
    end
  end

  defp process_name(info) do
    cond do
      info[:registered_name] -> inspect(info[:registered_name])
      label = info[:dictionary][:"$process_label"] -> inspect(label)
      initial = info[:dictionary][:"$initial_call"] -> format_mfa(initial)
      true -> nil
    end
  end

  defp normalize_sort_by("memory"), do: :memory_kb
  defp normalize_sort_by("message_queue"), do: :message_queue
  defp normalize_sort_by("reductions"), do: :reductions
  defp normalize_sort_by(_), do: :memory_kb

  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp format_mfa(_), do: nil

  defp top_processes_wrapper(limit, sort_by)
       when is_number(limit) and is_binary(sort_by) do
    top_processes(%{limit: limit, sort_by: sort_by})
  end

  defp binary_leak_wrapper(limit) when is_number(limit) do
    binary_leak(%{limit: limit})
  end

  defp binary_top_memory_wrapper(limit) when is_number(limit) do
    binary_top_memory(%{limit: limit})
  end

  defp binary_leak(opts) do
    limit = min(Map.get(opts, :limit) || 10, 50)

    before = Enum.map(Process.list(), &binary_info/1)

    :erlang.garbage_collect()

    after_gc = Enum.map(Process.list(), &binary_info/1)

    deltas =
      Enum.zip([before, after_gc])
      |> Enum.map(fn {before_proc, after_proc} ->
        delta =
          if is_nil(before_proc) || is_nil(after_proc) do
            0
          else
            (after_proc[:binary_count] || 0) - (before_proc[:binary_count] || 0)
          end

        Map.merge(after_proc || %{}, %{
          binary_delta: delta
        })
      end)
      |> Enum.filter(fn proc -> proc[:binary_delta] && proc[:binary_delta] > 0 end)
      |> Enum.sort_by(& &1[:binary_delta], :desc)
      |> Enum.take(limit)

    %{
      total_processes: :erlang.system_info(:process_count),
      showing: length(deltas),
      limit: limit,
      processes: deltas
    }
  end

  defp binary_top_memory(opts) do
    limit = min(Map.get(opts, :limit) || 10, 50)

    processes =
      Process.list()
      |> Stream.map(&binary_info/1)
      |> Stream.reject(&is_nil/1)
      |> Enum.sort_by(& &1[:binary_memory_kb], :desc)
      |> Enum.take(limit)

    %{
      total_processes: :erlang.system_info(:process_count),
      showing: length(processes),
      limit: limit,
      processes: processes
    }
  end

  @binary_keys [:binary, :current_function, :registered_name, :dictionary]

  defp binary_info(pid) do
    case Process.info(pid, @binary_keys) do
      nil ->
        nil

      info ->
        binaries = info[:binary] || []

        binary_memory_kb =
          binaries
          |> Enum.map(fn {_id, size, _count} -> size end)
          |> Enum.sum()
          |> Kernel.div(1024)

        %{
          pid: inspect(pid),
          name: process_name(info),
          binary_count: length(binaries),
          binary_memory_kb: binary_memory_kb,
          current_function: format_mfa(info[:current_function])
        }
    end
  end
end
