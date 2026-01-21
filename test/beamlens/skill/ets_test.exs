defmodule Beamlens.Skill.EtsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Skill.Ets

  describe "title/0" do
    test "returns a non-empty string" do
      title = Ets.title()

      assert is_binary(title)
      assert String.length(title) > 0
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
      assert docs =~ "ets_growth_stats"
      assert docs =~ "ets_leak_candidates"
    end
  end

  describe "ets_growth_stats callback" do
    setup do
      start_supervised!({Beamlens.Skill.Ets.GrowthStore, [name: Beamlens.Skill.Ets.GrowthStore]})
      :ok
    end

    test "returns fastest growing tables" do
      result = Ets.callbacks()["ets_growth_stats"].(5)

      assert is_map(result)
      assert Map.has_key?(result, :fastest_growing_tables)
      assert is_list(result.fastest_growing_tables)
    end

    test "table entries have expected fields" do
      table = :ets.new(:test_growth_stats, [:named_table, :public])
      :ets.insert(table, {:key1, :value1})
      :ets.insert(table, {:key2, :value2})

      result = Ets.callbacks()["ets_growth_stats"].(1)

      if result.fastest_growing_tables != [] do
        [table_stat | _] = result.fastest_growing_tables

        assert Map.has_key?(table_stat, :name)
        assert Map.has_key?(table_stat, :size_delta)
        assert Map.has_key?(table_stat, :growth_pct)
        assert Map.has_key?(table_stat, :current_size)
        assert Map.has_key?(table_stat, :memory_mb)
      end

      :ets.delete(table)
    end
  end

  describe "ets_leak_candidates callback" do
    setup do
      start_supervised!({Beamlens.Skill.Ets.GrowthStore, [name: Beamlens.Skill.Ets.GrowthStore]})
      :ok
    end

    test "returns suspected leak candidates" do
      result = Ets.callbacks()["ets_leak_candidates"].(50.0)

      assert is_map(result)
      assert Map.has_key?(result, :suspected_leaks)
      assert is_list(result.suspected_leaks)
    end

    test "leak candidate entries have expected fields" do
      result = Ets.callbacks()["ets_leak_candidates"].(50.0)

      if result.suspected_leaks != [] do
        [leak | _] = result.suspected_leaks

        assert Map.has_key?(leak, :name)
        assert Map.has_key?(leak, :growth_pct)
        assert Map.has_key?(leak, :size_delta)
        assert Map.has_key?(leak, :current_size)
        assert Map.has_key?(leak, :memory_mb)
        assert Map.has_key?(leak, :only_grows)
        assert leak.only_grows == true
      end
    end
  end
end
