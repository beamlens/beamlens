defmodule Beamlens.Skill.Anomaly.Detector.Metric do
  @moduledoc """
  A collected metric sample from a skill snapshot.
  """

  @enforce_keys [:skill, :metric, :value]
  defstruct [:skill, :metric, :value]

  @type t :: %__MODULE__{
          skill: module(),
          metric: atom(),
          value: float()
        }
end
