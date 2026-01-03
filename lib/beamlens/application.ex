defmodule Beamlens.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Beamlens.TaskSupervisor},
      {Beamlens.Scheduler, scheduler_opts()}
    ]

    opts = [strategy: :one_for_one, name: Beamlens.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp scheduler_opts do
    [
      schedules: Application.get_env(:beamlens, :schedules, []),
      agent_opts: Application.get_env(:beamlens, :agent_opts, [])
    ]
  end
end
