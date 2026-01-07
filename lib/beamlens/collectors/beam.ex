defmodule Beamlens.Collectors.Beam do
  @moduledoc """
  BEAM VM collector providing core runtime metrics.

  All functions are read-only with zero side effects.
  No PII/PHI exposure - only aggregate system statistics.
  """

  @behaviour Beamlens.Collector

  alias Beamlens.Tool

  @doc """
  Collects all BEAM metrics in a single call for snapshot-first analysis.

  Returns a map containing all metric categories plus top 10 processes by memory.
  """
  def snapshot do
    %{
      system_info: system_info(),
      memory_stats: memory_stats(),
      process_stats: process_stats(),
      scheduler_stats: scheduler_stats(),
      atom_stats: atom_stats(),
      persistent_terms: persistent_terms(),
      overview: overview(),
      top_processes: top_processes(%{limit: 10, sort_by: "memory"})
    }
  end

  @impl true
  def tools do
    [
      %Tool{
        name: :overview,
        intent: "get_overview",
        description:
          "Get high-level utilization percentages across all categories (call first to identify areas needing investigation)",
        execute: fn _params -> overview() end
      },
      %Tool{
        name: :system_info,
        intent: "get_system_info",
        description: "Get node identity and context (OTP version, uptime, schedulers)",
        execute: fn _params -> system_info() end
      },
      %Tool{
        name: :memory_stats,
        intent: "get_memory_stats",
        description: "Get detailed memory statistics for leak detection",
        execute: fn _params -> memory_stats() end
      },
      %Tool{
        name: :process_stats,
        intent: "get_process_stats",
        description: "Get process/port counts and limits for capacity check",
        execute: fn _params -> process_stats() end
      },
      %Tool{
        name: :scheduler_stats,
        intent: "get_scheduler_stats",
        description: "Get scheduler details and run queues for performance analysis",
        execute: fn _params -> scheduler_stats() end
      },
      %Tool{
        name: :atom_stats,
        intent: "get_atom_stats",
        description: "Get atom table metrics when suspecting atom leaks",
        execute: fn _params -> atom_stats() end
      },
      %Tool{
        name: :persistent_terms,
        intent: "get_persistent_terms",
        description: "Get persistent term usage statistics",
        execute: fn _params -> persistent_terms() end
      },
      %Tool{
        name: :top_processes,
        intent: "get_top_processes",
        description: "Get top processes sorted by memory/queue/reductions with pagination",
        execute: &top_processes/1
      }
    ]
  end

  defp overview do
    memory = :erlang.memory()
    total_mem = memory[:total]
    used_mem = memory[:processes] + memory[:system]

    %{
      memory_utilization_pct: Float.round(used_mem / total_mem * 100, 1),
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

  defp bytes_to_mb(bytes), do: Float.round(bytes / 1_048_576, 2)

  defp uptime_seconds do
    {wall_clock_ms, _} = :erlang.statistics(:wall_clock)
    div(wall_clock_ms, 1000)
  end

  # Top processes with pagination (based on Phoenix LiveDashboard patterns)

  @process_keys [
    :memory,
    :reductions,
    :message_queue_len,
    :current_function,
    :registered_name,
    :dictionary
  ]

  defp top_processes(params) do
    limit = min(Map.get(params, :limit) || 10, 50)
    offset = Map.get(params, :offset) || 0
    sort_by = normalize_sort_by(Map.get(params, :sort_by) || "memory")

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
end
