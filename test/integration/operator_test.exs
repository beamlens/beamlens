defmodule Beamlens.Integration.OperatorTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.Operator

  defmodule TestSkill do
    @behaviour Beamlens.Skill

    def id, do: :integration_test

    def title, do: "Integration Test"

    def description, do: "Test skill for integration tests"

    def system_prompt, do: "You are a test skill for integration tests."

    def snapshot do
      %{
        memory_utilization_pct: 45.0,
        process_utilization_pct: 10.0,
        port_utilization_pct: 5.0,
        atom_utilization_pct: 2.0,
        scheduler_run_queue: 0,
        schedulers_online: 8
      }
    end

    def callbacks do
      %{
        "get_memory" => fn -> %{total_mb: 100, used_mb: 45} end,
        "get_test_value" => fn -> 42 end
      }
    end

    def callback_docs do
      """
      ### get_memory()
      Returns memory stats: total_mb, used_mb

      ### get_test_value()
      Returns 42
      """
    end
  end

  describe "continuous mode" do
    @tag timeout: 30_000
    test "auto-starts loop and emits iteration events", context do
      ref = make_ref()
      parent = self()
      on_exit(fn -> :telemetry.detach(ref) end)

      :telemetry.attach(
        ref,
        [:beamlens, :operator, :iteration_start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :iteration_start, metadata})
        end,
        nil
      )

      {:ok, _pid} = start_operator(context, skill: TestSkill, mode: :continuous)

      assert_receive {:telemetry, :iteration_start, %{operator: :integration_test, iteration: 0}},
                     10_000
    end

    @tag timeout: 60_000
    test "emits llm events during loop", context do
      ref = make_ref()
      parent = self()
      on_exit(fn -> :telemetry.detach(ref) end)

      :telemetry.attach(
        ref,
        [:beamlens, :llm, :start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :llm_start, metadata})
        end,
        nil
      )

      {:ok, _pid} = start_operator(context, skill: TestSkill, mode: :continuous)

      assert_receive {:telemetry, :llm_start, %{trace_id: trace_id}}, 15_000
      assert is_binary(trace_id)
    end

    @tag timeout: 60_000
    test "takes snapshot on first iteration per BAML prompt instructions", context do
      ref = make_ref()
      parent = self()
      on_exit(fn -> :telemetry.detach(ref) end)

      :telemetry.attach(
        ref,
        [:beamlens, :operator, :take_snapshot],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :take_snapshot, metadata})
        end,
        nil
      )

      {:ok, _pid} = start_operator(context, skill: TestSkill, mode: :continuous)

      assert_receive {:telemetry, :take_snapshot,
                      %{operator: :integration_test, snapshot_id: snapshot_id}},
                     30_000

      assert is_binary(snapshot_id)
      assert String.length(snapshot_id) == 16
    end

    @tag timeout: 30_000
    test "increments iteration counter across multiple iterations", context do
      ref = make_ref()
      parent = self()
      on_exit(fn -> :telemetry.detach(ref) end)

      :telemetry.attach(
        ref,
        [:beamlens, :operator, :iteration_start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :iteration_start, metadata})
        end,
        nil
      )

      {:ok, _pid} = start_operator(context, skill: TestSkill, mode: :continuous)

      iterations_received =
        Enum.reduce_while(1..3, [], fn _, acc ->
          receive do
            {:telemetry, :iteration_start, %{iteration: iteration}} ->
              {:cont, acc ++ [iteration]}
          after
            10_000 ->
              {:halt, acc}
          end
        end)

      assert length(iterations_received) >= 2,
             "Expected at least 2 iterations, got #{length(iterations_received)}"

      sorted = Enum.sort(iterations_received)
      assert sorted == iterations_received, "Iterations should be in ascending order"
    end

    @tag timeout: 20_000
    test "maintains state across iterations", context do
      ref = make_ref()
      parent = self()
      on_exit(fn -> :telemetry.detach(ref) end)

      :telemetry.attach(
        ref,
        [:beamlens, :operator, :iteration_start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :iteration_start, metadata})
        end,
        nil
      )

      {:ok, _pid} = start_operator(context, skill: TestSkill, mode: :continuous)

      assert_receive {:telemetry, :iteration_start, %{iteration: 0}}, 10_000
      assert_receive {:telemetry, :iteration_start, %{iteration: iteration}}, 10_000
      assert iteration > 0
    end
  end

  describe "on-demand mode" do
    @tag timeout: 30_000
    test "loop does not start until await is called", context do
      ref = make_ref()
      parent = self()
      on_exit(fn -> :telemetry.detach(ref) end)

      :telemetry.attach(
        ref,
        [:beamlens, :operator, :iteration_start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :iteration_start, metadata})
        end,
        nil
      )

      {:ok, pid} = start_operator(context, skill: TestSkill, mode: :on_demand)

      refute_receive {:telemetry, :iteration_start, _}, 500

      Task.async(fn -> Operator.await(pid) end)

      assert_receive {:telemetry, :iteration_start, %{operator: :integration_test, iteration: 0}},
                     10_000
    end

    @tag timeout: 60_000
    test "run/3 returns notifications when analysis completes", context do
      {:ok, notifications} = Operator.run(TestSkill, context.client_registry)

      assert is_list(notifications)
    end
  end
end
