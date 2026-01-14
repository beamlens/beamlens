defmodule Beamlens.Supervisor do
  @moduledoc """
  Main supervisor for beamlens.

  Supervises the following components:

    * `Beamlens.TaskSupervisor` - For async tasks
    * `Beamlens.OperatorRegistry` - Registry for operator processes
    * `Beamlens.Skill.Logger.LogStore` - Log buffer
    * `Beamlens.Skill.Exception.ExceptionStore` - Exception buffer
    * `Beamlens.Operator.Supervisor` - DynamicSupervisor for operators
    * `Beamlens.Coordinator` - Coordinator process for multi-operator analysis

  ## Configuration

      children = [
        {Beamlens, client_registry: client_registry()}
      ]

  ## Options

    * `:client_registry` - LLM client configuration

  ## Advanced Deployments

  For custom supervision trees, use the building blocks directly.
  See `docs/deployment.md` for examples.
  """

  use Supervisor

  alias Beamlens.Operator.Supervisor, as: OperatorSupervisor
  alias Beamlens.Skill.Exception.ExceptionStore
  alias Beamlens.Skill.Logger.LogStore

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    operators = Keyword.get(opts, :operators, [])
    :persistent_term.put({__MODULE__, :operators}, operators)

    children = [
      {Task.Supervisor, name: Beamlens.TaskSupervisor},
      {Registry, keys: :unique, name: Beamlens.OperatorRegistry},
      LogStore,
      ExceptionStore,
      {OperatorSupervisor, []},
      {Beamlens.Coordinator, Keyword.take(opts, [:client_registry])}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
