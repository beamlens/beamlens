defmodule Beamlens.Operator.Tools do
  @moduledoc """
  Tool structs and union schema for the operator agent.

  Tools:
  - SetState: Update operator state
  - SendNotification: Create a notification with referenced snapshots
  - GetNotifications: See previous notifications for correlation
  - TakeSnapshot: Capture current metrics with unique ID
  - GetSnapshot: Retrieve a specific snapshot by ID
  - GetSnapshots: Retrieve multiple snapshots with pagination
  - Execute: Run Lua code with metric callbacks
  - Wait: Sleep, then continue with fresh context
  - Think: Reason through complex decisions before acting
  - Done: Signal analysis completion

  `SendNotification.snapshot_ids` must be a list of snapshot IDs to reference.
  """

  defmodule SetState do
    @moduledoc false
    defstruct [:intent, :state, :reason]

    @type t :: %__MODULE__{
            intent: String.t(),
            state: :healthy | :observing | :warning | :critical,
            reason: String.t()
          }
  end

  defmodule SendNotification do
    @moduledoc false
    defstruct [:intent, :type, :summary, :severity, :snapshot_ids]

    @type t :: %__MODULE__{
            intent: String.t(),
            type: String.t(),
            summary: String.t(),
            severity: :info | :warning | :critical,
            snapshot_ids: [String.t()]
          }
  end

  defmodule GetNotifications do
    @moduledoc false
    defstruct [:intent]

    @type t :: %__MODULE__{intent: String.t()}
  end

  defmodule TakeSnapshot do
    @moduledoc false
    defstruct [:intent]

    @type t :: %__MODULE__{intent: String.t()}
  end

  defmodule GetSnapshot do
    @moduledoc false
    defstruct [:intent, :id]

    @type t :: %__MODULE__{
            intent: String.t(),
            id: String.t()
          }
  end

  defmodule GetSnapshots do
    @moduledoc false
    defstruct [:intent, :limit, :offset]

    @type t :: %__MODULE__{
            intent: String.t(),
            limit: pos_integer() | nil,
            offset: non_neg_integer() | nil
          }
  end

  defmodule Execute do
    @moduledoc false
    defstruct [:intent, :code]

    @type t :: %__MODULE__{
            intent: String.t(),
            code: String.t()
          }
  end

  defmodule Wait do
    @moduledoc false
    defstruct [:intent, :ms]

    @type t :: %__MODULE__{
            intent: String.t(),
            ms: pos_integer()
          }
  end

  defmodule Think do
    @moduledoc false
    defstruct [:intent, :thought]

    @type t :: %__MODULE__{
            intent: String.t(),
            thought: String.t()
          }
  end

  defmodule Done do
    @moduledoc false
    defstruct [:intent]

    @type t :: %__MODULE__{intent: String.t()}
  end

  @doc """
  Returns a Zoi union schema for parsing operator tool responses.

  Uses discriminated union pattern matching on the `intent` field.
  """
  def schema do
    Zoi.union([
      set_state_schema(),
      send_notification_schema(),
      get_notifications_schema(),
      take_snapshot_schema(),
      get_snapshot_schema(),
      get_snapshots_schema(),
      execute_schema(),
      wait_schema(),
      think_schema(),
      done_schema()
    ])
  end

  defp set_state_schema do
    Zoi.object(%{
      intent: Zoi.literal("set_state"),
      state:
        Zoi.enum(["healthy", "observing", "warning", "critical"])
        |> Zoi.transform(&atomize_state/1),
      reason: Zoi.string()
    })
    |> Zoi.transform(fn data -> {:ok, struct!(SetState, data)} end)
  end

  defp send_notification_schema do
    Zoi.object(%{
      intent: Zoi.literal("send_notification"),
      type: Zoi.string(),
      summary: Zoi.string(),
      severity:
        Zoi.enum(["info", "warning", "critical"])
        |> Zoi.transform(&atomize_severity/1),
      snapshot_ids: Zoi.list(Zoi.string())
    })
    |> Zoi.transform(fn data -> {:ok, struct!(SendNotification, data)} end)
  end

  defp get_notifications_schema do
    Zoi.object(%{intent: Zoi.literal("get_notifications")})
    |> Zoi.transform(fn data -> {:ok, struct!(GetNotifications, data)} end)
  end

  defp take_snapshot_schema do
    Zoi.object(%{intent: Zoi.literal("take_snapshot")})
    |> Zoi.transform(fn data -> {:ok, struct!(TakeSnapshot, data)} end)
  end

  defp get_snapshot_schema do
    Zoi.object(%{
      intent: Zoi.literal("get_snapshot"),
      id: Zoi.string()
    })
    |> Zoi.transform(fn data -> {:ok, struct!(GetSnapshot, data)} end)
  end

  defp get_snapshots_schema do
    Zoi.object(%{
      intent: Zoi.literal("get_snapshots"),
      limit: Zoi.nullish(Zoi.integer()),
      offset: Zoi.nullish(Zoi.integer())
    })
    |> Zoi.transform(fn data -> {:ok, struct!(GetSnapshots, data)} end)
  end

  defp execute_schema do
    Zoi.object(%{
      intent: Zoi.literal("execute"),
      code: Zoi.string()
    })
    |> Zoi.transform(fn data -> {:ok, struct!(Execute, data)} end)
  end

  defp wait_schema do
    Zoi.object(%{
      intent: Zoi.literal("wait"),
      ms: Zoi.integer()
    })
    |> Zoi.transform(fn data -> {:ok, struct!(Wait, data)} end)
  end

  defp think_schema do
    Zoi.object(%{
      intent: Zoi.literal("think"),
      thought: Zoi.string()
    })
    |> Zoi.transform(fn data -> {:ok, struct!(Think, data)} end)
  end

  defp done_schema do
    Zoi.object(%{intent: Zoi.literal("done")})
    |> Zoi.transform(fn data -> {:ok, struct!(Done, data)} end)
  end

  defp atomize_state("healthy"), do: {:ok, :healthy}
  defp atomize_state("observing"), do: {:ok, :observing}
  defp atomize_state("warning"), do: {:ok, :warning}
  defp atomize_state("critical"), do: {:ok, :critical}

  defp atomize_severity("info"), do: {:ok, :info}
  defp atomize_severity("warning"), do: {:ok, :warning}
  defp atomize_severity("critical"), do: {:ok, :critical}
end
