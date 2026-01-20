defmodule Beamlens.Coordinator.RunningOperator do
  @moduledoc false

  @enforce_keys [:skill, :ref, :started_at]
  defstruct [:skill, :ref, :started_at]
end
