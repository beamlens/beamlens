defmodule Beamlens.Supervisor do
  @moduledoc """
  Main supervisor for beamlens.

  Supervises the following components:

    * `Beamlens.TaskSupervisor` - For async tasks (used by operators/coordinator for LLM calls)
    * `Beamlens.OperatorRegistry` - Registry for operator processes
    * `Beamlens.Skill.Logger.LogStore` - Log buffer
    * `Beamlens.Skill.Exception.ExceptionStore` - Exception buffer (only if Tower is installed)
    * `Beamlens.Coordinator` - Static coordinator process
    * `Beamlens.Operator.Supervisor` - Supervisor for static operator processes

  ## Configuration

      children = [
        {Beamlens, skills: [Beamlens.Skill.Beam, Beamlens.Skill.Ets]}
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
    :persistent_term.put({__MODULE__, :skills}, skills)

    children =
      [
        {Task.Supervisor, name: Beamlens.TaskSupervisor},
        {Registry, keys: :unique, name: Beamlens.OperatorRegistry},
        LogStore,
        exception_store_child(),
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
end
