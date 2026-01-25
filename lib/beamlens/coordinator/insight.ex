defmodule Beamlens.Coordinator.Insight do
  @moduledoc """
  Represents a correlated insight produced by the Coordinator.

  Insights aggregate related notifications and identify patterns across them.

  ## Grounding Fields

  Insights track whether their conclusions are grounded in factual observations:

    * `:matched_observations` - List of specific observations that correlated
    * `:hypothesis_grounded` - Whether hypotheses were corroborated by multiple operators

  The coordinator correlates on `context` + `observation` fields from notifications only.
  Hypotheses are only considered grounded when corroborated by multiple independent operators.
  """

  @type correlation_type :: :temporal | :causal | :symptomatic

  @type t :: %__MODULE__{
          id: String.t(),
          notification_ids: [String.t()],
          correlation_type: correlation_type(),
          summary: String.t(),
          matched_observations: [String.t()],
          hypothesis_grounded: boolean(),
          root_cause_hypothesis: String.t() | nil,
          confidence: :high | :medium | :low,
          created_at: DateTime.t()
        }

  @derive Jason.Encoder
  @enforce_keys [
    :id,
    :notification_ids,
    :correlation_type,
    :summary,
    :matched_observations,
    :hypothesis_grounded,
    :confidence,
    :created_at
  ]
  defstruct [
    :id,
    :notification_ids,
    :correlation_type,
    :summary,
    :matched_observations,
    :hypothesis_grounded,
    :root_cause_hypothesis,
    :confidence,
    :created_at
  ]

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: generate_id(),
      notification_ids: Map.fetch!(attrs, :notification_ids),
      correlation_type: Map.fetch!(attrs, :correlation_type),
      summary: Map.fetch!(attrs, :summary),
      matched_observations: Map.fetch!(attrs, :matched_observations),
      hypothesis_grounded: Map.fetch!(attrs, :hypothesis_grounded),
      root_cause_hypothesis: Map.get(attrs, :root_cause_hypothesis),
      confidence: Map.fetch!(attrs, :confidence),
      created_at: DateTime.utc_now()
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
