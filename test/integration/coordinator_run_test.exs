defmodule Beamlens.Integration.CoordinatorRunTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Operator.Notification

  defp run_opts(context, opts \\ [])

  defp run_opts(
         %{puck_client: %Puck.Client{} = puck_client, client_registry: client_registry},
         opts
       ) do
    opts
    |> Keyword.put(:client_registry, client_registry)
    |> Keyword.put_new(:puck_client, coordinator_puck_client(puck_client))
  end

  defp run_opts(%{client_registry: client_registry}, opts) do
    Keyword.put(opts, :client_registry, client_registry)
  end

  defp coordinator_puck_client(_puck_client) do
    Beamlens.Testing.mock_client(
      [%Beamlens.Coordinator.Tools.Done{intent: "done"}],
      default: %Beamlens.Coordinator.Tools.Done{intent: "done"}
    )
  end

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
        Coordinator.run(%{reason: "test"}, run_opts(context, timeout: 30_000))

      assert is_map(result)
      assert Map.has_key?(result, :insights)
      assert Map.has_key?(result, :operator_results)
    end

    @tag timeout: 60_000
    test "returns correct result structure", context do
      {:ok, result} =
        Coordinator.run(%{reason: "test"}, run_opts(context, timeout: 30_000))

      assert is_list(result.insights)
      assert is_list(result.operator_results)
    end
  end

  describe "run/2 - context handling" do
    @tag timeout: 60_000
    test "passes context map to coordinator", context do
      {:ok, result} =
        Coordinator.run(%{reason: "memory alert"}, run_opts(context, timeout: 30_000))

      assert is_map(result)
    end

    @tag timeout: 60_000
    test "handles empty context map", context do
      {:ok, result} = Coordinator.run(%{}, run_opts(context, timeout: 30_000))

      assert is_map(result)
      assert is_list(result.insights)
    end

    @tag timeout: 60_000
    test "run/1 with keyword list extracts context option", context do
      {:ok, result} =
        Coordinator.run(run_opts(context, context: %{reason: "test"}, timeout: 30_000))

      assert is_map(result)
    end
  end

  describe "run/2 - options handling" do
    @tag timeout: 60_000
    test "accepts notifications option", context do
      notification = build_test_notification()

      {:ok, result} =
        Coordinator.run(
          %{},
          run_opts(context, notifications: [notification], timeout: 30_000)
        )

      assert is_map(result)
    end

    @tag timeout: 60_000
    test "accepts skills option", context do
      {:ok, result} =
        Coordinator.run(%{}, run_opts(context, skills: [Beamlens.Skill.Beam], timeout: 30_000))

      assert is_map(result)
    end

    @tag timeout: 60_000
    test "accepts max_iterations option", context do
      {:ok, result} =
        Coordinator.run(%{}, run_opts(context, max_iterations: 5, timeout: 30_000))

      assert is_map(result)
    end

    @tag timeout: 60_000
    test "accepts compaction options", context do
      {:ok, result} =
        Coordinator.run(
          %{},
          run_opts(context,
            compaction_max_tokens: 10_000,
            compaction_keep_last: 3,
            timeout: 30_000
          )
        )

      assert is_map(result)
    end
  end

  describe "run/2 - timeout behavior" do
    @tag timeout: 60_000
    test "completes within default timeout", context do
      {:ok, result} = Coordinator.run(%{reason: "test"}, run_opts(context))

      assert is_map(result)
    end
  end

  describe "run/2 - process cleanup" do
    @tag timeout: 60_000
    test "coordinator process stops after completion", context do
      {:ok, _result} = Coordinator.run(%{}, run_opts(context, timeout: 30_000))

      refute Enum.any?(Process.list(), fn pid ->
               case Process.info(pid, :dictionary) do
                 {:dictionary, dict} ->
                   Enum.any?(dict, fn
                     {:"$initial_call", {Beamlens.Coordinator, :init, 1}} -> true
                     _ -> false
                   end)

                 nil ->
                   false
               end
             end)
    end
  end
end
