defmodule Beamlens.Alert do
  @moduledoc """
  Immediate notification from a watcher about detected anomaly.

  Alerts flow from watchers (workers) to the orchestrator. Each alert contains
  all evidence needed to investigate an anomaly, including the frozen snapshot
  at the time of detection.

  This follows the **Orchestrator-Workers** pattern from Anthropic's agent
  architecture guidelines, where workers detect anomalies and alert UP to
  the orchestrator for correlation and investigation.

  ## Fields

    * `:id` - Unique alert identifier
    * `:watcher` - Domain atom identifying the watcher (e.g., :beam, :ecto)
    * `:anomaly_type` - Classification of the anomaly detected (string from LLM)
    * `:severity` - `:info`, `:warning`, or `:critical`
    * `:summary` - Brief description of the anomaly
    * `:snapshot` - Frozen metrics at time of detection
    * `:detected_at` - When the anomaly was detected
    * `:node` - Node where the anomaly was detected
    * `:trace_id` - Correlation ID for telemetry

  ## Example

      %Beamlens.Alert{
        id: "a1b2c3d4",
        watcher: :beam,
        anomaly_type: "memory_elevated",
        severity: :warning,
        summary: "Memory utilization at 72%, exceeding 60% warning threshold",
        snapshot: %{
          memory_stats: %{total_mb: 1024, processes_mb: 400, ...},
          overview: %{memory_utilization_pct: 72.0, ...}
        },
        detected_at: ~U[2024-01-06 10:30:00Z],
        node: :myapp@host,
        trace_id: "xyz789"
      }
  """

  @type severity :: :info | :warning | :critical

  @type t :: %__MODULE__{
          id: String.t(),
          watcher: atom(),
          anomaly_type: String.t(),
          severity: severity(),
          summary: String.t(),
          snapshot: map(),
          detected_at: DateTime.t(),
          node: atom(),
          trace_id: String.t()
        }

  @derive Jason.Encoder
  @enforce_keys [
    :id,
    :watcher,
    :anomaly_type,
    :severity,
    :summary,
    :snapshot,
    :detected_at,
    :node,
    :trace_id
  ]
  defstruct [
    :id,
    :watcher,
    :anomaly_type,
    :severity,
    :summary,
    :snapshot,
    :detected_at,
    :node,
    :trace_id
  ]

  @doc """
  Creates a new alert with the given attributes.

  ## Required Attributes

    * `:watcher` - Domain atom (e.g., :beam, :ecto)
    * `:anomaly_type` - Classification atom (e.g., :memory_elevated)
    * `:severity` - One of :info, :warning, :critical
    * `:summary` - Brief description string
    * `:snapshot` - Map of frozen metrics

  ## Optional Attributes

    * `:id` - Auto-generated if not provided
    * `:detected_at` - Defaults to current UTC time
    * `:node` - Defaults to current node
    * `:trace_id` - Auto-generated if not provided

  ## Example

      Alert.new(%{
        watcher: :beam,
        anomaly_type: "memory_elevated",
        severity: :warning,
        summary: "Memory at 72%",
        snapshot: Beam.snapshot()
      })
  """
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: Map.get(attrs, :id, generate_id()),
      watcher: Map.fetch!(attrs, :watcher),
      anomaly_type: Map.fetch!(attrs, :anomaly_type),
      severity: Map.fetch!(attrs, :severity),
      summary: Map.fetch!(attrs, :summary),
      snapshot: Map.fetch!(attrs, :snapshot),
      detected_at: Map.get(attrs, :detected_at, DateTime.utc_now()),
      node: Map.get(attrs, :node, Node.self()),
      trace_id: Map.get(attrs, :trace_id, generate_trace_id())
    }
  end

  @doc """
  Generates a unique alert ID.

  Returns an 16-character lowercase hex string.
  """
  def generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
