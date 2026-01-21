defmodule Beamlens.Skill.Ports do
  @moduledoc """
  Port monitoring skill.

  Provides callback functions for monitoring BEAM ports (file descriptors, sockets, etc.).
  All functions are read-only with zero side effects.
  No PII/PHI exposure - only aggregate port statistics.
  """

  @behaviour Beamlens.Skill

  @impl true
  def title, do: "Ports"

  @impl true
  def description, do: "Ports: file descriptors, sockets, I/O throughput"

  @impl true
  def system_prompt do
    """
    You are a BEAM port monitor. You track ports (file descriptors, sockets,
    external program connections) for resource leaks and I/O issues.

    ## Your Domain
    - Port count and utilization against limits
    - I/O throughput per port (bytes in/out)
    - Port memory usage
    - Connected processes
    - Busy port events (ports causing process suspension)

    ## What to Watch For
    - Port utilization > 70%: risk of exhausting file descriptors
    - Ports with high input but no output: potential blocked readers
    - Ports with growing queue sizes: I/O backpressure
    - Orphaned ports: connected process may have died
    - Sudden port count increases: potential leak
    - Busy port events: processes suspended waiting for port I/O

    Correlate with:
    - System Monitor skill: busy_port and busy_dist_port events
    - Process info: identify suspended processes and their state
    """
  end

  @impl true
  def snapshot do
    ports = Port.list()
    limit = :erlang.system_info(:port_limit)

    %{
      port_count: length(ports),
      port_limit: limit,
      port_utilization_pct: Float.round(length(ports) / limit * 100, 2)
    }
  end

  @impl true
  def callbacks do
    alias Beamlens.Skill.SystemMonitor.EventStore

    %{
      "ports_list" => &list_ports/0,
      "ports_info" => &port_info/1,
      "ports_top" => &top_ports/2,
      "ports_busy_events" => fn ->
        EventStore.get_events(EventStore, type: "busy_port", limit: 50)
      end,
      "ports_busy_dist_events" => fn ->
        EventStore.get_events(EventStore, type: "busy_dist_port", limit: 50)
      end
    }
  end

  @impl true
  def callback_docs do
    """
    ### ports_list()
    All ports with: id, name, connected_pid, os_pid (if available)

    ### ports_info(port_id)
    Detailed port info: id, name, connected_pid, input_bytes, output_bytes, os_pid, queue_size, memory_kb

    ### ports_top(limit, sort_by)
    Top N ports by "input", "output", or "memory". Returns list with id, name, input_bytes, output_bytes, memory_kb

    ### ports_busy_events()
    Recent busy_port events from system monitor. Returns: datetime, type, port, pid

    ### ports_busy_dist_events()
    Recent busy_dist_port events from system monitor. Returns: datetime, type, port, pid
    """
  end

  defp list_ports do
    Port.list()
    |> Enum.map(&port_summary/1)
    |> Enum.reject(&is_nil/1)
  end

  defp port_info(port_id) when is_binary(port_id) do
    case resolve_port(port_id) do
      nil ->
        %{error: "port_not_found", id: port_id}

      port ->
        port_details(port)
    end
  end

  defp top_ports(limit, sort_by) when is_number(limit) and is_binary(sort_by) do
    limit = min(limit, 50)
    sort_key = normalize_sort_key(sort_by)

    Port.list()
    |> Enum.map(&port_with_stats/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&Map.get(&1, sort_key), :desc)
    |> Enum.take(limit)
  end

  defp port_summary(port) do
    case safe_port_info(port) do
      nil ->
        nil

      info ->
        %{
          id: inspect(port),
          name: format_name(info[:name]),
          connected_pid: format_pid(info[:connected]),
          os_pid: info[:os_pid]
        }
    end
  end

  defp port_details(port) do
    case safe_port_info(port) do
      nil ->
        %{error: "port_info_unavailable"}

      info ->
        %{
          id: inspect(port),
          name: format_name(info[:name]),
          connected_pid: format_pid(info[:connected]),
          input_bytes: info[:input] || 0,
          output_bytes: info[:output] || 0,
          os_pid: info[:os_pid],
          queue_size: info[:queue_size] || 0,
          memory_kb: div(info[:memory] || 0, 1024)
        }
    end
  end

  defp port_with_stats(port) do
    case safe_port_info(port) do
      nil ->
        nil

      info ->
        %{
          id: inspect(port),
          name: format_name(info[:name]),
          input_bytes: info[:input] || 0,
          output_bytes: info[:output] || 0,
          memory_kb: div(info[:memory] || 0, 1024)
        }
    end
  end

  defp safe_port_info(port) do
    Port.info(port)
  end

  defp resolve_port(port_id_string) do
    Port.list()
    |> Enum.find(fn port -> inspect(port) == port_id_string end)
  end

  defp format_name(name) when is_list(name), do: List.to_string(name)
  defp format_name(name) when is_binary(name), do: name
  defp format_name(name) when is_atom(name), do: Atom.to_string(name)
  defp format_name(_), do: "unknown"

  defp format_pid(pid) when is_pid(pid), do: inspect(pid)
  defp format_pid(_), do: "unknown"

  defp normalize_sort_key("input"), do: :input_bytes
  defp normalize_sort_key("output"), do: :output_bytes
  defp normalize_sort_key("memory"), do: :memory_kb
  defp normalize_sort_key(_), do: :memory_kb
end
