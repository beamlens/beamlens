defmodule Beamlens.Skill.Monitor.BaselineStoreTest do
  use ExUnit.Case, async: false

  alias Beamlens.Skill.Monitor.BaselineStore

  setup do
    start_supervised!(
      {BaselineStore,
       [
         name: :test_baseline_store,
         ets_table: :test_baselines,
         dets_file: nil
       ]}
    )

    :ok
  end

  describe "get_baseline/3" do
    test "returns nil for non-existent baseline" do
      assert BaselineStore.get_baseline(:test_baseline_store, :beam, :memory_mb) == nil
    end

    test "returns stored baseline" do
      samples = [100.0, 102.0, 98.0, 101.0, 99.0]

      {:ok, baseline} =
        BaselineStore.update_baseline(:test_baseline_store, :beam, :memory_mb, samples)

      retrieved = BaselineStore.get_baseline(:test_baseline_store, :beam, :memory_mb)

      assert retrieved.mean == baseline.mean
      assert retrieved.std_dev == baseline.std_dev
      assert retrieved.skill == :beam
      assert retrieved.metric == :memory_mb
      assert is_integer(retrieved.last_updated)
    end
  end

  describe "update_baseline/4" do
    test "calculates and stores baseline from samples" do
      samples = [50.0, 52.0, 48.0, 51.0, 49.0, 50.5, 49.5]

      assert {:ok, baseline} =
               BaselineStore.update_baseline(:test_baseline_store, :ets, :table_count, samples)

      assert_in_delta 50.0, baseline.mean, 0.5
      assert baseline.std_dev > 0
      assert baseline.percentile_50 > 48
      assert baseline.percentile_50 < 52
      assert baseline.percentile_95 > 48
      assert baseline.percentile_95 < 52
      assert baseline.sample_count == 7
      assert baseline.skill == :ets
      assert baseline.metric == :table_count
      assert is_integer(baseline.last_updated)
    end

    test "handles empty sample list" do
      assert {:ok, baseline} =
               BaselineStore.update_baseline(:test_baseline_store, :beam, :memory_mb, [])

      assert baseline.mean == 0.0
      assert baseline.std_dev == 0.0
      assert baseline.sample_count == 0
    end

    test "handles single sample" do
      samples = [100.0]

      assert {:ok, baseline} =
               BaselineStore.update_baseline(:test_baseline_store, :beam, :memory_mb, samples)

      assert baseline.mean == 100.0
      assert baseline.std_dev == 0.0
      assert baseline.sample_count == 1
    end

    test "updates existing baseline" do
      samples1 = [100.0, 102.0, 98.0]
      BaselineStore.update_baseline(:test_baseline_store, :beam, :memory_mb, samples1)

      samples2 = [200.0, 202.0, 198.0]

      assert {:ok, baseline} =
               BaselineStore.update_baseline(:test_baseline_store, :beam, :memory_mb, samples2)

      assert_in_delta 200.0, baseline.mean, 0.5
      assert baseline.sample_count == 3
    end
  end

  describe "clear/3" do
    test "removes stored baseline" do
      samples = [100.0, 102.0, 98.0]
      BaselineStore.update_baseline(:test_baseline_store, :beam, :memory_mb, samples)

      assert :ok = BaselineStore.clear(:test_baseline_store, :beam, :memory_mb)

      assert BaselineStore.get_baseline(:test_baseline_store, :beam, :memory_mb) == nil
    end

    test "clearing non-existent baseline is no-op" do
      assert :ok = BaselineStore.clear(:test_baseline_store, :beam, :nonexistent)
      assert BaselineStore.get_baseline(:test_baseline_store, :beam, :nonexistent) == nil
    end
  end

  describe "get_all_baselines/1" do
    test "returns empty map when no baselines stored" do
      baselines = BaselineStore.get_all_baselines(:test_baseline_store)
      assert baselines == []
    end

    test "returns all stored baselines" do
      samples1 = [100.0, 102.0, 98.0]
      BaselineStore.update_baseline(:test_baseline_store, :beam, :memory_mb, samples1)

      samples2 = [10, 12, 8, 11, 9]
      BaselineStore.update_baseline(:test_baseline_store, :ets, :table_count, samples2)

      samples3 = [5.0, 5.5, 4.5]
      BaselineStore.update_baseline(:test_baseline_store, :system, :process_count, samples3)

      baselines = BaselineStore.get_all_baselines(:test_baseline_store)

      assert length(baselines) == 3

      beam_baseline =
        Enum.find(baselines, fn b -> b.skill == :beam and b.metric == :memory_mb end)

      ets_baseline =
        Enum.find(baselines, fn b -> b.skill == :ets and b.metric == :table_count end)

      system_baseline =
        Enum.find(baselines, fn b -> b.skill == :system and b.metric == :process_count end)

      assert beam_baseline.mean > 90
      assert ets_baseline.sample_count == 5
      assert system_baseline.mean > 4
    end
  end

  describe "DETS persistence" do
    test "returns error when DETS not enabled" do
      assert {:error, :dets_not_enabled} = BaselineStore.save_to_dets(:test_baseline_store)
    end
  end
end
