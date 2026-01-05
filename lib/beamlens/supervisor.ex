defmodule Beamlens.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    schedules = opts |> Keyword.get(:schedules, []) |> normalize_schedules()
    circuit_breaker_opts = Keyword.get(opts, :circuit_breaker, [])
    scheduler_opts = Keyword.put(opts, :schedules, schedules)

    children =
      [
        {Task.Supervisor, name: Beamlens.TaskSupervisor},
        maybe_circuit_breaker(circuit_breaker_opts),
        {Beamlens.Scheduler, scheduler_opts}
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_circuit_breaker(opts) do
    if Keyword.get(opts, :enabled, false) do
      {Beamlens.CircuitBreaker, Keyword.delete(opts, :enabled)}
    else
      nil
    end
  end

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
