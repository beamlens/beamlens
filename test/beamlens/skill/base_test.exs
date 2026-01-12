defmodule Beamlens.Skill.BaseTest do
  use ExUnit.Case, async: true

  alias Beamlens.Skill.Base

  describe "callbacks/0" do
    test "returns map with expected keys" do
      callbacks = Base.callbacks()

      assert is_map(callbacks)
      assert Map.has_key?(callbacks, "get_current_time")
      assert Map.has_key?(callbacks, "get_node_info")
    end

    test "get_current_time callback returns valid structure" do
      callbacks = Base.callbacks()
      get_current_time = callbacks["get_current_time"]

      result = get_current_time.()

      assert is_map(result)
      assert Map.has_key?(result, :timestamp)
      assert Map.has_key?(result, :unix_ms)
      assert is_binary(result.timestamp)
      assert is_integer(result.unix_ms)
    end

    test "get_node_info callback returns valid structure" do
      callbacks = Base.callbacks()
      get_node_info = callbacks["get_node_info"]

      result = get_node_info.()

      assert is_map(result)
      assert Map.has_key?(result, :node)
      assert Map.has_key?(result, :uptime_seconds)
      assert Map.has_key?(result, :os_type)
      assert Map.has_key?(result, :os_name)
      assert is_binary(result.node)
      assert is_integer(result.uptime_seconds)
    end
  end

  describe "callback_docs/0" do
    test "returns non-empty documentation string" do
      docs = Base.callback_docs()

      assert is_binary(docs)
      assert String.length(docs) > 0
      assert String.contains?(docs, "get_current_time")
      assert String.contains?(docs, "get_node_info")
    end
  end
end
