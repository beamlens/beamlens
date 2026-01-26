defmodule Beamlens.Evals.IntentDecompositionTest do
  @moduledoc """
  Eval tests for fact vs speculation decomposition.

  Uses Puck.Eval to capture tool trajectories and grade that operators
  and coordinators correctly separate facts from speculation.
  """

  use ExUnit.Case, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Coordinator.Tools.ProduceInsight
  alias Beamlens.IntegrationCase
  alias Beamlens.Operator
  alias Beamlens.Operator.Notification
  alias Beamlens.Operator.Tools.SendNotification
  alias Puck.Eval.Graders
  alias Puck.Eval.Graders.LLM

  @moduletag :eval

  setup do
    :persistent_term.put(
      {Beamlens.Supervisor, :skills},
      [Beamlens.Skill.Beam, Beamlens.Skill.Ets, Beamlens.Skill.Gc]
    )

    on_exit(fn ->
      :persistent_term.erase({Beamlens.Supervisor, :skills})
    end)

    case IntegrationCase.build_client_registry() do
      {:ok, registry} ->
        {:ok, client_registry: registry}

      {:error, reason} ->
        flunk(reason)
    end
  end

  defmodule DecompositionSkill do
    @behaviour Beamlens.Skill

    def title, do: "Decomposition Eval"

    def description, do: "Test skill for decomposition evals"

    def system_prompt do
      """
      You are a BEAM VM health monitor. Memory > 80% requires a notification.

      When sending notifications, decompose information:
      - context: Factual system state (no speculation)
      - observation: What anomaly you detected (factual)
      - hypothesis: What MIGHT be causing it (speculative, optional)
      """
    end

    def snapshot do
      %{
        memory_utilization_pct: 85.0,
        process_utilization_pct: 12.0,
        port_utilization_pct: 5.0,
        atom_utilization_pct: 2.0,
        scheduler_run_queue: 0,
        schedulers_online: 8
      }
    end

    def callbacks do
      %{
        "get_memory" => fn -> %{total_mb: 1000, used_mb: 850, ets_mb: 400} end
      }
    end

    def callback_docs do
      "### get_memory()\nReturns memory stats: total_mb, used_mb, ets_mb"
    end
  end

  describe "operator decomposition evals" do
    @tag timeout: 60_000
    test "operator produces notifications with context and observation", context do
      start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})

      {:ok, _pid} =
        start_supervised(
          {Operator,
           skill: DecompositionSkill,
           client_registry: context.client_registry,
           name: {:via, Registry, {Beamlens.OperatorRegistry, DecompositionSkill}}}
        )

      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, _notifications} =
              Operator.run(DecompositionSkill, %{reason: "memory check"},
                client_registry: context.client_registry,
                timeout: 60_000
              )

            :ok
          end,
          timeout: 100
        )

      result =
        Puck.Eval.grade(nil, trajectory, [
          Graders.output_produced(SendNotification),
          Graders.output_matches(fn step ->
            case Map.get(step, :output) do
              %SendNotification{context: ctx, observation: obs} ->
                is_binary(ctx) and is_binary(obs)

              _ ->
                true
            end
          end)
        ])

      assert result.passed?,
             "Eval failed: #{inspect(result.grader_results, pretty: true)}"
    end

    @tag timeout: 60_000
    test "context field contains factual information only", context do
      start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})

      {:ok, _pid} =
        start_supervised(
          {Operator,
           skill: DecompositionSkill,
           client_registry: context.client_registry,
           name: {:via, Registry, {Beamlens.OperatorRegistry, DecompositionSkill}}}
        )

      {output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, notifications} =
              Operator.run(DecompositionSkill, %{reason: "memory check"},
                client_registry: context.client_registry,
                timeout: 60_000
              )

            notifications
          end,
          timeout: 100
        )

      judge_client = build_judge_client()

      context_rubric = """
      - Context contains only factual, observable system state
      - Context does NOT contain speculation (likely, probably, might, could, possibly, appears to, suggests, seems)
      - Context describes what IS, not what MIGHT BE
      - Context contains concrete values or states, not interpretations
      """

      context_grader =
        LLM.rubric(judge_client, context_rubric)

      context_texts = Enum.map_join(output, "\n\n---\n\n", & &1.context)

      result =
        Puck.Eval.grade(context_texts, trajectory, [
          Graders.output_produced(SendNotification),
          context_grader
        ])

      assert result.passed?,
             "Eval failed: #{inspect(result.grader_results, pretty: true)}"
    end
  end

  describe "coordinator grounding evals" do
    @tag timeout: 180_000
    test "coordinator produces insights with grounding metadata", context do
      start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})

      start_supervised!(
        {Coordinator, name: Coordinator, client_registry: context.client_registry}
      )

      notifications = [
        build_notification(%{
          operator: Beamlens.Skill.Beam,
          context: "Production node",
          observation: "Memory at 85%",
          hypothesis: "ETS growth"
        })
      ]

      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, _result} =
              Coordinator.run(%{},
                notifications: notifications,
                client_registry: context.client_registry,
                max_iterations: 20,
                timeout: 150_000
              )

            :ok
          end,
          timeout: 300
        )

      result =
        Puck.Eval.grade(nil, trajectory, [
          Graders.output_produced(ProduceInsight),
          Graders.output_matches(fn step ->
            case Map.get(step, :output) do
              %ProduceInsight{matched_observations: obs, hypothesis_grounded: grounded} ->
                is_list(obs) and is_boolean(grounded)

              _ ->
                true
            end
          end)
        ])

      assert result.passed?,
             "Eval failed: #{inspect(result.grader_results, pretty: true)}"
    end

    @tag timeout: 180_000
    test "single-source hypothesis is not grounded", context do
      start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})

      start_supervised!(
        {Coordinator, name: Coordinator, client_registry: context.client_registry}
      )

      notifications = [
        build_notification(%{
          operator: Beamlens.Skill.Beam,
          context: "Production node",
          observation: "Memory at 85%",
          hypothesis: "ETS table growth"
        })
      ]

      {output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, result} =
              Coordinator.run(%{},
                notifications: notifications,
                client_registry: context.client_registry,
                max_iterations: 20,
                timeout: 150_000
              )

            result
          end,
          timeout: 300
        )

      judge_client = build_judge_client()

      grounding_rubric = """
      - Given a SINGLE notification source about memory usage
      - The hypothesis "ETS table growth" should NOT be marked as grounded (hypothesis_grounded: false)
      - A hypothesis requires corroboration from multiple independent sources to be grounded
      - Without corroborating evidence, the hypothesis remains speculative
      """

      grounding_grader = LLM.rubric(judge_client, grounding_rubric)

      result =
        Puck.Eval.grade(output, trajectory, [
          Graders.output_produced(ProduceInsight),
          grounding_grader
        ])

      assert result.passed?,
             "Eval failed: #{inspect(result.grader_results, pretty: true)}"
    end

    @tag timeout: 180_000
    test "corroborated hypotheses are marked as grounded", context do
      start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})

      start_supervised!(
        {Coordinator, name: Coordinator, client_registry: context.client_registry}
      )

      notifications = [
        build_notification(%{
          operator: Beamlens.Skill.Beam,
          context: "Node active",
          observation: "Memory at 85%",
          hypothesis: "ETS table growth"
        }),
        build_notification(%{
          operator: Beamlens.Skill.Ets,
          context: "Node active",
          observation: "ETS using 500MB",
          hypothesis: "Unbounded table growth"
        })
      ]

      {output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, result} =
              Coordinator.run(%{},
                notifications: notifications,
                client_registry: context.client_registry,
                max_iterations: 25,
                timeout: 150_000
              )

            result
          end,
          timeout: 300
        )

      judge_client = build_judge_client()

      grounding_rubric = """
      - Given TWO corroborating notifications about memory/ETS issues
      - The hypothesis about ETS growth should be marked as grounded (hypothesis_grounded: true)
      - The matched_observations list should reference both memory and ETS observations
      - Corroboration from multiple independent sources strengthens the hypothesis
      """

      grounding_grader = LLM.rubric(judge_client, grounding_rubric)

      result =
        Puck.Eval.grade(output, trajectory, [
          Graders.output_produced(ProduceInsight),
          grounding_grader
        ])

      assert result.passed?,
             "Eval failed: #{inspect(result.grader_results, pretty: true)}"
    end
  end

  defp build_notification(attrs) do
    defaults = %{
      operator: :test,
      anomaly_type: "test_anomaly",
      severity: :warning,
      context: "Node running for 3 days",
      observation: "Test observation",
      snapshots: []
    }

    Notification.new(Map.merge(defaults, attrs))
  end

  defp build_judge_client do
    Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5"})
  end
end
