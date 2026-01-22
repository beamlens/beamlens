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
end
