defmodule Beamlens.Skill.GcTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Skill.Gc

  describe "id/0" do
    test "returns :gc" do
      assert Gc.id() == :gc
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
    end
  end
end
