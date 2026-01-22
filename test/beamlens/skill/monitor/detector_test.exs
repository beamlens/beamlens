defmodule Beamlens.Skill.Monitor.DetectorTest do
  use ExUnit.Case, async: false

  alias Beamlens.Skill.Monitor.BaselineStore
  alias Beamlens.Skill.Monitor.Detector
  alias Beamlens.Skill.Monitor.MetricStore

  @skill_beam Beamlens.Skill.Beam

  setup do
    metric_store =
      start_supervised!(
        {MetricStore,
         [
           name: :test_metric_store,
           sample_interval_ms: 1000,
           history_minutes: 1
         ]}
      )

    baseline_store =
      start_supervised!(
        {BaselineStore,
         [
           name: :test_baseline_store,
           ets_table: :test_baselines,
           dets_file: nil
         ]}
      )

    {:ok, metric_store: metric_store, baseline_store: baseline_store}
  end

  describe "start_link/1" do
    test "starts in learning state" do
      {:ok, pid} =
        start_supervised(
          {Detector,
           [
             name: :test_detector_learning,
             metric_store: :test_metric_store,
             baseline_store: :test_baseline_store,
             collection_interval_ms: 100,
             learning_duration_ms: 500,
             skills: [@skill_beam]
           ]}
        )

      assert :learning = Detector.get_state(:test_detector_learning)
      assert Process.alive?(pid)
    end

    test "requires metric_store and baseline_store" do
      assert {:ok, _pid} =
               start_supervised(
                 {Detector,
                  [
                    name: :test_detector_no_deps,
                    metric_store: :nonexistent_store,
                    baseline_store: :nonexistent_store
                  ]}
               )
    end
  end

  describe "get_state/1" do
    test "returns current state" do
      start_supervised(
        {Detector,
         [
           name: :test_detector_state,
           metric_store: :test_metric_store,
           baseline_store: :test_baseline_store,
           collection_interval_ms: 100,
           learning_duration_ms: 500,
           skills: [@skill_beam]
         ]}
      )

      assert :learning = Detector.get_state(:test_detector_state)
    end
  end

  describe "get_status/1" do
    test "returns detailed status information" do
      start_supervised(
        {Detector,
         [
           name: :test_detector_status,
           metric_store: :test_metric_store,
           baseline_store: :test_baseline_store,
           collection_interval_ms: 100,
           learning_duration_ms: 500,
           skills: [@skill_beam]
         ]}
      )

      status = Detector.get_status(:test_detector_status)

      assert status.state == :learning
      assert is_integer(status.learning_start_time)
      assert status.learning_elapsed_ms >= 0
      assert status.collection_interval_ms == 100
      assert status.consecutive_count == 0
    end
  end

  describe "learning phase" do
    test "transitions to active after learning duration" do
      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_learning_transition,
             metric_store: :test_metric_store,
             baseline_store: :test_baseline_store,
             collection_interval_ms: 60_000,
             learning_duration_ms: 100,
             skills: [@skill_beam]
           ]}
        )

      past_time = System.system_time(:millisecond) - 200

      :sys.replace_state(pid, fn state ->
        %{state | learning_start_time: past_time}
      end)

      send(pid, :collect)
      _ = :sys.get_state(pid)

      assert :active = Detector.get_state(:test_detector_learning_transition)
    end

    test "calculates baselines after learning" do
      for i <- 1..5 do
        MetricStore.add_sample(
          :test_metric_store,
          @skill_beam,
          :process_utilization_pct,
          50.0 + i
        )
      end

      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_baseline_calc,
             metric_store: :test_metric_store,
             baseline_store: :test_baseline_store,
             collection_interval_ms: 60_000,
             learning_duration_ms: 100,
             skills: [@skill_beam]
           ]}
        )

      past_time = System.system_time(:millisecond) - 200

      :sys.replace_state(pid, fn state ->
        %{state | learning_start_time: past_time}
      end)

      send(pid, :collect)
      _ = :sys.get_state(pid)

      baseline =
        BaselineStore.get_baseline(:test_baseline_store, @skill_beam, :process_utilization_pct)

      assert baseline != nil
      assert baseline.sample_count > 0
      assert is_number(baseline.mean)
    end
  end

  describe "anomaly detection" do
    setup do
      BaselineStore.update_baseline(
        :test_baseline_store,
        @skill_beam,
        :process_utilization_pct,
        [45.0, 47.0, 50.0, 53.0, 55.0]
      )

      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_anomaly,
             metric_store: :test_metric_store,
             baseline_store: :test_baseline_store,
             collection_interval_ms: 60_000,
             learning_duration_ms: 100,
             z_threshold: 2.0,
             consecutive_required: 2,
             cooldown_ms: 200,
             skills: [@skill_beam]
           ]}
        )

      :sys.replace_state(pid, fn state ->
        %{state | state: :active, learning_start_time: nil}
      end)

      {:ok, detector_pid: pid}
    end

    test "remains in active state when no anomalies", %{detector_pid: pid} do
      MetricStore.add_sample(:test_metric_store, @skill_beam, :process_utilization_pct, 52.0)

      send(pid, :collect)
      _ = :sys.get_state(pid)

      assert :active = Detector.get_state(:test_detector_anomaly)
    end

    test "enters cooldown when consecutive anomalies detected", %{detector_pid: pid} do
      anomaly_value = 100.0

      MetricStore.add_sample(
        :test_metric_store,
        @skill_beam,
        :process_utilization_pct,
        anomaly_value
      )

      send(pid, :collect)
      _ = :sys.get_state(pid)

      assert :active = Detector.get_state(:test_detector_anomaly)

      MetricStore.add_sample(
        :test_metric_store,
        @skill_beam,
        :process_utilization_pct,
        anomaly_value
      )

      send(pid, :collect)
      _ = :sys.get_state(pid)

      assert :cooldown = Detector.get_state(:test_detector_anomaly)
    end
  end

  describe "cooldown phase" do
    test "transitions back to active after cooldown" do
      BaselineStore.update_baseline(
        :test_baseline_store,
        @skill_beam,
        :process_utilization_pct,
        [45.0, 47.0, 50.0, 53.0, 55.0]
      )

      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_cooldown,
             metric_store: :test_metric_store,
             baseline_store: :test_baseline_store,
             collection_interval_ms: 60_000,
             learning_duration_ms: 100,
             cooldown_ms: 100,
             skills: [@skill_beam]
           ]}
        )

      past_time = System.system_time(:millisecond) - 200

      :sys.replace_state(pid, fn state ->
        %{state | state: :cooldown, cooldown_start_time: past_time}
      end)

      send(pid, :collect)
      _ = :sys.get_state(pid)

      assert :active = Detector.get_state(:test_detector_cooldown)
    end
  end
end
