defmodule Beamlens.Skill.PortsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Skill.Ports

  describe "title/0" do
    test "returns a non-empty string" do
      title = Ports.title()

      assert is_binary(title)
      assert String.length(title) > 0
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      description = Ports.description()

      assert is_binary(description)
      assert String.length(description) > 0
    end
  end

  describe "system_prompt/0" do
    test "returns a non-empty string" do
      system_prompt = Ports.system_prompt()

      assert is_binary(system_prompt)
      assert String.length(system_prompt) > 0
    end
  end

  describe "snapshot/0" do
    test "returns port statistics" do
      snapshot = Ports.snapshot()

      assert is_integer(snapshot.port_count)
      assert is_integer(snapshot.port_limit)
      assert is_float(snapshot.port_utilization_pct)
    end

    test "port_count is non-negative" do
      snapshot = Ports.snapshot()
      assert snapshot.port_count >= 0
    end

    test "utilization is within bounds" do
      snapshot = Ports.snapshot()
      assert snapshot.port_utilization_pct >= 0
      assert snapshot.port_utilization_pct <= 100
    end
  end

  describe "callbacks/0" do
    test "returns callback map with expected keys" do
      callbacks = Ports.callbacks()

      assert is_map(callbacks)
      assert Map.has_key?(callbacks, "ports_list")
      assert Map.has_key?(callbacks, "ports_info")
      assert Map.has_key?(callbacks, "ports_top")
    end

    test "callbacks are functions with correct arity" do
      callbacks = Ports.callbacks()

      assert is_function(callbacks["ports_list"], 0)
      assert is_function(callbacks["ports_info"], 1)
      assert is_function(callbacks["ports_top"], 2)
    end
  end

  describe "ports_list callback" do
    test "returns list of ports" do
      result = Ports.callbacks()["ports_list"].()

      assert is_list(result)
    end

    test "port entries have expected fields when ports exist" do
      result = Ports.callbacks()["ports_list"].()

      if result != [] do
        [port | _] = result
        assert Map.has_key?(port, :id)
        assert Map.has_key?(port, :name)
        assert Map.has_key?(port, :connected_pid)
      end
    end
  end

  describe "ports_info callback" do
    test "returns error for non-existent port" do
      result = Ports.callbacks()["ports_info"].("#Port<999.999>")

      assert result.error == "port_not_found"
    end
  end

  describe "ports_top callback" do
    test "returns top ports by memory" do
      result = Ports.callbacks()["ports_top"].(5, "memory")

      assert is_list(result)
      assert length(result) <= 5
    end

    test "returns top ports by input" do
      result = Ports.callbacks()["ports_top"].(5, "input")

      assert is_list(result)
      assert length(result) <= 5
    end

    test "returns top ports by output" do
      result = Ports.callbacks()["ports_top"].(5, "output")

      assert is_list(result)
      assert length(result) <= 5
    end

    test "caps limit at 50" do
      result = Ports.callbacks()["ports_top"].(100, "memory")

      assert length(result) <= 50
    end
  end

  describe "callback_docs/0" do
    test "returns non-empty string" do
      docs = Ports.callback_docs()

      assert is_binary(docs)
      assert String.length(docs) > 0
    end

    test "documents all callbacks" do
      docs = Ports.callback_docs()

      assert docs =~ "ports_list"
      assert docs =~ "ports_info"
      assert docs =~ "ports_top"
      assert docs =~ "ports_list_inet"
      assert docs =~ "ports_top_by_buffer"
      assert docs =~ "ports_inet_stats"
    end
  end

  describe "ports_list_inet callback" do
    test "returns list of inet ports" do
      result = Ports.callbacks()["ports_list_inet"].()

      assert is_list(result)
    end

    test "inet port entries have expected fields" do
      result = Ports.callbacks()["ports_list_inet"].()

      if result != [] do
        [port | _] = result
        assert Map.has_key?(port, :id)
        assert Map.has_key?(port, :type)
        assert Map.has_key?(port, :local_addr)
        assert Map.has_key?(port, :remote_addr)
        assert Map.has_key?(port, :input_kb)
        assert Map.has_key?(port, :output_kb)
      end
    end

    test "filters only inet port types" do
      result = Ports.callbacks()["ports_list_inet"].()

      if result != [] do
        inet_types = ["tcp_inet", "udp_inet", "sctp_inet"]
        Enum.all?(result, fn port -> port.type in inet_types end)
      end
    end
  end

  describe "ports_top_by_buffer callback" do
    test "returns top ports by send buffer" do
      result = Ports.callbacks()["ports_top_by_buffer"].(5, "send")

      assert is_list(result)
      assert length(result) <= 5
    end

    test "returns top ports by recv buffer" do
      result = Ports.callbacks()["ports_top_by_buffer"].(5, "recv")

      assert is_list(result)
      assert length(result) <= 5
    end

    test "caps limit at 50" do
      result = Ports.callbacks()["ports_top_by_buffer"].(100, "send")

      assert length(result) <= 50
    end

    test "entries have buffer fields" do
      result = Ports.callbacks()["ports_top_by_buffer"].(5, "send")

      if result != [] do
        [port | _] = result
        assert Map.has_key?(port, :id)
        assert Map.has_key?(port, :type)
        assert Map.has_key?(port, :send_kb)
        assert Map.has_key?(port, :recv_kb)
      end
    end
  end

  describe "ports_inet_stats callback" do
    test "returns error for non-existent port" do
      result = Ports.callbacks()["ports_inet_stats"].("#Port<999.999>")

      assert result.error == "port_not_found"
    end

    test "returns error for non-inet port" do
      ports = Ports.callbacks()["ports_list"].()

      if ports != [] do
        non_inet_port =
          Enum.find(ports, fn port ->
            port.name not in ["tcp_inet", "udp_inet", "sctp_inet"]
          end)

        if non_inet_port do
          result = Ports.callbacks()["ports_inet_stats"].(non_inet_port.id)

          assert Map.has_key?(result, :error)
        end
      end
    end
  end

  describe "ports_top_by_queue callback" do
    test "returns list of ports" do
      result = Ports.callbacks()["ports_top_by_queue"].(5)

      assert is_list(result)
      assert length(result) <= 5
    end

    test "entries have expected fields" do
      result = Ports.callbacks()["ports_top_by_queue"].(5)

      if result != [] do
        [port | _] = result
        assert Map.has_key?(port, :id)
        assert Map.has_key?(port, :name)
        assert Map.has_key?(port, :queue_size)
        assert Map.has_key?(port, :connected_pid)
        assert Map.has_key?(port, :saturation_pct)
      end
    end

    test "returns ports sorted by queue size descending" do
      result = Ports.callbacks()["ports_top_by_queue"].(10)

      if length(result) > 1 do
        queue_sizes = Enum.map(result, & &1.queue_size)
        assert queue_sizes == Enum.sort(queue_sizes, :desc)
      end
    end

    test "caps limit at 50" do
      result = Ports.callbacks()["ports_top_by_queue"].(100)

      assert length(result) <= 50
    end

    test "queue sizes are non-negative" do
      result = Ports.callbacks()["ports_top_by_queue"].(10)

      Enum.all?(result, fn port ->
        assert port.queue_size >= 0
      end)
    end

    test "saturation percentage is within valid range" do
      result = Ports.callbacks()["ports_top_by_queue"].(10)

      Enum.all?(result, fn port ->
        assert port.saturation_pct >= 0
        assert port.saturation_pct <= 100
      end)
    end
  end

  describe "ports_queue_growth callback" do
    test "returns growth analysis map" do
      result = Ports.callbacks()["ports_queue_growth"].(5)

      assert is_map(result)
      assert Map.has_key?(result, :growing_ports)
      assert Map.has_key?(result, :current_queues)
    end

    test "growing_ports is a list" do
      result = Ports.callbacks()["ports_queue_growth"].(5)

      assert is_list(result.growing_ports)
    end

    test "current_queues is a map" do
      result = Ports.callbacks()["ports_queue_growth"].(5)

      assert is_map(result.current_queues)
    end

    test "growing port entries have expected fields" do
      result = Ports.callbacks()["ports_queue_growth"].(5)

      if result.growing_ports != [] do
        [port | _] = result.growing_ports
        assert Map.has_key?(port, :id)
        assert Map.has_key?(port, :current_queue)
        assert Map.has_key?(port, :growth_rate_bytes_per_sec)
        assert Map.has_key?(port, :trend)
      end
    end

    test "accepts different time windows" do
      result_5min = Ports.callbacks()["ports_queue_growth"].(5)
      result_15min = Ports.callbacks()["ports_queue_growth"].(15)

      assert is_map(result_5min)
      assert is_map(result_15min)
    end

    test "trend is valid atom when data exists" do
      result = Ports.callbacks()["ports_queue_growth"].(5)

      if result.growing_ports != [] do
        Enum.all?(result.growing_ports, fn port ->
          assert port.trend in [:growing, :shrinking, :stable, :unknown]
        end)
      end
    end

    test "growth rates are numbers when data exists" do
      result = Ports.callbacks()["ports_queue_growth"].(5)

      if result.growing_ports != [] do
        Enum.all?(result.growing_ports, fn port ->
          assert is_number(port.growth_rate_bytes_per_sec)
        end)
      end
    end
  end

  describe "ports_suspended_processes callback" do
    test "returns list of suspended processes" do
      result = Ports.callbacks()["ports_suspended_processes"].()

      assert is_list(result)
    end

    test "process entries have expected fields when data exists" do
      result = Ports.callbacks()["ports_suspended_processes"].()

      if result != [] do
        [proc | _] = result
        assert Map.has_key?(proc, :pid)
        assert Map.has_key?(proc, :message_queue_len)
        assert Map.has_key?(proc, :current_function)
        assert Map.has_key?(proc, :registered_name)
      end
    end

    test "message queue lengths are non-negative" do
      result = Ports.callbacks()["ports_suspended_processes"].()

      if result != [] do
        Enum.all?(result, fn proc ->
          assert proc.message_queue_len >= 0
        end)
      end
    end

    test "pids are strings" do
      result = Ports.callbacks()["ports_suspended_processes"].()

      if result != [] do
        Enum.all?(result, fn proc ->
          assert is_binary(proc.pid)
        end)
      end
    end

    test "registered_names are strings or anonymous" do
      result = Ports.callbacks()["ports_suspended_processes"].()

      if result != [] do
        Enum.all?(result, fn proc ->
          assert is_binary(proc.registered_name)
        end)
      end
    end
  end

  describe "ports_saturation_prediction callback" do
    test "returns list of predictions" do
      result = Ports.callbacks()["ports_saturation_prediction"].(30)

      assert is_list(result)
    end

    test "prediction entries have expected fields when data exists" do
      result = Ports.callbacks()["ports_saturation_prediction"].(30)

      if result != [] do
        [pred | _] = result
        assert Map.has_key?(pred, :id)
        assert Map.has_key?(pred, :name)
        assert Map.has_key?(pred, :current_queue_bytes)
        assert Map.has_key?(pred, :growth_rate_bytes_per_sec)
        assert Map.has_key?(pred, :saturation_threshold_bytes)
        assert Map.has_key?(pred, :minutes_until_saturation)
        assert Map.has_key?(pred, :risk_level)
      end
    end

    test "risk levels are valid atoms when predictions exist" do
      result = Ports.callbacks()["ports_saturation_prediction"].(30)

      if result != [] do
        Enum.all?(result, fn pred ->
          assert pred.risk_level in [:critical, :high, :medium, :low]
        end)
      end
    end

    test "minutes_until_saturation is positive when predictions exist" do
      result = Ports.callbacks()["ports_saturation_prediction"].(30)

      if result != [] do
        Enum.all?(result, fn pred ->
          assert pred.minutes_until_saturation > 0
        end)
      end
    end

    test "saturation_threshold is 1MB" do
      result = Ports.callbacks()["ports_saturation_prediction"].(30)

      if result != [] do
        Enum.all?(result, fn pred ->
          assert pred.saturation_threshold_bytes == 1024 * 1024
        end)
      end
    end

    test "accepts different prediction windows" do
      result_15min = Ports.callbacks()["ports_saturation_prediction"].(15)
      result_60min = Ports.callbacks()["ports_saturation_prediction"].(60)

      assert is_list(result_15min)
      assert is_list(result_60min)
    end

    test "returns predictions sorted by minutes_until_saturation" do
      result = Ports.callbacks()["ports_saturation_prediction"].(30)

      if length(result) > 1 do
        times = Enum.map(result, & &1.minutes_until_saturation)
        assert times == Enum.sort(times)
      end
    end
  end
end
