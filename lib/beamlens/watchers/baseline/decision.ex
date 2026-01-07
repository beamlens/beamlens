defmodule Beamlens.Watchers.Baseline.Decision do
  @moduledoc """
  Decision structs and union schema for baseline analysis.

  Each struct represents a possible decision from the LLM:
  - ContinueObserving: Need more data or patterns still emerging
  - ReportAnomaly: Detected deviation from baseline
  - ReportHealthy: Confident system is operating normally
  """

  defmodule ContinueObserving do
    @moduledoc false
    defstruct [:intent, :notes, :confidence]

    @type t :: %__MODULE__{
            intent: String.t(),
            notes: String.t(),
            confidence: :low | :medium
          }
  end

  defmodule ReportAnomaly do
    @moduledoc false
    defstruct [
      :intent,
      :anomaly_type,
      :severity,
      :summary,
      :evidence,
      :confidence,
      :cooldown_minutes
    ]

    @type t :: %__MODULE__{
            intent: String.t(),
            anomaly_type: String.t(),
            severity: :info | :warning | :critical,
            summary: String.t(),
            evidence: [String.t()],
            confidence: :medium | :high,
            cooldown_minutes: integer()
          }
  end

  defmodule ReportHealthy do
    @moduledoc false
    defstruct [:intent, :summary, :confidence]

    @type t :: %__MODULE__{
            intent: String.t(),
            summary: String.t(),
            confidence: :medium | :high
          }
  end

  @doc """
  Returns a ZOI union schema for parsing AnalyzeBaseline responses into structs.

  Uses discriminated union pattern matching on the `intent` field.
  """
  def schema do
    Zoi.union([
      continue_observing_schema(),
      report_anomaly_schema(),
      report_healthy_schema()
    ])
  end

  defp continue_observing_schema do
    Zoi.object(%{
      intent: Zoi.literal("continue_observing"),
      notes: Zoi.string(),
      confidence: Zoi.enum(["low", "medium"]) |> Zoi.transform(&atomize_confidence/1)
    })
    |> Zoi.transform(fn data -> {:ok, struct!(ContinueObserving, data)} end)
  end

  defp report_anomaly_schema do
    Zoi.object(%{
      intent: Zoi.literal("report_anomaly"),
      anomaly_type: Zoi.string(),
      severity: Zoi.enum(["info", "warning", "critical"]) |> Zoi.transform(&atomize_severity/1),
      summary: Zoi.string(),
      evidence: Zoi.array(Zoi.string()),
      confidence: Zoi.enum(["medium", "high"]) |> Zoi.transform(&atomize_confidence/1),
      cooldown_minutes: Zoi.integer() |> Zoi.default(5)
    })
    |> Zoi.transform(fn data -> {:ok, struct!(ReportAnomaly, data)} end)
  end

  defp report_healthy_schema do
    Zoi.object(%{
      intent: Zoi.literal("report_healthy"),
      summary: Zoi.string(),
      confidence: Zoi.enum(["medium", "high"]) |> Zoi.transform(&atomize_confidence/1)
    })
    |> Zoi.transform(fn data -> {:ok, struct!(ReportHealthy, data)} end)
  end

  defp atomize_confidence("low"), do: {:ok, :low}
  defp atomize_confidence("medium"), do: {:ok, :medium}
  defp atomize_confidence("high"), do: {:ok, :high}

  defp atomize_severity("info"), do: {:ok, :info}
  defp atomize_severity("warning"), do: {:ok, :warning}
  defp atomize_severity("critical"), do: {:ok, :critical}
end
