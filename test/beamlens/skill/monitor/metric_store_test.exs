defmodule Beamlens.Skill.Monitor.MetricStoreTest do
  use ExUnit.Case

  alias Beamlens.Skill.Monitor.MetricStore

  setup do
    {:ok, pid} = MetricStore.start_link([])
    %{store: pid}
  end

  describe "add_sample/4" do
    test "stores a metric sample", %{store: store} do
      assert :ok = MetricStore.add_sample(store, :beam, :memory_mb, 100.0)

      samples = MetricStore.get_samples(store, :beam, :memory_mb, 60_000)
      assert length(samples) == 1
      assert hd(samples).value == 100.0
    end

    test "stores samples with unique timestamps", %{store: store} do
      :ok = MetricStore.add_sample(store, :beam, :memory_mb, 100.0)
      Process.sleep(2)
      :ok = MetricStore.add_sample(store, :beam, :memory_mb, 110.0)

      samples = MetricStore.get_samples(store, :beam, :memory_mb, 60_000)
      assert length(samples) == 2
    end
  end

  describe "get_samples/4" do
    test "returns samples within time window", %{store: store} do
      MetricStore.add_sample(store, :beam, :memory_mb, 100.0)

      samples = MetricStore.get_samples(store, :beam, :memory_mb, 60_000)
      assert length(samples) == 1
    end

    test "returns empty list for non-existent skill", %{store: store} do
      samples = MetricStore.get_samples(store, :nonexistent, :metric, 60_000)
      assert samples == []
    end

    test "returns empty list for non-existent metric", %{store: store} do
      MetricStore.add_sample(store, :beam, :memory_mb, 100.0)

      samples = MetricStore.get_samples(store, :beam, :nonexistent, 60_000)
      assert samples == []
    end

    test "sorts samples by timestamp", %{store: store} do
      MetricStore.add_sample(store, :beam, :memory_mb, 100.0)
      Process.sleep(2)
      MetricStore.add_sample(store, :beam, :memory_mb, 110.0)
      Process.sleep(2)
      MetricStore.add_sample(store, :beam, :memory_mb, 105.0)

      samples = MetricStore.get_samples(store, :beam, :memory_mb, 60_000)
      timestamps = Enum.map(samples, & &1.timestamp)

      assert length(samples) == 3
      assert timestamps == Enum.sort(timestamps)
    end
  end

  describe "get_latest/3" do
    test "returns most recent sample", %{store: store} do
      MetricStore.add_sample(store, :beam, :memory_mb, 100.0)
      MetricStore.add_sample(store, :beam, :memory_mb, 110.0)

      latest = MetricStore.get_latest(store, :beam, :memory_mb)
      assert latest.value == 110.0
    end

    test "returns nil for non-existent skill", %{store: store} do
      latest = MetricStore.get_latest(store, :nonexistent, :metric)
      assert is_nil(latest)
    end

    test "returns nil for non-existent metric", %{store: store} do
      MetricStore.add_sample(store, :beam, :memory_mb, 100.0)

      latest = MetricStore.get_latest(store, :beam, :nonexistent)
      assert is_nil(latest)
    end
  end

  describe "clear/3" do
    test "removes all samples for skill/metric", %{store: store} do
      MetricStore.add_sample(store, :beam, :memory_mb, 100.0)
      MetricStore.add_sample(store, :beam, :memory_mb, 110.0)

      assert :ok = MetricStore.clear(store, :beam, :memory_mb)

      samples = MetricStore.get_samples(store, :beam, :memory_mb, 60_000)
      assert samples == []
    end

    test "does not affect other metrics", %{store: store} do
      MetricStore.add_sample(store, :beam, :memory_mb, 100.0)
      MetricStore.add_sample(store, :beam, :process_count, 50.0)

      MetricStore.clear(store, :beam, :memory_mb)

      memory_samples = MetricStore.get_samples(store, :beam, :memory_mb, 60_000)
      process_samples = MetricStore.get_samples(store, :beam, :process_count, 60_000)

      assert memory_samples == []
      assert length(process_samples) == 1
    end
  end

  describe "get_all_samples/1" do
    test "returns all stored samples", %{store: store} do
      MetricStore.add_sample(store, :beam, :memory_mb, 100.0)
      MetricStore.add_sample(store, :beam, :process_count, 50.0)
      MetricStore.add_sample(store, :ets, :table_count, 10.0)

      all = MetricStore.get_all_samples(store)
      assert length(all) == 3
    end

    test "returns empty list when no samples", %{store: store} do
      all = MetricStore.get_all_samples(store)
      assert all == []
    end
  end

  describe "pruning" do
    test "prunes old samples based on history configuration" do
      {:ok, store} = MetricStore.start_link(history_minutes: 0, sample_interval_ms: 100)

      MetricStore.add_sample(store, :beam, :memory_mb, 100.0)

      Process.sleep(150)

      MetricStore.add_sample(store, :beam, :memory_mb, 110.0)

      samples = MetricStore.get_samples(store, :beam, :memory_mb, 60_000)

      assert length(samples) <= 2
    end
  end
end
