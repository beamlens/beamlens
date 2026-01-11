defmodule Beamlens.Operator.Snapshot do
  @moduledoc """
  Wrapper struct for snapshots with unique ID and timestamp.

  Snapshots are captured via `take_snapshot` and stored in the operator's
  GenServer state. When firing alerts, the LLM references snapshots by ID
  to include relevant evidence.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          captured_at: DateTime.t(),
          data: map()
        }

  @derive Jason.Encoder
  @enforce_keys [:id, :captured_at, :data]
  defstruct [:id, :captured_at, :data]

  @doc """
  Creates a new snapshot wrapping the given metrics data.

  Generates a unique ID and timestamps the snapshot.
  """
  def new(data) when is_map(data) do
    %__MODULE__{
      id: generate_id(),
      captured_at: DateTime.utc_now(),
      data: data
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
