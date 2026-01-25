defmodule Beamlens.Coordinator.Tools do
  @moduledoc """
  Tool structs and union schema for the coordinator agent.

  Tools:
  - GetNotifications: Query notifications, optionally filtered by status
  - UpdateNotificationStatuses: Set status on multiple notifications
  - ProduceInsight: Emit insight + auto-resolve referenced notifications
  - Done: Signal analysis completion
  - Think: Reason through complex decisions before acting
  - InvokeOperators: Spawn multiple operators in parallel
  - MessageOperator: Send message to running operator, get LLM response
  - GetOperatorStatuses: Check status of running operators
  - Wait: Pause loop for specified duration
  """

  defmodule GetNotifications do
    @moduledoc false
    defstruct [:intent, :status]

    @type t :: %__MODULE__{
            intent: String.t(),
            status: :unread | :acknowledged | :resolved | nil
          }
  end

  defmodule UpdateNotificationStatuses do
    @moduledoc false
    defstruct [:intent, :notification_ids, :status, :reason]

    @type t :: %__MODULE__{
            intent: String.t(),
            notification_ids: [String.t()],
            status: :acknowledged | :resolved,
            reason: String.t() | nil
          }
  end

  defmodule ProduceInsight do
    @moduledoc false
    defstruct [
      :intent,
      :notification_ids,
      :correlation_type,
      :summary,
      :matched_observations,
      :hypothesis_grounded,
      :root_cause_hypothesis,
      :confidence
    ]

    @type t :: %__MODULE__{
            intent: String.t(),
            notification_ids: [String.t()],
            correlation_type: :temporal | :causal | :symptomatic,
            summary: String.t(),
            matched_observations: [String.t()],
            hypothesis_grounded: boolean(),
            root_cause_hypothesis: String.t() | nil,
            confidence: :high | :medium | :low
          }
  end

  defmodule Done do
    @moduledoc false
    defstruct [:intent]

    @type t :: %__MODULE__{intent: String.t()}
  end

  defmodule Think do
    @moduledoc false
    defstruct [:intent, :thought]

    @type t :: %__MODULE__{
            intent: String.t(),
            thought: String.t()
          }
  end

  defmodule InvokeOperators do
    @moduledoc false
    defstruct [:intent, :skills, :context]

    @type t :: %__MODULE__{
            intent: String.t(),
            skills: [String.t()],
            context: String.t() | nil
          }
  end

  defmodule MessageOperator do
    @moduledoc false
    defstruct [:intent, :skill, :message]

    @type t :: %__MODULE__{
            intent: String.t(),
            skill: String.t(),
            message: String.t()
          }
  end

  defmodule GetOperatorStatuses do
    @moduledoc false
    defstruct [:intent]

    @type t :: %__MODULE__{intent: String.t()}
  end

  defmodule Wait do
    @moduledoc false
    defstruct [:intent, :ms]

    @type t :: %__MODULE__{
            intent: String.t(),
            ms: pos_integer()
          }
  end

  @doc """
  Returns a Zoi union schema for parsing coordinator tool responses.

  Uses discriminated union pattern matching on the `intent` field.
  """
  def schema do
    Zoi.union([
      get_notifications_schema(),
      update_notification_statuses_schema(),
      produce_insight_schema(),
      done_schema(),
      think_schema(),
      invoke_operators_schema(),
      message_operator_schema(),
      get_operator_statuses_schema(),
      wait_schema()
    ])
  end

  defp get_notifications_schema do
    Zoi.object(%{
      intent: Zoi.literal("get_notifications"),
      status:
        Zoi.nullish(
          Zoi.enum(["unread", "acknowledged", "resolved", "all"])
          |> Zoi.transform(&atomize_status/1)
        )
    })
    |> Zoi.transform(fn data -> {:ok, struct!(GetNotifications, data)} end)
  end

  defp update_notification_statuses_schema do
    Zoi.object(%{
      intent: Zoi.literal("update_notification_statuses"),
      notification_ids: Zoi.list(Zoi.string()),
      status:
        Zoi.enum(["acknowledged", "resolved"])
        |> Zoi.transform(&atomize_status/1),
      reason: Zoi.nullish(Zoi.string())
    })
    |> Zoi.transform(fn data -> {:ok, struct!(UpdateNotificationStatuses, data)} end)
  end

  defp produce_insight_schema do
    Zoi.object(%{
      intent: Zoi.literal("produce_insight"),
      notification_ids: Zoi.list(Zoi.string()),
      correlation_type:
        Zoi.enum(["temporal", "causal", "symptomatic"])
        |> Zoi.transform(&atomize_correlation_type/1),
      summary: Zoi.string(),
      matched_observations: Zoi.list(Zoi.string()),
      hypothesis_grounded: Zoi.boolean(),
      root_cause_hypothesis: Zoi.nullish(Zoi.string()),
      confidence:
        Zoi.enum(["high", "medium", "low"])
        |> Zoi.transform(&atomize_confidence/1)
    })
    |> Zoi.transform(fn data -> {:ok, struct!(ProduceInsight, data)} end)
  end

  defp done_schema do
    Zoi.object(%{intent: Zoi.literal("done")})
    |> Zoi.transform(fn data -> {:ok, struct!(Done, data)} end)
  end

  defp think_schema do
    Zoi.object(%{
      intent: Zoi.literal("think"),
      thought: Zoi.string()
    })
    |> Zoi.transform(fn data -> {:ok, struct!(Think, data)} end)
  end

  defp invoke_operators_schema do
    Zoi.object(%{
      intent: Zoi.literal("invoke_operators"),
      skills: Zoi.list(Zoi.string()),
      context: Zoi.nullish(Zoi.string())
    })
    |> Zoi.transform(fn data -> {:ok, struct!(InvokeOperators, data)} end)
  end

  defp message_operator_schema do
    Zoi.object(%{
      intent: Zoi.literal("message_operator"),
      skill: Zoi.string(),
      message: Zoi.string()
    })
    |> Zoi.transform(fn data -> {:ok, struct!(MessageOperator, data)} end)
  end

  defp get_operator_statuses_schema do
    Zoi.object(%{intent: Zoi.literal("get_operator_statuses")})
    |> Zoi.transform(fn data -> {:ok, struct!(GetOperatorStatuses, data)} end)
  end

  defp wait_schema do
    Zoi.object(%{
      intent: Zoi.literal("wait"),
      ms: Zoi.integer()
    })
    |> Zoi.transform(fn data -> {:ok, struct!(Wait, data)} end)
  end

  defp atomize_status("unread"), do: {:ok, :unread}
  defp atomize_status("acknowledged"), do: {:ok, :acknowledged}
  defp atomize_status("resolved"), do: {:ok, :resolved}
  defp atomize_status("all"), do: {:ok, nil}

  defp atomize_correlation_type("temporal"), do: {:ok, :temporal}
  defp atomize_correlation_type("causal"), do: {:ok, :causal}
  defp atomize_correlation_type("symptomatic"), do: {:ok, :symptomatic}

  defp atomize_confidence("high"), do: {:ok, :high}
  defp atomize_confidence("medium"), do: {:ok, :medium}
  defp atomize_confidence("low"), do: {:ok, :low}
end
