defmodule Beamlens.Integration.OperatorTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.Operator

  defmodule TestSkill do
    @behaviour Beamlens.Skill

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

      {:ok, pid} = start_operator(context, skill: TestSkill)

      refute_receive {:telemetry, :iteration_start, _}, 500

      Task.async(fn -> Operator.await(pid) end)

      assert_receive {:telemetry, :iteration_start, %{operator: TestSkill, iteration: 0}},
                     10_000
    end

    @tag timeout: 60_000
    test "run/2 returns notifications when analysis completes", context do
      {:ok, _pid} = start_operator(context, skill: TestSkill)

      {:ok, notifications} = Operator.run(TestSkill, %{}, timeout: 60_000)

      assert is_list(notifications)
    end
  end
end
