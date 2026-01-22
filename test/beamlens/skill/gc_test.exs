defmodule Beamlens.Skill.GcTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Skill.Gc

  describe "title/0" do
    test "returns a non-empty string" do
      title = Gc.title()

      assert is_binary(title)
      assert String.length(title) > 0
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      description = Gc.description()

      assert is_binary(description)
      assert String.length(description) > 0
    end
  end

  describe "system_prompt/0" do
    test "returns a non-empty string" do
      system_prompt = Gc.system_prompt()

      assert is_binary(system_prompt)
      assert String.length(system_prompt) > 0
    end
  end

  describe "snapshot/0" do
    test "returns GC statistics" do
      snapshot = Gc.snapshot()

      assert is_integer(snapshot.total_gcs)
      assert is_integer(snapshot.words_reclaimed)
      assert is_float(snapshot.bytes_reclaimed_mb)
    end

    test "total_gcs is non-negative" do
      snapshot = Gc.snapshot()
      assert snapshot.total_gcs >= 0
    end
  end

  describe "callbacks/0" do
    test "returns callback map with expected keys" do
      callbacks = Gc.callbacks()

      assert is_map(callbacks)
      assert Map.has_key?(callbacks, "gc_stats")
      assert Map.has_key?(callbacks, "gc_top_processes")
    end

    test "callbacks are functions with correct arity" do
      callbacks = Gc.callbacks()

      assert is_function(callbacks["gc_stats"], 0)
      assert is_function(callbacks["gc_top_processes"], 1)
    end
  end

  describe "gc_stats callback" do
    test "returns global GC statistics" do
      result = Gc.callbacks()["gc_stats"].()

      assert is_integer(result.total_gcs)
      assert is_integer(result.words_reclaimed)
      assert is_float(result.bytes_reclaimed_mb)
    end
  end

  describe "gc_top_processes callback" do
    test "returns top processes by heap size" do
      result = Gc.callbacks()["gc_top_processes"].(5)

      assert is_list(result)
      assert length(result) <= 5
    end

    test "process entries have expected fields" do
      result = Gc.callbacks()["gc_top_processes"].(1)

      if result != [] do
        [proc | _] = result
        assert Map.has_key?(proc, :pid)
        assert Map.has_key?(proc, :heap_size_kb)
        assert Map.has_key?(proc, :total_heap_size_kb)
        assert Map.has_key?(proc, :minor_gcs)
        assert Map.has_key?(proc, :message_queue_len)
      end
    end

    test "caps limit at 50" do
      result = Gc.callbacks()["gc_top_processes"].(100)

      assert length(result) <= 50
    end
  end

  describe "callback_docs/0" do
    test "returns non-empty string" do
      docs = Gc.callback_docs()

      assert is_binary(docs)
      assert String.length(docs) > 0
    end

    test "documents all callbacks" do
      docs = Gc.callback_docs()

      assert docs =~ "gc_stats"
      assert docs =~ "gc_top_processes"
      assert docs =~ "gc_find_spiky_processes"
      assert docs =~ "gc_find_lazy_gc_processes"
      assert docs =~ "gc_calculate_efficiency"
      assert docs =~ "gc_recommend_hibernation"
      assert docs =~ "gc_get_long_gcs"
    end
  end

  describe "gc_find_spiky_processes callback" do
    test "returns list of processes with high memory variance" do
      result = Gc.callbacks()["gc_find_spiky_processes"].(0.01)

      assert is_list(result)
    end

    test "process entries have expected fields" do
      result = Gc.callbacks()["gc_find_spiky_processes"].(0.01)

      if result != [] do
        [proc | _] = result
        assert Map.has_key?(proc, :pid)
        assert Map.has_key?(proc, :heap_size_kb)
        assert Map.has_key?(proc, :total_heap_size_kb)
        assert Map.has_key?(proc, :variance_mb)
        assert Map.has_key?(proc, :stack_size_kb)
      end
    end

    test "higher threshold returns fewer or equal processes" do
      low = Gc.callbacks()["gc_find_spiky_processes"].(0.01)
      high = Gc.callbacks()["gc_find_spiky_processes"].(10.0)

      assert length(high) <= length(low)
    end

    test "returns processes sorted by variance descending" do
      result = Gc.callbacks()["gc_find_spiky_processes"].(0.01)

      if length(result) > 1 do
        variances = Enum.map(result, & &1.variance_mb)
        assert variances == Enum.sort(variances, :desc)
      end
    end
  end

  describe "gc_find_lazy_gc_processes callback" do
    test "returns list of processes with lazy GC" do
      result = Gc.callbacks()["gc_find_lazy_gc_processes"].(1.0, 5.0)

      assert is_list(result)
    end

    test "process entries have expected fields" do
      result = Gc.callbacks()["gc_find_lazy_gc_processes"].(1.0, 5.0)

      if result != [] do
        [proc | _] = result
        assert Map.has_key?(proc, :pid)
        assert Map.has_key?(proc, :heap_size_mb)
        assert Map.has_key?(proc, :total_heap_size_mb)
        assert Map.has_key?(proc, :last_gc_minutes_ago)
        assert Map.has_key?(proc, :minor_gcs)
      end
    end

    test "higher min_heap_mb returns fewer or equal processes" do
      low = Gc.callbacks()["gc_find_lazy_gc_processes"].(0.1, 5.0)
      high = Gc.callbacks()["gc_find_lazy_gc_processes"].(100.0, 5.0)

      assert length(high) <= length(low)
    end

    test "returns processes sorted by heap size descending" do
      result = Gc.callbacks()["gc_find_lazy_gc_processes"].(1.0, 5.0)

      if length(result) > 1 do
        heap_sizes = Enum.map(result, & &1.heap_size_mb)
        assert heap_sizes == Enum.sort(heap_sizes, :desc)
      end
    end
  end

  describe "gc_calculate_efficiency callback" do
    test "returns efficiency info for current process" do
      result = Gc.callbacks()["gc_calculate_efficiency"].(inspect(self()))

      assert is_map(result)
      assert Map.has_key?(result, :pid)
    end

    test "process entries have expected fields when found" do
      result = Gc.callbacks()["gc_calculate_efficiency"].(inspect(self()))

      unless Map.has_key?(result, :error) do
        assert Map.has_key?(result, :efficiency_ratio)
        assert Map.has_key?(result, :total_reclaimed_mb)
        assert Map.has_key?(result, :total_allocated_mb)
        assert Map.has_key?(result, :minor_gcs)

        assert is_float(result.efficiency_ratio)
        assert result.efficiency_ratio >= 0.0
        assert result.efficiency_ratio <= 1.0
      end
    end

    test "returns error for non-existent process" do
      result = Gc.callbacks()["gc_calculate_efficiency"].("0.999.0")

      assert is_map(result)
      assert Map.has_key?(result, :error)
      assert result.error == "process_not_found"
    end
  end

  describe "gc_recommend_hibernation callback" do
    test "returns list of hibernation candidates" do
      result = Gc.callbacks()["gc_recommend_hibernation"].()

      assert is_list(result)
    end

    test "process entries have expected fields" do
      result = Gc.callbacks()["gc_recommend_hibernation"].()

      if result != [] do
        [proc | _] = result
        assert Map.has_key?(proc, :pid)
        assert Map.has_key?(proc, :heap_size_mb)
        assert Map.has_key?(proc, :message_queue_len)
        assert Map.has_key?(proc, :estimated_savings_mb)
        assert proc.message_queue_len == 0
      end
    end

    test "returns processes sorted by estimated savings descending" do
      result = Gc.callbacks()["gc_recommend_hibernation"].()

      if length(result) > 1 do
        savings = Enum.map(result, & &1.estimated_savings_mb)
        assert savings == Enum.sort(savings, :desc)
      end
    end

    test "only includes processes with registered names" do
      result = Gc.callbacks()["gc_recommend_hibernation"].()

      Enum.each(result, fn proc ->
        assert proc.name != nil
      end)
    end
  end

  describe "gc_get_long_gcs callback" do
    test "returns list of long GC events" do
      result = Gc.callbacks()["gc_get_long_gcs"].(10)

      assert is_list(result)
    end

    test "returns empty list when EventStore is not running" do
      result = Gc.callbacks()["gc_get_long_gcs"].(10)

      assert is_list(result)
    end

    test "respects limit parameter" do
      result = Gc.callbacks()["gc_get_long_gcs"].(5)

      assert length(result) <= 5
    end

    test "event entries have expected fields when available" do
      result = Gc.callbacks()["gc_get_long_gcs"].(10)

      if result != [] do
        [event | _] = result
        assert Map.has_key?(event, :datetime)
        assert Map.has_key?(event, :pid)
        assert Map.has_key?(event, :duration_ms)
      end
    end
  end
end
