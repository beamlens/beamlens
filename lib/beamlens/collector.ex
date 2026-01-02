defmodule Beamlens.Collector do
  @moduledoc """
  Gathers BEAM VM metrics safely through focused, granular functions.

  All functions are read-only with zero side effects.
  No PII/PHI exposure - only aggregate system statistics.

  ## Tool Functions

  Each function is designed for a specific analysis context:

  - `system_info/0` - Basic node context (always call first)
  - `memory_stats/0` - Memory categories for leak detection
  - `process_stats/0` - Process/port counts and limits
  - `scheduler_stats/0` - Scheduler details and run queues
  - `atom_stats/0` - Atom table metrics for leak detection
  - `persistent_terms/0` - Persistent term usage (OTP 21.2+)
  """

  @doc """
  Returns basic system information about the node.

  Use this first to get context before drilling into specific areas.
  """
  def system_info do
    %{
      node: Atom.to_string(Node.self()),
      otp_release: to_string(:erlang.system_info(:otp_release)),
      elixir_version: System.version(),
      uptime_seconds: uptime_seconds(),
      schedulers_online: :erlang.system_info(:schedulers_online)
    }
  end

  @doc """
  Returns detailed memory statistics.

  Use when investigating memory issues or potential leaks.
  """
  def memory_stats do
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

  @doc """
  Returns process and port statistics with limits.

  Use when checking system capacity or potential exhaustion.
  """
  def process_stats do
    %{
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      port_limit: :erlang.system_info(:port_limit)
    }
  end

  @doc """
  Returns scheduler statistics and run queue information.

  Use when investigating performance or latency issues.
  """
  def scheduler_stats do
    %{
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      dirty_cpu_schedulers_online: :erlang.system_info(:dirty_cpu_schedulers_online),
      dirty_io_schedulers: :erlang.system_info(:dirty_io_schedulers),
      run_queue: :erlang.statistics(:run_queue)
    }
  end

  @doc """
  Returns atom table statistics.

  Use when suspecting atom leaks. High atom_count approaching atom_limit
  indicates a critical issue.
  """
  def atom_stats do
    memory = :erlang.memory()

    %{
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit),
      atom_mb: bytes_to_mb(memory[:atom]),
      atom_used_mb: bytes_to_mb(memory[:atom_used])
    }
  end

  @doc """
  Returns persistent term statistics.

  Use when checking persistent term usage. Available in OTP 21.2+.
  """
  def persistent_terms do
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
end
