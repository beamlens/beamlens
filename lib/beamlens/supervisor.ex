defmodule Beamlens.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    schedules = opts |> Keyword.get(:schedules, []) |> normalize_schedules()
    scheduler_opts = Keyword.put(opts, :schedules, schedules)

    children = [
      {Task.Supervisor, name: Beamlens.TaskSupervisor},
      {Beamlens.Scheduler, scheduler_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Normalize schedule configs to keyword lists
  # Supports tuple shorthand: {:name, "cron"} -> [name: :name, cron: "cron"]
  defp normalize_schedules(schedules) do
    Enum.map(schedules, &normalize_schedule/1)
  end

  defp normalize_schedule({name, cron}) when is_atom(name) and is_binary(cron) do
    [name: name, cron: cron]
  end

  defp normalize_schedule(config) when is_list(config) do
    config
  end
end
