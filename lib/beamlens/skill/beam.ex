defmodule Beamlens.Skill.Beam do
  @moduledoc """
  BEAM VM metrics skill.

  Provides callback functions for collecting BEAM runtime metrics.
  Used by watchers and can be called directly.

  All functions are read-only with zero side effects.
  No PII/PHI exposure - only aggregate system statistics.
  """

  @behaviour Beamlens.Skill

  @impl true
  def id, do: :beam

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
      "beam_top_processes" => &top_processes_wrapper/2
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
end
