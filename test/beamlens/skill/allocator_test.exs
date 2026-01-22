defmodule Beamlens.Skill.AllocatorTest do
  use ExUnit.Case

  alias Beamlens.Skill.Allocator

  describe "allocator_summary/0" do
    test "returns list of allocators with metrics" do
      summary = Allocator.allocator_summary()

      assert is_list(summary)
      refute summary == []

      first = hd(summary)

      assert Map.has_key?(first, :name)
      assert Map.has_key?(first, :carriers)
      assert Map.has_key?(first, :blocks)
      assert Map.has_key?(first, :block_size_mb)
      assert Map.has_key?(first, :carrier_size_mb)
      assert Map.has_key?(first, :usage_ratio)
    end

    test "allocator names are valid VM allocators" do
      summary = Allocator.allocator_summary()

      valid_allocators = [
        :binary_alloc,
        :eheap_alloc,
        :ets_alloc,
        :fix_alloc,
        :literal_alloc,
        :temp_alloc,
        :sl_alloc,
        :std_alloc,
        :ll_alloc,
        :driver_alloc
      ]

      Enum.each(summary, fn allocator ->
        assert allocator.name in valid_allocators
      end)
    end

    test "usage ratio is between 0 and 1" do
      summary = Allocator.allocator_summary()

      Enum.each(summary, fn allocator ->
        assert allocator.usage_ratio >= 0.0
        assert allocator.usage_ratio <= 1.0
      end)
    end
  end

  describe "allocator_by_type/1" do
    test "returns detailed metrics for binary_alloc" do
      result = Allocator.allocator_by_type(:binary_alloc)

      refute result == nil

      assert result.name == :binary_alloc
      assert is_integer(result.carriers)
      assert is_integer(result.blocks)
      assert result.carrier_size_mb >= 0
      assert result.block_size_mb >= 0
      assert result.usage_ratio >= 0.0
      assert result.usage_ratio <= 1.0
    end

    test "returns detailed metrics for eheap_alloc" do
      result = Allocator.allocator_by_type(:eheap_alloc)

      refute result == nil

      assert result.name == :eheap_alloc
      assert is_integer(result.carriers)
      assert is_integer(result.blocks)
      assert is_integer(result.mseg_carriers)
      assert is_integer(result.sys_alloc_carriers)
    end

    test "returns detailed metrics for ets_alloc" do
      result = Allocator.allocator_by_type(:ets_alloc)

      refute result == nil

      assert result.name == :ets_alloc
      assert is_map(result)
    end

    test "returns nil for invalid allocator" do
      result = Allocator.allocator_by_type(:invalid_alloc)

      assert result == nil
    end
  end

  describe "allocator_fragmentation/0" do
    test "returns fragmentation metrics" do
      result = Allocator.allocator_fragmentation()

      assert Map.has_key?(result, :average_usage_ratio)
      assert Map.has_key?(result, :worst_allocator)
      assert Map.has_key?(result, :worst_usage_ratio)
      assert Map.has_key?(result, :fragmentation_score)

      assert result.average_usage_ratio >= 0.0
      assert result.average_usage_ratio <= 1.0
      assert result.worst_usage_ratio >= 0.0
      assert result.worst_usage_ratio <= 1.0
      assert result.fragmentation_score >= 0.0
      assert result.fragmentation_score <= 1.0
    end

    test "fragmentation score is inverse of average usage ratio" do
      result = Allocator.allocator_fragmentation()

      expected = 1.0 - result.average_usage_ratio

      assert_in_delta result.fragmentation_score, expected, 0.001
    end
  end

  describe "allocator_problematic/0" do
    test "returns list of allocators with low usage ratio" do
      result = Allocator.allocator_problematic()

      assert is_list(result)

      Enum.each(result, fn allocator ->
        assert allocator.usage_ratio < 0.5
      end)
    end

    test "returns allocators sorted by usage ratio ascending" do
      result = Allocator.allocator_problematic()

      if length(result) > 1 do
        sorted = result |> Enum.map(fn a -> a.usage_ratio end) |> Enum.sort()
        actual = result |> Enum.map(fn a -> a.usage_ratio end)

        assert actual == sorted
      end
    end

    test "may return empty list if no fragmentation detected" do
      result = Allocator.allocator_problematic()

      assert is_list(result)
    end
  end

  describe "snapshot/0" do
    test "returns aggregate metrics" do
      snapshot = Allocator.snapshot()

      assert Map.has_key?(snapshot, :allocator_count)
      assert Map.has_key?(snapshot, :total_carriers)
      assert Map.has_key?(snapshot, :fragmented_allocators)
      assert Map.has_key?(snapshot, :worst_usage_ratio)

      assert is_integer(snapshot.allocator_count)
      assert is_integer(snapshot.total_carriers)
      assert is_integer(snapshot.fragmented_allocators)
      assert snapshot.worst_usage_ratio >= 0.0
      assert snapshot.worst_usage_ratio <= 1.0
    end

    test "fragmented_allocators count matches allocator_problematic" do
      snapshot = Allocator.snapshot()
      problematic = Allocator.allocator_problematic()

      assert snapshot.fragmented_allocators == length(problematic)
    end
  end
end
