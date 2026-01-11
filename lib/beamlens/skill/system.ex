defmodule Beamlens.Skill.System do
  @moduledoc """
  OS-level system metrics skill.

  Provides callback functions for collecting CPU, memory, and disk metrics
  from the operating system via Erlang's os_mon application.

  ## Requirements

  This skill requires os_mon to be started. Add it to your application's
  extra_applications in mix.exs:

      def application do
        [extra_applications: [:logger, :os_mon]]
      end

  ## Platform Notes

  - `cpu_sup` metrics are only available on Unix systems
  - `memsup` and `disksup` work on Unix and Windows

  All functions are read-only with zero side effects.
  """

  @behaviour Beamlens.Skill

  @compile {:no_warn_undefined, [:cpu_sup, :memsup, :disksup]}

  @impl true
  def id, do: :system

  @impl true
  def snapshot do
    mem = memory_stats()

    %{
      cpu_load_1m: cpu_load(:avg1),
      cpu_load_5m: cpu_load(:avg5),
      cpu_load_15m: cpu_load(:avg15),
      memory_used_pct: mem.used_pct,
      disk_max_used_pct: highest_disk_usage_pct()
    }
  end

  @impl true
  def callbacks do
    %{
      "system_get_cpu" => &cpu_stats/0,
      "system_get_memory" => &memory_stats/0,
      "system_get_disks" => &disk_stats/0
    }
  end

  @impl true
  def callback_docs do
    """
    ### system_get_cpu()
    CPU load averages: load_1m, load_5m, load_15m (normalized where 1.0 = 100% of one CPU),
    process_count (OS processes, not BEAM)

    ### system_get_memory()
    System memory: total_mb, used_mb, free_mb, used_pct, buffered_mb, cached_mb

    ### system_get_disks()
    Disk usage per mount point: list of {mount, total_mb, used_pct}
    """
  end

  defp cpu_stats do
    %{
      load_1m: cpu_load(:avg1),
      load_5m: cpu_load(:avg5),
      load_15m: cpu_load(:avg15),
      process_count: cpu_call(:nprocs)
    }
  end

  defp memory_stats do
    data = :memsup.get_system_memory_data()
    total = Keyword.get(data, :total_memory, 0)
    free = Keyword.get(data, :free_memory, 0)
    used = total - free

    %{
      total_mb: bytes_to_mb(total),
      free_mb: bytes_to_mb(free),
      used_mb: bytes_to_mb(used),
      used_pct: percentage(used, total),
      buffered_mb: bytes_to_mb(Keyword.get(data, :buffered_memory, 0)),
      cached_mb: bytes_to_mb(Keyword.get(data, :cached_memory, 0))
    }
  end

  defp disk_stats do
    :disksup.get_disk_data()
    |> Enum.map(fn {mount, total_kb, used_pct} ->
      %{
        mount: to_string(mount),
        total_mb: Float.round(total_kb / 1024, 1),
        used_pct: used_pct
      }
    end)
  end

  defp cpu_load(avg_fun) do
    case Process.whereis(:cpu_sup) do
      nil -> 0.0
      _pid -> Float.round(apply(:cpu_sup, avg_fun, []) / 256, 2)
    end
  end

  defp cpu_call(fun) do
    case Process.whereis(:cpu_sup) do
      nil -> 0
      _pid -> apply(:cpu_sup, fun, [])
    end
  end

  defp highest_disk_usage_pct do
    case :disksup.get_disk_data() do
      [] -> 0
      disks -> disks |> Enum.map(&elem(&1, 2)) |> Enum.max()
    end
  end

  defp percentage(_used, 0), do: 0.0
  defp percentage(used, total), do: Float.round(used / total * 100, 1)

  defp bytes_to_mb(bytes), do: Float.round(bytes / 1_048_576, 2)
end
