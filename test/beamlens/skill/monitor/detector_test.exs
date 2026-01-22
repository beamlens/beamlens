defmodule Beamlens.Skill.Monitor.DetectorTest do
  use ExUnit.Case, async: false

  alias Beamlens.Skill.Monitor.BaselineStore
  alias Beamlens.Skill.Monitor.Detector
  alias Beamlens.Skill.Monitor.MetricStore

  @skill_beam Beamlens.Skill.Beam

  defmodule TestSkill do
    @moduledoc false
    @behaviour Beamlens.Skill
    def title, do: "Test Skill"
    def description, do: "Test skill"
    def system_prompt, do: ""
    def snapshot, do: %{metric_a: 50.0, metric_b: 100.0}
    def callbacks, do: %{}
    def callback_docs, do: ""
  end

  defmodule TestSkill2 do
    @moduledoc false
    @behaviour Beamlens.Skill
    def title, do: "Test Skill 2"
    def description, do: "Second test skill"
    def system_prompt, do: ""
    def snapshot, do: %{metric_x: 25.0, metric_y: 75.0, metric_z: 150.0}
    def callbacks, do: %{}
    def callback_docs, do: ""
  end

  defmodule TestSkillControllable do
    @moduledoc false
    @behaviour Beamlens.Skill
    def title, do: "Controllable"
    def description, do: "Controllable test skill"
    def system_prompt, do: ""
    def snapshot, do: Agent.get(__MODULE__, & &1)
    def callbacks, do: %{}
    def callback_docs, do: ""
  end

  defmodule TestSkillControllableReset do
    @moduledoc false
    @behaviour Beamlens.Skill
    def title, do: "Controllable Reset"
    def description, do: "Controllable test skill for reset test"
    def system_prompt, do: ""
    def snapshot, do: Agent.get(__MODULE__, & &1)
    def callbacks, do: %{}
    def callback_docs, do: ""
  end

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
      assert status.auto_trigger == false
      assert status.triggers_in_last_hour == 0
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

  describe "multi-skill collection" do
    test "collects metrics from multiple skills" do
      start_supervised!(
        {MetricStore,
         [
           name: :test_metric_store_multi,
           sample_interval_ms: 1000,
           history_minutes: 1
         ]},
        id: :metric_multi
      )

      start_supervised!(
        {BaselineStore,
         [
           name: :test_baseline_store_multi,
           ets_table: :test_baselines_multi,
           dets_file: nil
         ]},
        id: :baseline_multi
      )

      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_multi_collect,
             metric_store: :test_metric_store_multi,
             baseline_store: :test_baseline_store_multi,
             collection_interval_ms: 60_000,
             learning_duration_ms: 1000,
             skills: [TestSkill, TestSkill2]
           ]},
          id: :detector_multi_collect
        )

      send(pid, :collect)
      _ = :sys.get_state(pid)

      assert MetricStore.get_latest(:test_metric_store_multi, TestSkill, :metric_a) != nil
      assert MetricStore.get_latest(:test_metric_store_multi, TestSkill, :metric_b) != nil
      assert MetricStore.get_latest(:test_metric_store_multi, TestSkill2, :metric_x) != nil
      assert MetricStore.get_latest(:test_metric_store_multi, TestSkill2, :metric_y) != nil
      assert MetricStore.get_latest(:test_metric_store_multi, TestSkill2, :metric_z) != nil
    end

    test "collects all metrics from skill snapshots" do
      start_supervised!(
        {MetricStore,
         [
           name: :test_metric_store_snapshot,
           sample_interval_ms: 1000,
           history_minutes: 1
         ]},
        id: :metric_snapshot
      )

      start_supervised!(
        {BaselineStore,
         [
           name: :test_baseline_store_snapshot,
           ets_table: :test_baselines_snapshot,
           dets_file: nil
         ]},
        id: :baseline_snapshot
      )

      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_snapshot,
             metric_store: :test_metric_store_snapshot,
             baseline_store: :test_baseline_store_snapshot,
             collection_interval_ms: 60_000,
             learning_duration_ms: 1000,
             skills: [TestSkill]
           ]},
          id: :detector_snapshot
        )

      send(pid, :collect)
      _ = :sys.get_state(pid)

      sample_a = MetricStore.get_latest(:test_metric_store_snapshot, TestSkill, :metric_a)
      sample_b = MetricStore.get_latest(:test_metric_store_snapshot, TestSkill, :metric_b)

      assert sample_a.value == 50.0
      assert sample_b.value == 100.0
    end
  end

  describe "multi-skill baseline learning" do
    test "calculates baselines for all skill metrics after learning" do
      start_supervised!(
        {MetricStore,
         [
           name: :test_metric_store_baseline_multi,
           sample_interval_ms: 1000,
           history_minutes: 1
         ]},
        id: :metric_baseline_multi
      )

      start_supervised!(
        {BaselineStore,
         [
           name: :test_baseline_store_baseline_multi,
           ets_table: :test_baselines_baseline_multi,
           dets_file: nil
         ]},
        id: :baseline_baseline_multi
      )

      for i <- 1..5 do
        MetricStore.add_sample(:test_metric_store_baseline_multi, TestSkill, :metric_a, 50.0 + i)
        MetricStore.add_sample(:test_metric_store_baseline_multi, TestSkill, :metric_b, 100.0 + i)
        MetricStore.add_sample(:test_metric_store_baseline_multi, TestSkill2, :metric_x, 25.0 + i)
        MetricStore.add_sample(:test_metric_store_baseline_multi, TestSkill2, :metric_y, 75.0 + i)

        MetricStore.add_sample(
          :test_metric_store_baseline_multi,
          TestSkill2,
          :metric_z,
          150.0 + i
        )
      end

      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_baseline_multi,
             metric_store: :test_metric_store_baseline_multi,
             baseline_store: :test_baseline_store_baseline_multi,
             collection_interval_ms: 60_000,
             learning_duration_ms: 100,
             skills: [TestSkill, TestSkill2]
           ]},
          id: :detector_baseline_multi
        )

      past_time = System.system_time(:millisecond) - 200

      :sys.replace_state(pid, fn state ->
        %{state | learning_start_time: past_time}
      end)

      send(pid, :collect)
      _ = :sys.get_state(pid)

      baseline_a =
        BaselineStore.get_baseline(:test_baseline_store_baseline_multi, TestSkill, :metric_a)

      baseline_b =
        BaselineStore.get_baseline(:test_baseline_store_baseline_multi, TestSkill, :metric_b)

      baseline_x =
        BaselineStore.get_baseline(:test_baseline_store_baseline_multi, TestSkill2, :metric_x)

      baseline_y =
        BaselineStore.get_baseline(:test_baseline_store_baseline_multi, TestSkill2, :metric_y)

      baseline_z =
        BaselineStore.get_baseline(:test_baseline_store_baseline_multi, TestSkill2, :metric_z)

      assert baseline_a != nil
      assert baseline_a.sample_count > 0
      assert baseline_b != nil
      assert baseline_b.sample_count > 0
      assert baseline_x != nil
      assert baseline_x.sample_count > 0
      assert baseline_y != nil
      assert baseline_y.sample_count > 0
      assert baseline_z != nil
      assert baseline_z.sample_count > 0
    end
  end

  describe "anomaly detection with mock skills" do
    test "detects anomaly only for changed metric" do
      start_supervised!(
        {MetricStore,
         [
           name: :test_metric_store_anomaly_mock,
           sample_interval_ms: 1000,
           history_minutes: 1
         ]},
        id: :metric_anomaly_mock
      )

      start_supervised!(
        {BaselineStore,
         [
           name: :test_baseline_store_anomaly_mock,
           ets_table: :test_baselines_anomaly_mock,
           dets_file: nil
         ]},
        id: :baseline_anomaly_mock
      )

      start_supervised!(%{
        id: TestSkillControllable,
        start:
          {Agent, :start_link,
           [fn -> %{controlled_metric: 50.0} end, [name: TestSkillControllable]]}
      })

      BaselineStore.update_baseline(
        :test_baseline_store_anomaly_mock,
        TestSkillControllable,
        :controlled_metric,
        [45.0, 47.0, 50.0, 53.0, 55.0]
      )

      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_anomaly_mock,
             metric_store: :test_metric_store_anomaly_mock,
             baseline_store: :test_baseline_store_anomaly_mock,
             collection_interval_ms: 60_000,
             learning_duration_ms: 100,
             z_threshold: 2.0,
             consecutive_required: 2,
             cooldown_ms: 200,
             skills: [TestSkillControllable]
           ]},
          id: :detector_anomaly_mock
        )

      :sys.replace_state(pid, fn state ->
        %{state | state: :active, learning_start_time: nil}
      end)

      Agent.update(TestSkillControllable, fn _ -> %{controlled_metric: 200.0} end)

      send(pid, :collect)
      state = :sys.get_state(pid)

      assert state.consecutive_count == 1

      send(pid, :collect)
      _ = :sys.get_state(pid)

      assert :cooldown = Detector.get_state(:test_detector_anomaly_mock)
    end

    test "normal values reset consecutive count" do
      start_supervised!(
        {MetricStore,
         [
           name: :test_metric_store_reset,
           sample_interval_ms: 1000,
           history_minutes: 1
         ]},
        id: :metric_reset
      )

      start_supervised!(
        {BaselineStore,
         [
           name: :test_baseline_store_reset,
           ets_table: :test_baselines_reset,
           dets_file: nil
         ]},
        id: :baseline_reset
      )

      start_supervised!(%{
        id: TestSkillControllableReset,
        start:
          {Agent, :start_link,
           [fn -> %{controlled_metric: 50.0} end, [name: TestSkillControllableReset]]}
      })

      BaselineStore.update_baseline(
        :test_baseline_store_reset,
        TestSkillControllableReset,
        :controlled_metric,
        [45.0, 47.0, 50.0, 53.0, 55.0]
      )

      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_reset,
             metric_store: :test_metric_store_reset,
             baseline_store: :test_baseline_store_reset,
             collection_interval_ms: 60_000,
             learning_duration_ms: 100,
             z_threshold: 2.0,
             consecutive_required: 3,
             cooldown_ms: 200,
             skills: [TestSkillControllableReset]
           ]},
          id: :detector_reset
        )

      :sys.replace_state(pid, fn state ->
        %{state | state: :active, learning_start_time: nil}
      end)

      Agent.update(TestSkillControllableReset, fn _ -> %{controlled_metric: 200.0} end)

      send(pid, :collect)
      state = :sys.get_state(pid)

      assert state.consecutive_count == 1

      Agent.update(TestSkillControllableReset, fn _ -> %{controlled_metric: 50.0} end)

      send(pid, :collect)
      state = :sys.get_state(pid)

      assert state.consecutive_count == 0
      assert :active = Detector.get_state(:test_detector_reset)
    end
  end

  defmodule TestSkillAutoTrigger do
    @moduledoc false
    @behaviour Beamlens.Skill
    def title, do: "Auto Trigger Skill"
    def description, do: "Controllable skill for auto-trigger tests"
    def system_prompt, do: ""
    def snapshot, do: Agent.get(__MODULE__, & &1)
    def callbacks, do: %{}
    def callback_docs, do: ""
  end

  describe "auto-trigger" do
    import ExUnit.CaptureLog

    setup do
      start_supervised!(
        {MetricStore,
         [
           name: :test_metric_store_auto,
           sample_interval_ms: 1000,
           history_minutes: 1
         ]},
        id: :metric_auto
      )

      start_supervised!(
        {BaselineStore,
         [
           name: :test_baseline_store_auto,
           ets_table: :test_baselines_auto,
           dets_file: nil
         ]},
        id: :baseline_auto
      )

      start_supervised!(%{
        id: TestSkillAutoTrigger,
        start:
          {Agent, :start_link,
           [fn -> %{controlled_metric: 50.0} end, [name: TestSkillAutoTrigger]]}
      })

      BaselineStore.update_baseline(
        :test_baseline_store_auto,
        TestSkillAutoTrigger,
        :controlled_metric,
        [45.0, 47.0, 50.0, 53.0, 55.0]
      )

      :ok
    end

    test "does not trigger when auto_trigger is false (default)" do
      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_auto_off,
             metric_store: :test_metric_store_auto,
             baseline_store: :test_baseline_store_auto,
             collection_interval_ms: 60_000,
             learning_duration_ms: 100,
             z_threshold: 2.0,
             consecutive_required: 2,
             cooldown_ms: 200,
             skills: [TestSkillAutoTrigger]
           ]},
          id: :detector_auto_off
        )

      :sys.replace_state(pid, fn state ->
        %{state | state: :active, learning_start_time: nil}
      end)

      Agent.update(TestSkillAutoTrigger, fn _ -> %{controlled_metric: 200.0} end)

      send(pid, :collect)
      _ = :sys.get_state(pid)

      send(pid, :collect)
      state = :sys.get_state(pid)

      assert state.trigger_history == []
      assert state.auto_trigger == false
    end

    test "triggers Coordinator when enabled and under rate limit" do
      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_auto_on,
             metric_store: :test_metric_store_auto,
             baseline_store: :test_baseline_store_auto,
             collection_interval_ms: 60_000,
             learning_duration_ms: 100,
             z_threshold: 2.0,
             consecutive_required: 2,
             cooldown_ms: 200,
             auto_trigger: true,
             max_triggers_per_hour: 3,
             skills: [TestSkillAutoTrigger]
           ]},
          id: :detector_auto_on
        )

      :sys.replace_state(pid, fn state ->
        %{state | state: :active, learning_start_time: nil}
      end)

      Agent.update(TestSkillAutoTrigger, fn _ -> %{controlled_metric: 200.0} end)

      send(pid, :collect)
      _ = :sys.get_state(pid)

      send(pid, :collect)
      state = :sys.get_state(pid)

      assert length(state.trigger_history) == 1
      assert state.auto_trigger == true
    end

    test "logs warning when rate-limited" do
      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_rate_limit,
             metric_store: :test_metric_store_auto,
             baseline_store: :test_baseline_store_auto,
             collection_interval_ms: 60_000,
             learning_duration_ms: 100,
             z_threshold: 2.0,
             consecutive_required: 2,
             cooldown_ms: 100,
             auto_trigger: true,
             max_triggers_per_hour: 2,
             skills: [TestSkillAutoTrigger]
           ]},
          id: :detector_rate_limit
        )

      now = System.system_time(:millisecond)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | state: :active,
            learning_start_time: nil,
            trigger_history: [now - 1000, now - 2000]
        }
      end)

      Agent.update(TestSkillAutoTrigger, fn _ -> %{controlled_metric: 200.0} end)

      send(pid, :collect)
      _ = :sys.get_state(pid)

      log =
        capture_log(fn ->
          send(pid, :collect)
          _ = :sys.get_state(pid)
        end)

      assert log =~ "rate-limited"

      state = :sys.get_state(pid)
      assert length(state.trigger_history) == 2
    end

    test "prunes old entries from trigger_history" do
      pid =
        start_supervised!(
          {Detector,
           [
             name: :test_detector_prune,
             metric_store: :test_metric_store_auto,
             baseline_store: :test_baseline_store_auto,
             collection_interval_ms: 60_000,
             learning_duration_ms: 100,
             z_threshold: 2.0,
             consecutive_required: 2,
             cooldown_ms: 200,
             auto_trigger: true,
             max_triggers_per_hour: 3,
             skills: [TestSkillAutoTrigger]
           ]},
          id: :detector_prune
        )

      now = System.system_time(:millisecond)
      one_hour_ms = :timer.hours(1)
      old_timestamp = now - one_hour_ms - 1000

      :sys.replace_state(pid, fn state ->
        %{
          state
          | state: :active,
            learning_start_time: nil,
            trigger_history: [old_timestamp]
        }
      end)

      Agent.update(TestSkillAutoTrigger, fn _ -> %{controlled_metric: 200.0} end)

      send(pid, :collect)
      _ = :sys.get_state(pid)

      send(pid, :collect)
      state = :sys.get_state(pid)

      assert length(state.trigger_history) == 1
      refute old_timestamp in state.trigger_history
    end
  end
end
