defmodule Beamlens.Supervisor do
  @moduledoc """
  Main supervisor for beamlens.

  Supervises the following components:

    * `Beamlens.TaskSupervisor` - For async tasks (used by operators/coordinator for LLM calls)
    * `Beamlens.OperatorRegistry` - Registry for operator processes
    * `Beamlens.Skill.Logger.LogStore` - Log buffer
    * `Beamlens.Skill.Exception.ExceptionStore` - Exception buffer (only if Tower is installed)
    * `Beamlens.Skill.SystemMonitor.EventStore` - System monitor event buffer (only if SystemMonitor skill is enabled)
    * `Beamlens.Skill.Ets.GrowthStore` - ETS growth tracking buffer (only if Ets skill is enabled)
    * `Beamlens.Skill.Beam.AtomStore` - Atom growth tracking buffer (only if Beam skill is enabled)
    * `Beamlens.Skill.Monitor.Supervisor` - Statistical anomaly detection (only if Monitor skill is enabled and configured with enabled: true)
    * `Beamlens.Coordinator` - Static coordinator process
    * `Beamlens.Operator.Supervisor` - Supervisor for static operator processes

  ## Configuration

      children = [
        {Beamlens, skills: [Beamlens.Skill.Beam, Beamlens.Skill.Ets]}
      ]

  ## Monitor Skill Configuration

  The Monitor skill is opt-in and requires explicit configuration:

      children = [
        {Beamlens,
         skills: [Beamlens.Skill.Beam, Beamlens.Skill.Monitor],
         monitor: [
           enabled: true,
           collection_interval_ms: :timer.seconds(30),
           learning_duration_ms: :timer.hours(2),
           z_threshold: 3.0,
           consecutive_required: 3,
           cooldown_ms: :timer.minutes(15)
         ]}
      ]

  ## Advanced Deployments

  For custom supervision trees, use the building blocks directly.
  See `docs/deployment.md` for examples.
  """

  use Supervisor

  alias Beamlens.Coordinator
  alias Beamlens.Operator.Supervisor, as: OperatorSupervisor
  alias Beamlens.Skill.Logger.LogStore

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    skills = Keyword.get(opts, :skills, Beamlens.Operator.Supervisor.builtin_skills())
    client_registry = Keyword.get(opts, :client_registry)
    monitor_opts = Keyword.get(opts, :monitor, [])
    :persistent_term.put({__MODULE__, :skills}, skills)

    children =
      [
        {Task.Supervisor, name: Beamlens.TaskSupervisor},
        {Registry, keys: :unique, name: Beamlens.OperatorRegistry},
        LogStore,
        exception_store_child(),
        system_monitor_child(skills),
        ets_growth_store_child(skills),
        beam_atom_store_child(skills),
        monitor_child(skills, monitor_opts),
        coordinator_child(client_registry),
        {OperatorSupervisor, skills: skills, client_registry: client_registry}
      ]
      |> List.flatten()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp coordinator_child(client_registry) do
    opts = [name: Coordinator]

    opts =
      if client_registry do
        Keyword.put(opts, :client_registry, client_registry)
      else
        opts
      end

    {Coordinator, opts}
  end

  defp exception_store_child do
    if Code.ensure_loaded?(Beamlens.Skill.Exception.ExceptionStore) do
      [Beamlens.Skill.Exception.ExceptionStore]
    else
      []
    end
  end

  defp system_monitor_child(skills) do
    if Beamlens.Skill.SystemMonitor in skills do
      [Beamlens.Skill.SystemMonitor.EventStore]
    else
      []
    end
  end

  defp ets_growth_store_child(skills) do
    if Beamlens.Skill.Ets in skills do
      [{Beamlens.Skill.Ets.GrowthStore, [name: Beamlens.Skill.Ets.GrowthStore]}]
    else
      []
    end
  end

  defp beam_atom_store_child(skills) do
    if Beamlens.Skill.Beam in skills do
      [{Beamlens.Skill.Beam.AtomStore, [name: Beamlens.Skill.Beam.AtomStore]}]
    else
      []
    end
  end

  defp monitor_child(skills, monitor_opts) do
    if Beamlens.Skill.Monitor in skills do
      enabled = Keyword.get(monitor_opts, :enabled, false)

      if enabled do
        [{Beamlens.Skill.Monitor.Supervisor, monitor_opts}]
      else
        []
      end
    else
      []
    end
  end
end
