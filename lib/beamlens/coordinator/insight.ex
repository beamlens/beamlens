defmodule Beamlens.Coordinator.Insight do
  @moduledoc """
  Represents a correlated insight produced by the Coordinator.

  Insights aggregate related alerts and identify patterns across them.
  """

  @type correlation_type :: :temporal | :causal | :symptomatic

  @type t :: %__MODULE__{
          id: String.t(),
          alert_ids: [String.t()],
          correlation_type: correlation_type(),
          summary: String.t(),
          root_cause_hypothesis: String.t() | nil,
          confidence: :high | :medium | :low,
          created_at: DateTime.t()
        }

  @derive Jason.Encoder
  @enforce_keys [:id, :alert_ids, :correlation_type, :summary, :confidence, :created_at]
  defstruct [
    :id,
    :alert_ids,
    :correlation_type,
    :summary,
    :root_cause_hypothesis,
    :confidence,
    :created_at
  ]

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: generate_id(),
      alert_ids: Map.fetch!(attrs, :alert_ids),
      correlation_type: Map.fetch!(attrs, :correlation_type),
      summary: Map.fetch!(attrs, :summary),
      root_cause_hypothesis: Map.get(attrs, :root_cause_hypothesis),
      confidence: Map.fetch!(attrs, :confidence),
      created_at: DateTime.utc_now()
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
