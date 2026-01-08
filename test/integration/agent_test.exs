defmodule Beamlens.Integration.AgentTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  describe "Agent.run/1" do
    @describetag timeout: 120_000

    test "runs agent loop and returns health analysis", %{client_registry: client_registry} do
      {:ok, analysis} =
        Beamlens.Agent.run(
          max_iterations: 10,
          client_registry: client_registry,
          timeout: :timer.seconds(60)
        )

      assert %Beamlens.HealthAnalysis{} = analysis
      assert analysis.status in [:healthy, :warning, :critical]
      assert is_binary(analysis.summary)
      assert is_list(analysis.concerns)
      assert is_list(analysis.recommendations)
    end

    test "populates events with snapshot first, then interleaved LLMCall and ToolCall", %{
      client_registry: client_registry
    } do
      {:ok, analysis} =
        Beamlens.Agent.run(
          max_iterations: 10,
          client_registry: client_registry,
          timeout: :timer.seconds(60)
        )

      assert is_list(analysis.events)
      assert length(analysis.events) >= 2

      [snapshot_event | rest] = analysis.events
      assert %Beamlens.Events.ToolCall{intent: "snapshot"} = snapshot_event
      assert is_map(snapshot_event.result)
      assert Map.has_key?(snapshot_event.result, :overview)

      llm_calls = Enum.filter(rest, &match?(%Beamlens.Events.LLMCall{}, &1))
      tool_calls = Enum.filter(rest, &match?(%Beamlens.Events.ToolCall{}, &1))

      assert llm_calls != []

      [first_llm_call | _] = llm_calls
      assert is_binary(first_llm_call.tool_selected)
      assert %DateTime{} = first_llm_call.occurred_at
      assert is_integer(first_llm_call.iteration)

      Enum.each(tool_calls, fn tool_call ->
        assert is_binary(tool_call.intent)
        assert %DateTime{} = tool_call.occurred_at
        assert is_map(tool_call.result)
      end)
    end

    test "includes JudgeCall event when judge is enabled (default)", %{
      client_registry: client_registry
    } do
      {:ok, analysis} =
        Beamlens.Agent.run(
          max_iterations: 10,
          client_registry: client_registry,
          timeout: :timer.seconds(60)
        )

      judge_calls = Enum.filter(analysis.events, &match?(%Beamlens.Events.JudgeCall{}, &1))

      assert judge_calls != [], "Expected at least one JudgeCall event"

      [judge_call | _] = judge_calls
      assert judge_call.verdict in [:accept, :retry]
      assert judge_call.confidence in [:high, :medium, :low]
      assert is_list(judge_call.issues)
      assert is_binary(judge_call.feedback)
      assert is_integer(judge_call.attempt)
      assert %DateTime{} = judge_call.occurred_at
    end

    test "excludes JudgeCall events when judge is disabled", %{client_registry: client_registry} do
      {:ok, analysis} =
        Beamlens.Agent.run(
          max_iterations: 10,
          judge: false,
          client_registry: client_registry,
          timeout: :timer.seconds(60)
        )

      judge_calls = Enum.filter(analysis.events, &match?(%Beamlens.Events.JudgeCall{}, &1))

      assert judge_calls == [], "Expected no JudgeCall events when judge: false"
    end
  end
end
