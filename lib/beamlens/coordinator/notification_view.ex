defmodule Beamlens.Coordinator.NotificationView do
  @moduledoc """
  View of a notification for the coordinator's LLM context.
  """

  @enforce_keys [
    :id,
    :status,
    :operator,
    :anomaly_type,
    :severity,
    :context,
    :observation,
    :detected_at
  ]
  @derive Jason.Encoder
  defstruct [
    :id,
    :status,
    :operator,
    :anomaly_type,
    :severity,
    :context,
    :observation,
    :hypothesis,
    :detected_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          status: :unread | :acknowledged | :resolved,
          operator: module(),
          anomaly_type: String.t(),
          severity: :info | :warning | :critical,
          context: String.t(),
          observation: String.t(),
          hypothesis: String.t() | nil,
          detected_at: DateTime.t()
        }

  def from_entry(id, %{notification: notification, status: status}) do
    %__MODULE__{
      id: id,
      status: status,
      operator: notification.operator,
      anomaly_type: notification.anomaly_type,
      severity: notification.severity,
      context: notification.context,
      observation: notification.observation,
      hypothesis: notification.hypothesis,
      detected_at: notification.detected_at
    }
  end
end
