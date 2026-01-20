defmodule Beamlens.Operator.CompletionResult do
  @moduledoc """
  Result sent to `notify_pid` when an operator completes analysis.

  Contains the final state and all collected data from the operator run.
  """

  alias Beamlens.Operator.{Notification, Snapshot}

  defstruct [:state, :notifications, :snapshots]

  @type t :: %__MODULE__{
          state: :healthy | :observing | :warning | :critical,
          notifications: [Notification.t()],
          snapshots: [Snapshot.t()]
        }
end
