defmodule Beamlens.Skill.EtsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Skill.Ets

  describe "id/0" do
    test "returns :ets" do
      assert Ets.id() == :ets
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      description = Ets.description()

      assert is_binary(description)
      assert String.length(description) > 0
    end
  end

  describe "system_prompt/0" do
    test "returns a non-empty string" do
      system_prompt = Ets.system_prompt()

      assert is_binary(system_prompt)
      assert String.length(system_prompt) > 0
    end
  end

  describe "snapshot/0" do
    test "returns table count and memory" do
      snapshot = Ets.snapshot()

      assert is_integer(snapshot.table_count)
      assert is_float(snapshot.total_memory_mb)
      assert is_float(snapshot.largest_table_mb)
    end

    test "table_count is positive" do
      snapshot = Ets.snapshot()
      assert snapshot.table_count > 0
    end
  end

  describe "callbacks/0" do
    test "returns callback map with expected keys" do
      callbacks = Ets.callbacks()

      assert is_map(callbacks)
      assert Map.has_key?(callbacks, "ets_list_tables")
      assert Map.has_key?(callbacks, "ets_table_info")
      assert Map.has_key?(callbacks, "ets_top_tables")
    end

    test "callbacks are functions with correct arity" do
      callbacks = Ets.callbacks()

      assert is_function(callbacks["ets_list_tables"], 0)
      assert is_function(callbacks["ets_table_info"], 1)
      assert is_function(callbacks["ets_top_tables"], 2)
    end
  end

  describe "ets_list_tables callback" do
    test "returns list of tables" do
      result = Ets.callbacks()["ets_list_tables"].()

      assert is_list(result)
      assert result != []
    end

    test "table entries have expected fields" do
      result = Ets.callbacks()["ets_list_tables"].()

      [table | _] = result
      assert Map.has_key?(table, :name)
      assert Map.has_key?(table, :type)
      assert Map.has_key?(table, :protection)
      assert Map.has_key?(table, :size)
      assert Map.has_key?(table, :memory_kb)
    end
  end

  describe "ets_table_info callback" do
    test "returns table details for existing table" do
      :ets.new(:test_ets_info_table, [:named_table, :public])
      result = Ets.callbacks()["ets_table_info"].("test_ets_info_table")

      assert result.name == "test_ets_info_table"
      assert result.type == :set
      assert result.protection == :public
      assert is_integer(result.size)
      assert is_integer(result.memory_kb)

      :ets.delete(:test_ets_info_table)
    end

    test "returns error for non-existent table" do
      result = Ets.callbacks()["ets_table_info"].("nonexistent_table_xyz")

      assert result.error == "table_not_found"
    end
  end

  describe "ets_top_tables callback" do
    test "returns top tables by memory" do
      result = Ets.callbacks()["ets_top_tables"].(5, "memory")

      assert is_list(result)
      assert length(result) <= 5
    end

    test "returns top tables by size" do
      result = Ets.callbacks()["ets_top_tables"].(5, "size")

      assert is_list(result)
      assert length(result) <= 5
    end

    test "caps limit at 50" do
      result = Ets.callbacks()["ets_top_tables"].(100, "memory")

      assert length(result) <= 50
    end
  end

  describe "callback_docs/0" do
    test "returns non-empty string" do
      docs = Ets.callback_docs()

      assert is_binary(docs)
      assert String.length(docs) > 0
    end

    test "documents all callbacks" do
      docs = Ets.callback_docs()

      assert docs =~ "ets_list_tables"
      assert docs =~ "ets_table_info"
      assert docs =~ "ets_top_tables"
    end
  end
end
