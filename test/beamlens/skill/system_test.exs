defmodule Beamlens.Skill.SystemTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.Skill.System

  describe "id/0" do
    test "returns :system" do
      assert System.id() == :system
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      description = System.description()

      assert is_binary(description)
      assert String.length(description) > 0
    end
  end

  describe "system_prompt/0" do
    test "returns a non-empty string" do
      system_prompt = System.system_prompt()

      assert is_binary(system_prompt)
      assert String.length(system_prompt) > 0
    end
  end

  describe "snapshot/0" do
    test "returns expected keys" do
      snapshot = System.snapshot()

      assert Map.has_key?(snapshot, :cpu_load_1m)
      assert Map.has_key?(snapshot, :cpu_load_5m)
      assert Map.has_key?(snapshot, :cpu_load_15m)
      assert Map.has_key?(snapshot, :memory_used_pct)
      assert Map.has_key?(snapshot, :disk_max_used_pct)
    end

    test "cpu load values are floats" do
      snapshot = System.snapshot()

      assert is_float(snapshot.cpu_load_1m)
      assert is_float(snapshot.cpu_load_5m)
      assert is_float(snapshot.cpu_load_15m)
    end

    test "memory_used_pct is a valid percentage" do
      snapshot = System.snapshot()

      assert is_float(snapshot.memory_used_pct)
      assert snapshot.memory_used_pct >= 0
      assert snapshot.memory_used_pct <= 100
    end

    test "disk_max_used_pct is a valid percentage" do
      snapshot = System.snapshot()

      assert is_integer(snapshot.disk_max_used_pct)
      assert snapshot.disk_max_used_pct >= 0
      assert snapshot.disk_max_used_pct <= 100
    end
  end

  describe "callbacks/0" do
    test "returns callback map with expected keys" do
      callbacks = System.callbacks()

      assert is_map(callbacks)
      assert Map.has_key?(callbacks, "system_get_cpu")
      assert Map.has_key?(callbacks, "system_get_memory")
      assert Map.has_key?(callbacks, "system_get_disks")
    end

    test "callbacks are functions with correct arity" do
      callbacks = System.callbacks()

      assert is_function(callbacks["system_get_cpu"], 0)
      assert is_function(callbacks["system_get_memory"], 0)
      assert is_function(callbacks["system_get_disks"], 0)
    end
  end

  describe "system_get_cpu callback" do
    test "returns cpu metrics" do
      stats = System.callbacks()["system_get_cpu"].()

      assert is_float(stats.load_1m)
      assert is_float(stats.load_5m)
      assert is_float(stats.load_15m)
      assert is_integer(stats.process_count)
    end

    test "load values are non-negative" do
      stats = System.callbacks()["system_get_cpu"].()

      assert stats.load_1m >= 0
      assert stats.load_5m >= 0
      assert stats.load_15m >= 0
    end
  end

  describe "system_get_memory callback" do
    test "returns memory stats in MB" do
      stats = System.callbacks()["system_get_memory"].()

      assert is_float(stats.total_mb)
      assert is_float(stats.used_mb)
      assert is_float(stats.free_mb)
      assert is_float(stats.used_pct)
      assert is_float(stats.buffered_mb)
      assert is_float(stats.cached_mb)
    end

    test "total is positive" do
      stats = System.callbacks()["system_get_memory"].()

      assert stats.total_mb > 0
    end

    test "used_pct is valid percentage" do
      stats = System.callbacks()["system_get_memory"].()

      assert stats.used_pct >= 0
      assert stats.used_pct <= 100
    end
  end

  describe "system_get_disks callback" do
    test "returns list of disk info" do
      disks = System.callbacks()["system_get_disks"].()

      assert is_list(disks)
    end

    test "each disk has expected fields" do
      disks = System.callbacks()["system_get_disks"].()

      assert disks != [], "Expected at least one disk mount"

      disk = hd(disks)
      assert is_binary(disk.mount)
      assert is_float(disk.total_mb)
      assert is_integer(disk.used_pct)
    end

    test "disk used_pct values are valid percentages" do
      disks = System.callbacks()["system_get_disks"].()

      Enum.each(disks, fn disk ->
        assert disk.used_pct >= 0
        assert disk.used_pct <= 100
      end)
    end
  end

  describe "callback_docs/0" do
    test "returns non-empty string" do
      docs = System.callback_docs()

      assert is_binary(docs)
      assert String.length(docs) > 0
    end

    test "documents all callbacks" do
      docs = System.callback_docs()

      assert docs =~ "system_get_cpu"
      assert docs =~ "system_get_memory"
      assert docs =~ "system_get_disks"
    end
  end
end
