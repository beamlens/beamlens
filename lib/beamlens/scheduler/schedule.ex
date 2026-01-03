defmodule Beamlens.Scheduler.Schedule do
  @moduledoc """
  Internal schedule struct for cron-based scheduling.
  """

  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @type t :: %__MODULE__{
          name: atom(),
          cron: Crontab.CronExpression.t(),
          cron_string: String.t(),
          agent_opts: keyword(),
          running: reference() | nil,
          timer_ref: reference() | nil,
          next_run_at: NaiveDateTime.t() | nil,
          last_run_at: NaiveDateTime.t() | nil,
          run_count: non_neg_integer()
        }

  defstruct [
    :name,
    :cron,
    :cron_string,
    :running,
    :timer_ref,
    :next_run_at,
    :last_run_at,
    agent_opts: [],
    run_count: 0
  ]

  @doc """
  Parse schedule config. Returns `{:ok, schedule}` or `{:error, reason}`.

  ## Options

    * `:name` - (required) atom identifier for the schedule
    * `:cron` - (required) cron expression string
    * `:agent_opts` - (optional) agent options to merge with global opts
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    name = Keyword.fetch!(opts, :name)
    cron_string = Keyword.fetch!(opts, :cron)
    agent_opts = Keyword.get(opts, :agent_opts, [])

    case Parser.parse(cron_string) do
      {:ok, cron} ->
        schedule = %__MODULE__{
          name: name,
          cron: cron,
          cron_string: cron_string,
          agent_opts: agent_opts,
          next_run_at: compute_next_run(cron)
        }

        {:ok, schedule}

      {:error, reason} ->
        {:error, {:invalid_cron, name, reason}}
    end
  end

  @doc """
  Compute next run time from cron expression.

  Accepts optional `now` parameter for testability.
  """
  @spec compute_next_run(Crontab.CronExpression.t(), NaiveDateTime.t()) :: NaiveDateTime.t()
  def compute_next_run(cron, now \\ NaiveDateTime.utc_now()) do
    {:ok, next} = Scheduler.get_next_run_date(cron, now)
    next
  end

  # Maximum timer delay (~49.7 days) due to Erlang's 32-bit signed integer limit
  @max_timer_ms 2_147_483_647

  @doc """
  Milliseconds until next run.

  Returns `{ms, :exact | :clamped}` tuple. When the delay exceeds ~49 days,
  the value is clamped to the maximum safe timer value.
  """
  @spec ms_until_next_run(t()) :: {non_neg_integer(), :exact | :clamped}
  def ms_until_next_run(%__MODULE__{next_run_at: next_run_at}) do
    now = NaiveDateTime.utc_now()
    diff_ms = NaiveDateTime.diff(next_run_at, now, :millisecond) |> max(0)

    if diff_ms > @max_timer_ms do
      {@max_timer_ms, :clamped}
    else
      {diff_ms, :exact}
    end
  end

  @doc """
  Sanitized map for public API.

  Hides internal refs, exposes `running?` boolean.
  """
  @spec to_public_map(t()) :: map()
  def to_public_map(%__MODULE__{} = s) do
    %{
      name: s.name,
      cron: s.cron_string,
      next_run_at: s.next_run_at,
      last_run_at: s.last_run_at,
      run_count: s.run_count,
      running?: s.running != nil
    }
  end
end
