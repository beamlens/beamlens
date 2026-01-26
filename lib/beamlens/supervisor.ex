defmodule Beamlens.Supervisor do
  @moduledoc """
  Main supervisor for beamlens.

  Supervises the following components:

    * `Beamlens.TaskSupervisor` - For async tasks (used by operators/coordinator for LLM calls)
    * `Beamlens.OperatorRegistry` - Registry for operator processes
    * `Beamlens.Skill.Logger.LogStore` - Log buffer
    * `Beamlens.Skill.Exception.ExceptionStore` - Exception buffer (only if Tower is installed)
    * `Beamlens.Skill.VmEvents.EventStore` - System monitor event buffer (only if VmEvents skill is enabled)
    * `Beamlens.Skill.Ets.GrowthStore` - ETS growth tracking buffer (only if Ets skill is enabled)
    * `Beamlens.Skill.Beam.AtomStore` - Atom growth tracking buffer (only if Beam skill is enabled)
    * `Beamlens.Skill.Tracer` - Function tracer GenServer (only if Tracer skill is enabled)
    * `Beamlens.Skill.Anomaly.Supervisor` - Statistical anomaly detection (only if Anomaly skill is enabled)
    * `Beamlens.Coordinator` - Static coordinator process
    * `Beamlens.Operator.Supervisor` - Supervisor for static operator processes

  ## Configuration

  Skills can be specified as modules or `{module, opts}` tuples for collocated configuration:

      children = [
        {Beamlens,
         skills: [
           Beamlens.Skill.Beam,
           {Beamlens.Skill.Anomaly, [
             collection_interval_ms: :timer.seconds(30),
             learning_duration_ms: :timer.hours(2),
             z_threshold: 3.0,
             consecutive_required: 3,
             cooldown_ms: :timer.minutes(15)
           ]}
         ]}
      ]

  ## Anomaly Skill Configuration

  The Anomaly skill is enabled by default and starts automatically with builtin skills.
  To customize its configuration, use collocated options:

      children = [
        {Beamlens,
         skills: [
           Beamlens.Skill.Beam,
           {Beamlens.Skill.Anomaly, [
             collection_interval_ms: :timer.seconds(30),
             learning_duration_ms: :timer.hours(2)
           ]}
         ]}
      ]

  To disable the Anomaly skill explicitly:

      children = [
        {Beamlens,
         skills: [
           Beamlens.Skill.Beam,
           {Beamlens.Skill.Anomaly, enabled: false}
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

  @doc """
  Returns the list of registered skill modules.

  Returns an empty list if Beamlens hasn't been started yet.
  """
  def registered_skills do
    :persistent_term.get({__MODULE__, :skills}, [])
  end

  @impl true
  def init(opts) do
    skills = opts |> Keyword.get(:skills) |> resolve_skills()
    client_registry = Keyword.get(opts, :client_registry)

    {skill_modules, skill_configs} = parse_skills(skills)
    :persistent_term.put({__MODULE__, :skills}, skill_modules)

    children =
      [
        {Task.Supervisor, name: Beamlens.TaskSupervisor},
        {Registry, keys: :unique, name: Beamlens.OperatorRegistry},
        LogStore,
        exception_store_child(),
        system_monitor_child(skill_modules),
        ets_growth_store_child(skill_modules),
        beam_atom_store_child(skill_modules),
        tracer_child(skill_modules),
        monitor_child(skill_modules, skill_configs),
        coordinator_child(client_registry),
        {OperatorSupervisor, skills: skill_modules, client_registry: client_registry}
      ]
      |> List.flatten()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp parse_skills(skills) do
    Enum.reduce(skills, {[], %{}}, fn
      skill, {modules, configs} when is_atom(skill) ->
        {[skill | modules], configs}

      {skill, opts}, {modules, configs} when is_atom(skill) and is_list(opts) ->
        {[skill | modules], Map.put(configs, skill, opts)}
    end)
    |> then(fn {modules, configs} -> {Enum.reverse(modules), configs} end)
  end

  defp resolve_skills(nil), do: Beamlens.Operator.Supervisor.builtin_skills()
  defp resolve_skills([]), do: Beamlens.Operator.Supervisor.builtin_skills()
  defp resolve_skills(skills), do: skills

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
    if Beamlens.Skill.VmEvents in skills do
      [Beamlens.Skill.VmEvents.EventStore]
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

  defp tracer_child(skills) do
    if Beamlens.Skill.Tracer in skills do
      [Beamlens.Skill.Tracer]
    else
      []
    end
  end

  defp monitor_child(skills, skill_configs) do
    if Beamlens.Skill.Anomaly in skills do
      monitor_opts = Map.get(skill_configs, Beamlens.Skill.Anomaly, [])
      enabled = Keyword.get(monitor_opts, :enabled, true)

      if enabled do
        [{Beamlens.Skill.Anomaly.Supervisor, monitor_opts}]
      else
        []
      end
    else
      []
    end
  end
end
