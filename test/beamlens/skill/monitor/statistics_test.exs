defmodule Beamlens.Skill.Monitor.StatisticsTest do
  use ExUnit.Case

  alias Beamlens.Skill.Monitor.Statistics

  describe "mean/1" do
    test "calculates arithmetic mean" do
      assert Statistics.mean([1.0, 2.0, 3.0, 4.0, 5.0]) == 3.0
      assert Statistics.mean([10.0, 20.0, 30.0]) == 20.0
    end

    test "returns 0.0 for empty list" do
      assert Statistics.mean([]) == 0.0
    end

    test "handles single element" do
      assert Statistics.mean([5.0]) == 5.0
    end

    test "handles negative numbers" do
      assert Statistics.mean([-5.0, 5.0]) == 0.0
    end
  end

  describe "std_dev/2" do
    test "calculates population standard deviation" do
      assert Statistics.std_dev([2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0], 5.0)
             |> Float.round(4) == 2.0
    end

    test "returns 0.0 for empty list" do
      assert Statistics.std_dev([], 0.0) == 0.0
    end

    test "returns 0.0 for single element" do
      assert Statistics.std_dev([5.0], 5.0) == 0.0
    end

    test "returns 0.0 for constant values" do
      assert Statistics.std_dev([5.0, 5.0, 5.0], 5.0) == 0.0
    end
  end

  describe "z_score/3" do
    test "calculates z-score correctly" do
      assert Statistics.z_score(15.0, 10.0, 2.0) == 2.5
      assert Statistics.z_score(5.0, 10.0, 2.0) == -2.5
      assert Statistics.z_score(10.0, 10.0, 2.0) == 0.0
    end

    test "returns 0.0 when std_dev is 0" do
      assert Statistics.z_score(100.0, 10.0, 0.0) == 0.0
    end
  end

  describe "percentile/2" do
    test "calculates median (50th percentile)" do
      assert Statistics.percentile([1.0, 2.0, 3.0, 4.0, 5.0], 50) == 3.0
      assert Statistics.percentile([1.0, 2.0, 3.0, 4.0], 50) == 2.5
    end

    test "calculates 95th percentile" do
      values = Enum.to_list(1..100) |> Enum.map(&(&1 * 1.0))
      result = Statistics.percentile(values, 95)
      assert_in_delta result, 95.0, 0.1
    end

    test "calculates 99th percentile" do
      values = Enum.to_list(1..100) |> Enum.map(&(&1 * 1.0))
      result = Statistics.percentile(values, 99)
      assert_in_delta result, 99.0, 0.1
    end

    test "returns 0.0 for empty list" do
      assert Statistics.percentile([], 50) == 0.0
    end

    test "handles single element" do
      assert Statistics.percentile([42.0], 50) == 42.0
    end
  end

  describe "ema/2" do
    test "calculates exponential moving average" do
      result = Statistics.ema([1.0, 2.0, 3.0, 4.0, 5.0], 0.5)
      assert_in_delta result, 4.0625, 0.01
    end

    test "returns first value for single element" do
      assert Statistics.ema([5.0], 0.5) == 5.0
    end

    test "returns 0.0 for empty list" do
      assert Statistics.ema([], 0.5) == 0.0
    end

    test "higher alpha weights recent data more" do
      values = [1.0, 2.0, 3.0, 4.0, 5.0, 10.0]

      ema_high = Statistics.ema(values, 0.9)
      ema_low = Statistics.ema(values, 0.1)

      assert ema_high > ema_low
    end
  end

  describe "detect_anomaly?/3" do
    test "detects anomaly when z-score exceeds threshold" do
      baseline = %{mean: 100.0, std_dev: 10.0}

      assert Statistics.detect_anomaly?(135.0, baseline, 3.0) == true
      assert Statistics.detect_anomaly?(65.0, baseline, 3.0) == true
    end

    test "does not detect anomaly within threshold" do
      baseline = %{mean: 100.0, std_dev: 10.0}

      assert Statistics.detect_anomaly?(125.0, baseline, 3.0) == false
      assert Statistics.detect_anomaly?(75.0, baseline, 3.0) == false
    end

    test "handles zero std_dev" do
      baseline = %{mean: 100.0, std_dev: 0.0}

      assert Statistics.detect_anomaly?(1000.0, baseline, 3.0) == false
    end
  end

  describe "calculate_baseline/1" do
    test "calculates full baseline statistics" do
      samples = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]

      baseline = Statistics.calculate_baseline(samples)

      assert baseline.mean == 5.5
      assert baseline.sample_count == 10
      assert baseline.percentile_50 == 5.5
      assert baseline.std_dev > 0
      assert_in_delta baseline.percentile_95, 9.55, 0.1
    end

    test "returns zero baseline for empty list" do
      baseline = Statistics.calculate_baseline([])

      assert baseline.mean == 0.0
      assert baseline.std_dev == 0.0
      assert baseline.percentile_50 == 0.0
      assert baseline.percentile_95 == 0.0
      assert baseline.percentile_99 == 0.0
      assert baseline.sample_count == 0
    end
  end
end
