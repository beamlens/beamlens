defmodule Beamlens.Coordinator.NotificationEntry do
  @moduledoc false

  @enforce_keys [:notification, :status]
  defstruct [:notification, :status]
end
