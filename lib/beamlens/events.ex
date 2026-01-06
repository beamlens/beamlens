defmodule Beamlens.Events do
  @moduledoc """
  Event types for agent execution trace.

  Events capture everything that happens during an agent run - LLM decisions,
  tool executions, and judge reviews. They provide data provenance so users
  can verify AI conclusions against raw data.

  ## Event Types

    * `Beamlens.Events.LLMCall` - Captures an LLM decision (which tool was selected)
    * `Beamlens.Events.ToolCall` - Captures a tool execution with its result
    * `Beamlens.Events.JudgeCall` - Captures a judge review verdict

  ## Example

      events = [
        %Events.LLMCall{occurred_at: ~U[...], iteration: 0, tool_selected: "get_system_info"},
        %Events.ToolCall{intent: "get_system_info", occurred_at: ~U[...], result: %{...}},
        %Events.LLMCall{occurred_at: ~U[...], iteration: 1, tool_selected: "done"},
        %Events.JudgeCall{occurred_at: ~U[...], attempt: 1, verdict: :accept, confidence: :high}
      ]
  """

  alias Beamlens.Events.{JudgeCall, LLMCall, ToolCall}

  @type t :: LLMCall.t() | ToolCall.t() | JudgeCall.t()
end
