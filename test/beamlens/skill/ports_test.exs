defmodule Beamlens.Skill.PortsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Skill.Ports

  describe "id/0" do
    test "returns :ports" do
      assert Ports.id() == :ports
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
    end
  end
end
