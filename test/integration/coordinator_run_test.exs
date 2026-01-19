defmodule Beamlens.Integration.CoordinatorRunTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Operator.Notification

  defp build_test_notification(overrides \\ %{}) do
    Notification.new(
      Map.merge(
        %{
          operator: :test,
          anomaly_type: "test_anomaly",
          severity: :info,
          summary: "Test notification",
          snapshots: []
        },
        overrides
      )
    )
  end

  describe "run/2 - basic execution" do
    @tag timeout: 60_000
    test "spawns coordinator and blocks until completion", context do
      {:ok, result} =
        Coordinator.run(%{reason: "test"},
          client_registry: context.client_registry,
          timeout: 30_000
        )

      assert is_map(result)
      assert Map.has_key?(result, :insights)
      assert Map.has_key?(result, :operator_results)
    end

    @tag timeout: 60_000
    test "returns correct result structure", context do
      {:ok, result} =
        Coordinator.run(%{reason: "test"},
          client_registry: context.client_registry,
          timeout: 30_000
        )

      assert is_list(result.insights)
      assert is_list(result.operator_results)
    end
  end

  describe "run/2 - context handling" do
    @tag timeout: 60_000
    test "passes context map to coordinator", context do
      {:ok, result} =
        Coordinator.run(%{reason: "memory alert"},
          client_registry: context.client_registry,
          timeout: 30_000
        )

      assert is_map(result)
    end

    @tag timeout: 60_000
    test "handles empty context map", context do
      {:ok, result} =
        Coordinator.run(%{}, client_registry: context.client_registry, timeout: 30_000)

      assert is_map(result)
      assert is_list(result.insights)
    end

    @tag timeout: 60_000
    test "run/1 with keyword list extracts context option", context do
      {:ok, result} =
        Coordinator.run(
          context: %{reason: "test"},
          client_registry: context.client_registry,
          timeout: 30_000
        )

      assert is_map(result)
    end
  end

  describe "run/2 - options handling" do
    @tag timeout: 60_000
    test "accepts notifications option", context do
      notification = build_test_notification()

      {:ok, result} =
        Coordinator.run(%{},
          notifications: [notification],
          client_registry: context.client_registry,
          timeout: 30_000
        )

      assert is_map(result)
    end

    @tag timeout: 60_000
    test "accepts skills option", context do
      {:ok, result} =
        Coordinator.run(%{},
          skills: [Beamlens.Skill.Beam],
          client_registry: context.client_registry,
          timeout: 30_000
        )

      assert is_map(result)
    end

    @tag timeout: 60_000
    test "accepts max_iterations option", context do
      {:ok, result} =
        Coordinator.run(%{},
          max_iterations: 5,
          client_registry: context.client_registry,
          timeout: 30_000
        )

      assert is_map(result)
    end

    @tag timeout: 60_000
    test "accepts compaction options", context do
      {:ok, result} =
        Coordinator.run(%{},
          compaction_max_tokens: 10_000,
          compaction_keep_last: 3,
          client_registry: context.client_registry,
          timeout: 30_000
        )

      assert is_map(result)
    end
  end

  describe "run/2 - timeout behavior" do
    @tag timeout: 60_000
    test "completes within default timeout", context do
      {:ok, result} =
        Coordinator.run(%{reason: "test"}, client_registry: context.client_registry)

      assert is_map(result)
    end
  end

  describe "run/2 - process cleanup" do
    @tag timeout: 60_000
    test "coordinator process stops after completion", context do
      {:ok, _result} =
        Coordinator.run(%{}, client_registry: context.client_registry, timeout: 30_000)

      refute Enum.any?(Process.list(), &coordinator_process?/1)
    end
  end

  describe "run/2 - timeout edge cases" do
    @tag timeout: 60_000
    test "exits with timeout when LLM response exceeds limit", context do
      Process.flag(:trap_exit, true)

      pid =
        spawn_link(fn ->
          Coordinator.run(%{},
            client_registry: context.client_registry,
            timeout: 50
          )
        end)

      assert_receive {:EXIT, ^pid, {:timeout, _}}, 5_000
    end

    @tag timeout: 60_000
    test "coordinator process stops even when timeout occurs", context do
      Process.flag(:trap_exit, true)
      coordinators_before = count_coordinator_processes()

      pid =
        spawn_link(fn ->
          Coordinator.run(%{},
            client_registry: context.client_registry,
            timeout: 50
          )
        end)

      assert_receive {:EXIT, ^pid, {:timeout, _}}, 5_000

      coordinators_after = count_coordinator_processes()
      assert coordinators_before == coordinators_after
    end
  end

  defp count_coordinator_processes do
    Enum.count(Process.list(), &coordinator_process?/1)
  end

  defp coordinator_process?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> has_coordinator_initial_call?(dict)
      nil -> false
    end
  end

  defp has_coordinator_initial_call?(dict) do
    Enum.any?(dict, fn
      {:"$initial_call", {Beamlens.Coordinator, :init, 1}} -> true
      _ -> false
    end)
  end
end
