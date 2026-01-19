defmodule Beamlens.Integration.OperatorRunTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.Operator

  defmodule TestSkill do
    @behaviour Beamlens.Skill

    def title, do: "Run Test"

    def description, do: "Test skill for Operator.run/2 integration tests"

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
        "get_test_value" => fn -> 42 end
      }
    end

    def callback_docs do
      """
      ### get_test_value()
      Returns 42
      """
    end
  end

  describe "run/2 skill resolution" do
    @tag timeout: 60_000
    test "accepts valid skill module", context do
      {:ok, notifications} =
        Operator.run(TestSkill, %{reason: "test"}, client_registry: context.client_registry)

      assert is_list(notifications)
    end
  end

  describe "run/2 context formatting" do
    @tag timeout: 60_000
    test "formats context with reason", context do
      {:ok, notifications} =
        Operator.run(TestSkill, %{reason: "memory alert"},
          client_registry: context.client_registry
        )

      assert is_list(notifications)
    end

    @tag timeout: 60_000
    test "handles empty context map", context do
      {:ok, notifications} =
        Operator.run(TestSkill, %{}, client_registry: context.client_registry)

      assert is_list(notifications)
    end

    @tag timeout: 60_000
    test "handles context with non-string values", context do
      {:ok, notifications} =
        Operator.run(TestSkill, %{count: 42, enabled: true},
          client_registry: context.client_registry
        )

      assert is_list(notifications)
    end
  end

  describe "run/2 options handling" do
    @tag timeout: 60_000
    test "accepts timeout option", context do
      {:ok, notifications} =
        Operator.run(TestSkill, %{}, client_registry: context.client_registry, timeout: 30_000)

      assert is_list(notifications)
    end

    @tag timeout: 60_000
    test "accepts max_iterations option", context do
      {:ok, notifications} =
        Operator.run(TestSkill, %{}, client_registry: context.client_registry, max_iterations: 5)

      assert is_list(notifications)
    end

    @tag timeout: 60_000
    test "accepts compaction options", context do
      {:ok, notifications} =
        Operator.run(
          TestSkill,
          %{},
          client_registry: context.client_registry,
          compaction_max_tokens: 100_000,
          compaction_keep_last: 10
        )

      assert is_list(notifications)
    end
  end

  describe "run/2 timeout behavior" do
    @tag timeout: 60_000
    test "completes within default timeout", context do
      {:ok, notifications} =
        Operator.run(TestSkill, %{}, client_registry: context.client_registry)

      assert is_list(notifications)
    end
  end

  describe "run/2 return structure" do
    @tag timeout: 60_000
    test "returns list of notifications", context do
      {:ok, notifications} =
        Operator.run(TestSkill, %{}, client_registry: context.client_registry)

      assert is_list(notifications)
    end
  end

  describe "run/2 timeout edge cases" do
    @tag timeout: 60_000
    test "exits with timeout when LLM response exceeds limit", context do
      Process.flag(:trap_exit, true)

      pid =
        spawn_link(fn ->
          Operator.run(TestSkill, %{},
            client_registry: context.client_registry,
            timeout: 50
          )
        end)

      assert_receive {:EXIT, ^pid, {:timeout, _}}, 5_000
    end

    @tag timeout: 60_000
    test "stops operator process after timeout", context do
      Process.flag(:trap_exit, true)

      pid =
        spawn_link(fn ->
          Operator.run(TestSkill, %{},
            client_registry: context.client_registry,
            timeout: 1
          )
        end)

      assert_receive {:EXIT, ^pid, {:timeout, _}}, 5_000
    end
  end
end
