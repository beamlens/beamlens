defmodule Beamlens.Operator.Alert do
  @moduledoc """
  Immediate notification from an operator about detected anomaly.

  Alerts are emitted via telemetry events when an operator detects an anomaly.
  Each alert contains all evidence needed to investigate, including referenced
  snapshots that were captured during investigation.

  ## Fields

    * `:id` - Unique alert identifier
    * `:operator` - Domain atom identifying the operator (e.g., :beam, :ecto)
    * `:anomaly_type` - Classification of the anomaly detected (string from LLM)
    * `:severity` - `:info`, `:warning`, or `:critical`
    * `:summary` - Brief description of the anomaly
    * `:snapshots` - List of referenced snapshots captured during investigation
    * `:detected_at` - When the anomaly was detected
    * `:node` - Node where the anomaly was detected
    * `:trace_id` - Correlation ID for telemetry

  ## Example

      %Beamlens.Operator.Alert{
        id: "a1b2c3d4",
        operator: :beam,
        anomaly_type: "memory_elevated",
        severity: :warning,
        summary: "Memory utilization at 72%, exceeding 60% warning threshold",
        snapshots: [
          %{id: "abc123", captured_at: ~U[2024-01-06 10:30:00Z], data: %{...}},
          %{id: "def456", captured_at: ~U[2024-01-06 10:30:30Z], data: %{...}}
        ],
        detected_at: ~U[2024-01-06 10:30:00Z],
        node: :myapp@host,
        trace_id: "xyz789"
      }
  """

  @type severity :: :info | :warning | :critical

  @type t :: %__MODULE__{
          id: String.t(),
          operator: atom(),
          anomaly_type: String.t(),
          severity: severity(),
          summary: String.t(),
          snapshots: [map()],
          detected_at: DateTime.t(),
          node: atom(),
          trace_id: String.t()
        }

  @derive Jason.Encoder
  @enforce_keys [
    :id,
    :operator,
    :anomaly_type,
    :severity,
    :summary,
    :snapshots,
    :detected_at,
    :node,
    :trace_id
  ]
  defstruct [
    :id,
    :operator,
    :anomaly_type,
    :severity,
    :summary,
    :snapshots,
    :detected_at,
    :node,
    :trace_id
  ]

  @doc """
  Creates a new alert with the given attributes.

  ## Required Attributes

    * `:operator` - Domain atom (e.g., :beam, :ecto)
    * `:anomaly_type` - Classification string (e.g., "memory_elevated")
    * `:severity` - One of :info, :warning, :critical
    * `:summary` - Brief description string
    * `:snapshots` - List of snapshot maps

  ## Optional Attributes

    * `:id` - Auto-generated if not provided
    * `:detected_at` - Defaults to current UTC time
    * `:node` - Defaults to current node
    * `:trace_id` - Auto-generated if not provided

  ## Example

      Alert.new(%{
        operator: :beam,
        anomaly_type: "memory_elevated",
        severity: :warning,
        summary: "Memory at 72%",
        snapshots: [snapshot1, snapshot2]
      })
  """
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: Map.get(attrs, :id, generate_id()),
      operator: Map.fetch!(attrs, :operator),
      anomaly_type: Map.fetch!(attrs, :anomaly_type),
      severity: Map.fetch!(attrs, :severity),
      summary: Map.fetch!(attrs, :summary),
      snapshots: Map.fetch!(attrs, :snapshots),
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
