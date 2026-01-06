defmodule Beamlens.Events.JudgeCall do
  @moduledoc """
  Captures a judge evaluation of the agent's health analysis.

  This event is recorded each time the judge reviews an analysis,
  showing whether the output was accepted or needs retry.

  ## Fields

    * `:occurred_at` - When the judge evaluation completed
    * `:attempt` - The attempt number (1-3)
    * `:verdict` - Either `:accept` or `:retry`
    * `:confidence` - Judge's confidence: `:high`, `:medium`, or `:low`
    * `:issues` - List of issues found (empty if accepted)
    * `:feedback` - Guidance for retry (empty if accepted)
  """

  @type t :: %__MODULE__{
          occurred_at: DateTime.t(),
          attempt: pos_integer(),
          verdict: :accept | :retry,
          confidence: :high | :medium | :low,
          issues: [String.t()],
          feedback: String.t()
        }

  @derive Jason.Encoder
  @enforce_keys [:occurred_at, :attempt, :verdict, :confidence]
  defstruct [:occurred_at, :attempt, :verdict, :confidence, issues: [], feedback: ""]
end
