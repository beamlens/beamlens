defmodule Beamlens.Coordinator.OperatorStatusView do
  @moduledoc """
  View of operator status for the coordinator's LLM context.
  """

  @enforce_keys [:skill, :alive]
  @derive Jason.Encoder
  defstruct [:skill, :alive, :state, :iteration, :running, :started_at]

  @type t :: %__MODULE__{
          skill: module(),
          alive: boolean(),
          state: :healthy | :observing | :warning | :critical | nil,
          iteration: non_neg_integer() | nil,
          running: boolean() | nil,
          started_at: DateTime.t() | nil
        }

  def alive(skill, status, started_at) do
    %__MODULE__{
      skill: skill,
      alive: true,
      state: status.state,
      iteration: status.iteration,
      running: status.running,
      started_at: started_at
    }
  end

  def dead(skill) do
    %__MODULE__{skill: skill, alive: false}
  end
end
