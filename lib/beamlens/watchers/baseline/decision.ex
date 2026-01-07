defmodule Beamlens.Watchers.Baseline.Decision do
  @moduledoc """
  Decision structs and union schema for baseline analysis.

  Each struct represents a possible decision from the LLM:
  - ContinueObserving: Need more data or patterns still emerging
  - Alert: Detected deviation from baseline
  - Healthy: Confident system is operating normally
  - InvestigationComplete: Watcher investigation finished with findings
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

  defmodule Alert do
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

  defmodule Healthy do
    @moduledoc false
    defstruct [:intent, :summary, :confidence]

    @type t :: %__MODULE__{
            intent: String.t(),
            summary: String.t(),
            confidence: :medium | :high
          }
  end

  defmodule WatcherFindings do
    @moduledoc """
    Findings produced by watcher investigation after anomaly detection.
    """
    defstruct [
      :anomaly_type,
      :severity,
      :root_cause,
      :evidence,
      :recommendations,
      :confidence
    ]

    @type t :: %__MODULE__{
            anomaly_type: String.t(),
            severity: :info | :warning | :critical,
            root_cause: String.t(),
            evidence: [String.t()],
            recommendations: [String.t()],
            confidence: :low | :medium | :high
          }
  end

  defmodule InvestigationComplete do
    @moduledoc false
    defstruct [:intent, :findings]

    @type t :: %__MODULE__{
            intent: String.t(),
            findings: WatcherFindings.t()
          }
  end

  @doc """
  Returns a ZOI union schema for parsing AnalyzeBaseline responses into structs.

  Uses discriminated union pattern matching on the `intent` field.
  """
  def schema do
    Zoi.union([
      continue_observing_schema(),
      alert_schema(),
      healthy_schema()
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

  defp alert_schema do
    Zoi.object(%{
      intent: Zoi.literal("report_anomaly"),
      anomaly_type: Zoi.string(),
      severity: Zoi.enum(["info", "warning", "critical"]) |> Zoi.transform(&atomize_severity/1),
      summary: Zoi.string(),
      evidence: Zoi.array(Zoi.string()),
      confidence: Zoi.enum(["medium", "high"]) |> Zoi.transform(&atomize_confidence/1),
      cooldown_minutes: Zoi.integer() |> Zoi.default(5)
    })
    |> Zoi.transform(fn data -> {:ok, struct!(Alert, data)} end)
  end

  defp healthy_schema do
    Zoi.object(%{
      intent: Zoi.literal("report_healthy"),
      summary: Zoi.string(),
      confidence: Zoi.enum(["medium", "high"]) |> Zoi.transform(&atomize_confidence/1)
    })
    |> Zoi.transform(fn data -> {:ok, struct!(Healthy, data)} end)
  end

  defp atomize_confidence("low"), do: {:ok, :low}
  defp atomize_confidence("medium"), do: {:ok, :medium}
  defp atomize_confidence("high"), do: {:ok, :high}

  defp atomize_severity("info"), do: {:ok, :info}
  defp atomize_severity("warning"), do: {:ok, :warning}
  defp atomize_severity("critical"), do: {:ok, :critical}

  @doc """
  Returns a ZOI schema for parsing SelectInvestigationTool responses.

  Parses tool selections into structs (reusing Beamlens.Tools structs)
  or InvestigationComplete with findings.
  """
  def investigation_schema do
    alias Beamlens.Tools

    Zoi.union([
      simple_tool_schema(Tools.GetOverview, "get_overview"),
      simple_tool_schema(Tools.GetSystemInfo, "get_system_info"),
      simple_tool_schema(Tools.GetMemoryStats, "get_memory_stats"),
      simple_tool_schema(Tools.GetProcessStats, "get_process_stats"),
      simple_tool_schema(Tools.GetSchedulerStats, "get_scheduler_stats"),
      simple_tool_schema(Tools.GetAtomStats, "get_atom_stats"),
      simple_tool_schema(Tools.GetPersistentTerms, "get_persistent_terms"),
      top_processes_schema(),
      investigation_complete_schema()
    ])
  end

  defp simple_tool_schema(module, intent_value) do
    Zoi.object(%{intent: Zoi.literal(intent_value)})
    |> Zoi.transform(fn data -> {:ok, struct!(module, data)} end)
  end

  defp top_processes_schema do
    alias Beamlens.Tools.GetTopProcesses

    Zoi.object(%{
      intent: Zoi.literal("get_top_processes"),
      limit: Zoi.integer() |> Zoi.optional(),
      offset: Zoi.integer() |> Zoi.optional(),
      sort_by: Zoi.enum(["memory", "message_queue", "reductions"]) |> Zoi.optional()
    })
    |> Zoi.transform(fn data -> {:ok, struct!(GetTopProcesses, data)} end)
  end

  defp investigation_complete_schema do
    findings_schema =
      Zoi.object(%{
        anomaly_type: Zoi.string(),
        severity: Zoi.enum(["info", "warning", "critical"]) |> Zoi.transform(&atomize_severity/1),
        root_cause: Zoi.string(),
        evidence: Zoi.array(Zoi.string()),
        recommendations: Zoi.array(Zoi.string()),
        confidence: Zoi.enum(["low", "medium", "high"]) |> Zoi.transform(&atomize_confidence/1)
      })
      |> Zoi.transform(fn data -> {:ok, struct!(WatcherFindings, data)} end)

    Zoi.object(%{
      intent: Zoi.literal("investigation_complete"),
      findings: findings_schema
    })
    |> Zoi.transform(fn data -> {:ok, struct!(InvestigationComplete, data)} end)
  end
end
