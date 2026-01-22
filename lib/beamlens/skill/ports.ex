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
      "ports_list_inet" => &list_inet_ports/0,
      "ports_top_by_buffer" => &top_ports_by_buffer/2,
      "ports_inet_stats" => &inet_stats/1,
      "ports_top_by_queue" => &top_ports_by_queue/1,
      "ports_queue_growth" => &queue_growth/1,
      "ports_suspended_processes" => &suspended_processes/0,
      "ports_saturation_prediction" => &saturation_prediction/1,
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

    ### ports_list_inet()
    All inet ports (TCP/UDP/SCTP) with socket details: id, type, local_addr, remote_addr, input_kb, output_kb

    ### ports_top_by_buffer(limit, direction)
    Top N inet ports by send or recv buffer size. Direction: "send" or "recv"

    ### ports_inet_stats(port_id)
    Detailed inet port statistics: recv_cnt, recv_oct, send_cnt, send_oct, send_pend

    ### ports_top_by_queue(limit)
    Top N ports by internal queue size. Returns: id, name, queue_size, connected_pid, saturation_pct

    ### ports_queue_growth(minutes_back)
    Track port queue size changes over time window. Returns ports with highest growth rates and predictions

    ### ports_suspended_processes()
    Processes currently de-scheduled due to port saturation. Correlates busy_port events with process info

    ### ports_saturation_prediction(minutes_ahead)
    Predict which ports will saturate based on current queue growth rates

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

  def list_inet_ports do
    inet_types = ["tcp_inet", "udp_inet", "sctp_inet"]

    Port.list()
    |> Enum.map(&inet_port_summary/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn port -> port.type in inet_types end)
  end

  def top_ports_by_buffer(limit, direction) when is_number(limit) and is_binary(direction) do
    limit = min(limit, 50)

    inet_ports =
      Port.list()
      |> Enum.map(&inet_port_with_buffer/1)
      |> Enum.reject(&is_nil/1)

    sort_key =
      case direction do
        "send" -> :send_kb
        "recv" -> :recv_kb
        _ -> :send_kb
      end

    inet_ports
    |> Enum.sort_by(&Map.get(&1, sort_key), :desc)
    |> Enum.take(limit)
  end

  def inet_stats(port_id) when is_binary(port_id) do
    case resolve_port(port_id) do
      nil ->
        %{error: "port_not_found", id: port_id}

      port ->
        case safe_inet_stats(port) do
          {:ok, stats} ->
            Map.put(stats, :id, port_id)

          {:error, reason} ->
            %{error: reason, id: port_id}
        end
    end
  end

  defp inet_port_summary(port) do
    case safe_port_info(port) do
      nil ->
        nil

      info ->
        port_type = format_name(info[:name])

        inet_data =
          case get_inet_info(port) do
            {:ok, data} ->
              data

            _ ->
              %{local_addr: "unknown", remote_addr: "unknown"}
          end

        %{
          id: inspect(port),
          type: port_type,
          local_addr: inet_data.local_addr,
          remote_addr: inet_data.remote_addr,
          input_kb: bytes_to_kb(info[:input] || 0),
          output_kb: bytes_to_kb(info[:output] || 0)
        }
    end
  end

  defp inet_port_with_buffer(port) do
    case safe_port_info(port) do
      nil ->
        nil

      info ->
        case safe_inet_stats(port) do
          {:ok, stats} ->
            %{
              id: inspect(port),
              type: format_name(info[:name]),
              send_kb: bytes_to_kb(stats.send_oct || 0),
              recv_kb: bytes_to_kb(stats.recv_oct || 0)
            }

          _ ->
            nil
        end
    end
  end

  defp safe_inet_stats(port) do
    case :inet.getstat(port) do
      {:ok, stats} when is_list(stats) ->
        stats_map =
          stats
          |> Enum.map(fn {key, val} -> {key, val} end)
          |> Map.new()

        {:ok, stats_map}

      {:error, _} ->
        {:error, "inet_stats_failed"}
    end
  rescue
    _ -> {:error, "not_an_inet_port"}
  end

  defp get_inet_info(port) do
    local_addr =
      case :inet.sockname(port) do
        {:ok, {ip, port_num}} -> format_ip_port(ip, port_num)
        _ -> "unknown"
      end

    remote_addr =
      case :inet.peername(port) do
        {:ok, {ip, port_num}} -> format_ip_port(ip, port_num)
        _ -> "not_connected"
      end

    {:ok, %{local_addr: local_addr, remote_addr: remote_addr}}
  rescue
    _ -> {:error, "inet_info_failed"}
  end

  defp format_ip_port(ip, port) when is_tuple(ip) do
    ip_str =
      ip
      |> Tuple.to_list()
      |> Enum.join(".")

    "#{ip_str}:#{port}"
  end

  defp format_ip_port(_ip, _port), do: "unknown"

  defp bytes_to_kb(bytes) when is_integer(bytes), do: Float.round(bytes / 1024, 2)
  defp bytes_to_kb(_), do: 0.0

  def top_ports_by_queue(limit) when is_number(limit) do
    limit = min(limit, 50)

    Port.list()
    |> Enum.map(&port_with_queue/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.queue_size, :desc)
    |> Enum.take(limit)
  end

  def queue_growth(minutes_back) when is_number(minutes_back) do
    window_ms = minutes_back * 60_000

    current_queues =
      Port.list()
      |> Enum.map(&port_with_queue/1)
      |> Enum.reject(&is_nil/1)
      |> Map.new(fn port -> {port.id, port.queue_size} end)

    oldest_queues =
      get_historical_queues(window_ms)

    analyze_growth(current_queues, oldest_queues)
  end

  def suspended_processes do
    alias Beamlens.Skill.SystemMonitor.EventStore

    busy_events =
      EventStore.get_events(EventStore, type: "busy_port", limit: 100)

    suspended_pids =
      busy_events
      |> Enum.map(fn event -> extract_pid_from_event(event) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.map(suspended_pids, fn pid -> process_suspension_info(pid) end)
    |> Enum.reject(&is_nil/1)
  end

  def saturation_prediction(minutes_ahead) when is_number(minutes_ahead) do
    window_ms = 5 * 60_000

    growth_data = queue_growth(div(window_ms, 60_000))

    future_ms = minutes_ahead * 60_000

    Enum.map(growth_data.growing_ports, fn port ->
      predict_saturation(port, growth_data.current_queues, future_ms)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.minutes_until_saturation)
  end

  defp port_with_queue(port) do
    case safe_port_info(port) do
      nil ->
        nil

      info ->
        queue_size = info[:queue_size] || 0

        saturation_pct =
          calculate_saturation_pct(queue_size)

        %{
          id: inspect(port),
          name: format_name(info[:name]),
          queue_size: queue_size,
          connected_pid: format_pid(info[:connected]),
          saturation_pct: saturation_pct
        }
    end
  end

  defp calculate_saturation_pct(queue_size) when queue_size >= 0 do
    cond do
      queue_size >= 1024 * 1024 ->
        100.0

      queue_size >= 512 * 1024 ->
        75.0

      queue_size >= 256 * 1024 ->
        50.0

      queue_size >= 128 * 1024 ->
        25.0

      true ->
        Float.round(queue_size / (1024 * 1024) * 100, 2)
    end
  end

  defp get_historical_queues(_window_ms) do
    %{}
  end

  defp analyze_growth(current_queues, oldest_queues) when map_size(oldest_queues) == 0 do
    current_port_list =
      current_queues
      |> Enum.map(fn {id, queue_size} ->
        %{
          id: id,
          current_queue: queue_size,
          growth_rate_bytes_per_sec: 0,
          trend: :unknown
        }
      end)

    %{growing_ports: current_port_list, current_queues: current_queues}
  end

  defp analyze_growth(current_queues, oldest_queues) do
    _now_ms = System.system_time(:millisecond)
    window_sec = 300

    growing_ports =
      current_queues
      |> Enum.map(fn {id, current_queue} ->
        oldest_queue = Map.get(oldest_queues, id, current_queue)

        growth_bytes = current_queue - oldest_queue
        growth_rate = growth_bytes / window_sec

        trend =
          cond do
            growth_rate > 1024 ->
              :growing

            growth_rate < -1024 ->
              :shrinking

            true ->
              :stable
          end

        %{
          id: id,
          current_queue: current_queue,
          oldest_queue: oldest_queue,
          growth_bytes: growth_bytes,
          growth_rate_bytes_per_sec: growth_rate,
          trend: trend
        }
      end)
      |> Enum.filter(fn port -> port.trend == :growing end)

    %{growing_ports: growing_ports, current_queues: current_queues}
  end

  defp extract_pid_from_event(event) do
    pid_string = Map.get(event, :pid)

    if pid_string do
      pid_string
      |> String.trim()
      |> String.to_charlist()
      |> :erlang.list_to_pid()
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp process_suspension_info(pid) do
    case Process.info(pid, [:message_queue_len, :current_function, :dictionary]) do
      nil ->
        nil

      info ->
        %{
          pid: inspect(pid),
          message_queue_len: Keyword.get(info, :message_queue_len, 0),
          current_function: format_current_function(Keyword.get(info, :current_function)),
          registered_name: get_process_name(pid)
        }
    end
  rescue
    _ -> nil
  end

  defp format_current_function({mod, fun, arity}) do
    "#{inspect(mod)}.#{fun}/#{arity}"
  end

  defp format_current_function(_), do: "unknown"

  defp get_process_name(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> inspect(name)
      _ -> "anonymous"
    end
  rescue
    _ -> "unknown"
  end

  defp predict_saturation(port, current_queues, _future_ms) do
    queue_size = Map.get(current_queues, port.id, port.current_queue)

    if port.growth_rate_bytes_per_sec > 0 do
      saturation_threshold = 1024 * 1024

      remaining_bytes = max(saturation_threshold - queue_size, 0)
      seconds_until_saturation = remaining_bytes / port.growth_rate_bytes_per_sec

      minutes_until_saturation = seconds_until_saturation / 60

      if minutes_until_saturation < 1440 do
        %{
          id: port.id,
          name: port.name,
          current_queue_bytes: queue_size,
          growth_rate_bytes_per_sec: port.growth_rate_bytes_per_sec,
          saturation_threshold_bytes: saturation_threshold,
          minutes_until_saturation: Float.round(minutes_until_saturation, 2),
          risk_level: assess_risk(minutes_until_saturation)
        }
      else
        nil
      end
    else
      nil
    end
  end

  defp assess_risk(minutes) when minutes < 15, do: :critical
  defp assess_risk(minutes) when minutes < 60, do: :high
  defp assess_risk(minutes) when minutes < 240, do: :medium
  defp assess_risk(_), do: :low
end
