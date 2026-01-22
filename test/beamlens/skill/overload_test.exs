defmodule Beamlens.Skill.OverloadTest do
  use ExUnit.Case

  alias Beamlens.Skill.Overload

  describe "title/0" do
    test "returns title" do
      assert Overload.title() == "Overload Detection"
    end
  end

  describe "description/0" do
    test "returns description" do
      assert Overload.description() =~ "overload"
    end
  end

  describe "system_prompt/0" do
    test "returns system prompt" do
      prompt = Overload.system_prompt()
      assert prompt =~ "overload"
      assert prompt =~ "message queue"
      assert prompt =~ "bottleneck"
    end
  end

  describe "snapshot/0" do
    test "returns snapshot with expected fields" do
      snapshot = Overload.snapshot()

      assert Map.has_key?(snapshot, :overload_severity)
      assert Map.has_key?(snapshot, :overload_type)
      assert Map.has_key?(snapshot, :bottleneck_location)
      assert Map.has_key?(snapshot, :affected_processes)
      assert Map.has_key?(snapshot, :total_queue_depth)
      assert Map.has_key?(snapshot, :recommended_action)
      assert Map.has_key?(snapshot, :time_to_crash_estimate_seconds)

      assert snapshot.overload_severity in [:none, :transient, :sustained, :critical]
    end
  end

  describe "callbacks/0" do
    test "returns expected callbacks" do
      callbacks = Overload.callbacks()

      assert Map.has_key?(callbacks, "overload_state")
      assert Map.has_key?(callbacks, "overload_queue_analysis")
      assert Map.has_key?(callbacks, "overload_bottleneck")
      assert Map.has_key?(callbacks, "overload_cascade_detection")
      assert Map.has_key?(callbacks, "overload_remediation_plan")

      assert is_function(callbacks["overload_state"], 0)
      assert is_function(callbacks["overload_queue_analysis"], 0)
      assert is_function(callbacks["overload_bottleneck"], 0)
      assert is_function(callbacks["overload_cascade_detection"], 0)
      assert is_function(callbacks["overload_remediation_plan"], 0)
    end
  end

  describe "callback_docs/0" do
    test "returns callback documentation" do
      docs = Overload.callback_docs()

      assert docs =~ "overload_state"
      assert docs =~ "overload_queue_analysis"
      assert docs =~ "overload_bottleneck"
      assert docs =~ "overload_cascade_detection"
      assert docs =~ "overload_remediation_plan"
    end
  end

  describe "overload_state/0" do
    test "returns overload state map" do
      state = Overload.overload_state_wrapper()

      assert Map.has_key?(state, :severity)
      assert Map.has_key?(state, :type)
      assert Map.has_key?(state, :bottleneck_location)
      assert Map.has_key?(state, :affected_processes)
      assert Map.has_key?(state, :total_queue_depth)
      assert Map.has_key?(state, :recommended_action)
      assert Map.has_key?(state, :time_to_crash_estimate_seconds)

      assert state.severity in [:none, :transient, :sustained, :critical]
      assert is_integer(state.affected_processes)
      assert is_integer(state.total_queue_depth)
      assert state.total_queue_depth >= 0
    end
  end

  describe "queue_analysis/0" do
    test "returns queue analysis map" do
      analysis = Overload.queue_analysis_wrapper()

      assert Map.has_key?(analysis, :total_queued_messages)
      assert Map.has_key?(analysis, :processes_with_queues)
      assert Map.has_key?(analysis, :queue_percentiles)
      assert Map.has_key?(analysis, :fastest_growing_queues)
      assert Map.has_key?(analysis, :overload_classification)

      assert is_integer(analysis.total_queued_messages)
      assert analysis.total_queued_messages >= 0
      assert is_integer(analysis.processes_with_queues)
      assert analysis.processes_with_queues >= 0

      assert Map.has_key?(analysis.queue_percentiles, :p50)
      assert Map.has_key?(analysis.queue_percentiles, :p90)
      assert Map.has_key?(analysis.queue_percentiles, :p95)
      assert Map.has_key?(analysis.queue_percentiles, :p99)
      assert Map.has_key?(analysis.queue_percentiles, :p100)

      assert is_list(analysis.fastest_growing_queues)
    end
  end

  describe "find_bottleneck/0" do
    test "returns bottleneck analysis" do
      bottleneck = Overload.bottleneck_wrapper()

      assert Map.has_key?(bottleneck, :bottleneck_type)
      assert Map.has_key?(bottleneck, :bottleneck_location)
      assert Map.has_key?(bottleneck, :evidence)
      assert Map.has_key?(bottleneck, :confidence_level)

      assert bottleneck.bottleneck_type in [
               :downstream_blocking,
               :cpu_bound,
               :contention,
               :unknown
             ]

      assert is_binary(bottleneck.bottleneck_location)
      assert bottleneck.confidence_level in [:low, :medium, :high]
      assert is_list(bottleneck.evidence)
    end
  end

  describe "cascade_detection/0" do
    test "returns cascade detection results" do
      cascade = Overload.cascade_detection_wrapper()

      assert Map.has_key?(cascade, :cascading)
      assert Map.has_key?(cascade, :affected_subsystems)
      assert Map.has_key?(cascade, :failure_relationships)
      assert Map.has_key?(cascade, :severity)

      assert is_boolean(cascade.cascading)
      assert is_list(cascade.affected_subsystems)
      assert is_list(cascade.failure_relationships)
      assert cascade.severity in [:none, :warning, :critical]
    end
  end

  describe "remediation_plan/0" do
    test "returns remediation plan" do
      plan = Overload.remediation_plan_wrapper()

      assert Map.has_key?(plan, :overload_severity)
      assert Map.has_key?(plan, :recommended_action)
      assert Map.has_key?(plan, :action_description)
      assert Map.has_key?(plan, :priority)
      assert Map.has_key?(plan, :estimated_impact)
      assert Map.has_key?(plan, :implementation_steps)

      assert plan.overload_severity in [:none, :transient, :sustained, :critical]
      assert is_atom(plan.recommended_action) or is_binary(plan.recommended_action)
      assert is_binary(plan.action_description)
      assert plan.priority in [:low, :medium, :high, :critical]
      assert is_binary(plan.estimated_impact)
      assert is_list(plan.implementation_steps)
    end
  end

  describe "helper functions" do
    test "majority_bottleneck? returns correct result" do
      types = [:downstream_blocking, :downstream_blocking, :cpu_bound]
      refute Overload.majority_bottleneck?(types, 3, :cpu_bound)
      assert Overload.majority_bottleneck?(types, 3, :downstream_blocking)
    end

    test "significant_bottleneck? returns correct result" do
      types = [:contention, :contention, :downstream_blocking]
      assert Overload.significant_bottleneck?(types, 3, :contention, 3)
      refute Overload.significant_bottleneck?(types, 3, :cpu_bound, 3)
    end
  end

  describe "integration tests" do
    test "all callbacks return valid data" do
      callbacks = Overload.callbacks()

      Enum.each(callbacks, fn {name, func} ->
        result = func.()
        assert is_map(result), "Callback #{name} should return a map"
      end)
    end

    test "overload severity affects remediation priority" do
      state = Overload.overload_state_wrapper()
      plan = Overload.remediation_plan_wrapper()

      if state.severity == :critical do
        assert plan.priority in [:high, :critical]
      end
    end
  end
end
