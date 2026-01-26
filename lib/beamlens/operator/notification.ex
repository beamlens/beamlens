defmodule Beamlens.Operator.Notification do
  @moduledoc """
  Immediate notification from an operator about detected anomaly.

  Notifications are emitted via telemetry events when an operator detects an anomaly.
  Each notification contains all evidence needed to investigate, including referenced
  snapshots that were captured during investigation.

  ## Decomposed Fields (Fact vs Speculation)

  Notifications separate factual observations from speculation to enable better
  correlation by the coordinator:

    * `:context` - Factual system state description (e.g., "Node running for 3 days")
    * `:observation` - What anomaly was detected, factually (e.g., "Memory at 85%")
    * `:hypothesis` - What might be causing it, speculative (e.g., "likely ETS growth")

  The coordinator correlates on `context` + `observation` only, and uses `hypothesis`
  only when corroborated by multiple operators.

  ## All Fields

    * `:id` - Unique notification identifier
    * `:operator` - Module implementing the skill (e.g., Beamlens.Skill.Beam)
    * `:anomaly_type` - Classification of the anomaly detected (string from LLM)
    * `:severity` - `:info`, `:warning`, or `:critical`
    * `:context` - Factual system state description
    * `:observation` - Factual anomaly description
    * `:hypothesis` - Speculative cause (optional)
    * `:snapshots` - List of referenced snapshots captured during investigation
    * `:detected_at` - When the anomaly was detected
    * `:node` - Node where the anomaly was detected
    * `:trace_id` - Correlation ID for telemetry

  ## Example

      %Beamlens.Operator.Notification{
        id: "a1b2c3d4",
        operator: Beamlens.Skill.Beam,
        anomaly_type: "memory_elevated",
        severity: :warning,
        context: "Node running for 3 days, 500 processes active",
        observation: "Memory utilization at 72%, exceeding 60% warning threshold",
        hypothesis: "Likely due to ETS table growth in caching module",
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
          operator: module(),
          anomaly_type: String.t(),
          severity: severity(),
          context: String.t(),
          observation: String.t(),
          hypothesis: String.t() | nil,
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
    :context,
    :observation,
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
    :context,
    :observation,
    :hypothesis,
    :snapshots,
    :detected_at,
    :node,
    :trace_id
  ]

  @doc """
  Creates a new notification with the given attributes.

  ## Required Attributes

    * `:operator` - Domain atom (e.g., :beam, :ecto)
    * `:anomaly_type` - Classification string (e.g., "memory_elevated")
    * `:severity` - One of :info, :warning, :critical
    * `:context` - Factual system state description
    * `:observation` - Factual anomaly description
    * `:snapshots` - List of snapshot maps

  ## Optional Attributes

    * `:id` - Auto-generated if not provided
    * `:hypothesis` - Speculative cause (optional)
    * `:detected_at` - Defaults to current UTC time
    * `:node` - Defaults to current node
    * `:trace_id` - Auto-generated if not provided

  ## Example

      Notification.new(%{
        operator: :beam,
        anomaly_type: "memory_elevated",
        severity: :warning,
        context: "Node running for 3 days, 500 processes",
        observation: "Memory at 72%, exceeding threshold",
        hypothesis: "Likely ETS table growth",
        snapshots: [snapshot1, snapshot2]
      })
  """
  def new(attrs) when is_map(attrs) do
    context = Map.fetch!(attrs, :context)
    observation = Map.fetch!(attrs, :observation)
    hypothesis = Map.get(attrs, :hypothesis)

    %__MODULE__{
      id: Map.get(attrs, :id, generate_id()),
      operator: Map.fetch!(attrs, :operator),
      anomaly_type: Map.fetch!(attrs, :anomaly_type),
      severity: Map.fetch!(attrs, :severity),
      context: context,
      observation: observation,
      hypothesis: hypothesis,
      snapshots: Map.fetch!(attrs, :snapshots),
      detected_at: Map.get(attrs, :detected_at, DateTime.utc_now()),
      node: Map.get(attrs, :node, Node.self()),
      trace_id: Map.get(attrs, :trace_id, generate_trace_id())
    }
  end

  @doc """
  Generates a unique notification ID.

  Returns an 16-character lowercase hex string.
  """
  def generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
