defmodule Beamlens.Skill.Anomaly.Detector.Status do
  @moduledoc """
  Status information for the anomaly detector.
  """

  @enforce_keys [
    :state,
    :consecutive_count,
    :collection_interval_ms,
    :auto_trigger,
    :triggers_in_last_hour
  ]
  defstruct [
    :state,
    :learning_start_time,
    :learning_elapsed_ms,
    :cooldown_start_time,
    :consecutive_count,
    :collection_interval_ms,
    :auto_trigger,
    :triggers_in_last_hour
  ]

  @type t :: %__MODULE__{
          state: :learning | :active | :cooldown,
          learning_start_time: integer() | nil,
          learning_elapsed_ms: integer() | nil,
          cooldown_start_time: integer() | nil,
          consecutive_count: non_neg_integer(),
          collection_interval_ms: pos_integer(),
          auto_trigger: boolean(),
          triggers_in_last_hour: non_neg_integer()
        }
end
