defmodule Beamlens.Operator.Supervisor do
  @moduledoc """
  DynamicSupervisor for operator processes.

  Starts and supervises operator processes based on configuration.
  Each operator runs a continuous LLM-driven loop.

  ## Configuration

      config :beamlens,
        operators: [
          :beam,
          [name: :custom, skill_module: MyApp.Skill.Custom]
        ]

  ## Operator Specifications

  Operators can be specified in two forms:

    * `:skill` - Uses built-in skill module (e.g., `:beam` → `Beamlens.Skill.Beam`)
    * `[name: atom, skill_module: module, ...]` - Custom skill module with options

  ## Operator Options

    * `:name` - Required. Atom identifier for the operator
    * `:skill_module` - Required. Module implementing `Beamlens.Skill`
    * `:compaction_max_tokens` - Token threshold before compaction (default: 50,000)
    * `:compaction_keep_last` - Messages to keep after compaction (default: 5)

  ## Example with Compaction

      config :beamlens,
        operators: [
          :beam,
          [name: :ets, skill_module: Beamlens.Skill.Ets,
           compaction_max_tokens: 100_000,
           compaction_keep_last: 10]
        ]
  """

  use DynamicSupervisor

  alias Beamlens.Operator
  alias Beamlens.Skill.{Beam, Ets, Gc, Logger, Ports, Sup}

  @builtin_skills %{
    beam: Beam,
    ets: Ets,
    gc: Gc,
    logger: Logger,
    ports: Ports,
    sup: Sup
  }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts all configured operators with the given options.

  Called by the parent supervisor after OperatorSupervisor is started.
  """
  def start_operators_with_opts(supervisor \\ __MODULE__, operators, client_registry) do
    Enum.each(operators, &start_operator(supervisor, &1, client_registry))
  end

  @doc """
  Starts all configured operators.

  Called after the supervisor is started to spawn operator processes.
  """
  def start_operators(supervisor \\ __MODULE__) do
    operators = Application.get_env(:beamlens, :operators, [])

    Enum.map(operators, fn spec ->
      start_operator(supervisor, spec)
    end)
  end

  @doc """
  Starts a single operator under the supervisor.
  """
  def start_operator(supervisor \\ __MODULE__, spec, client_registry \\ nil)

  def start_operator(supervisor, skill, client_registry) when is_atom(skill) do
    case Map.fetch(@builtin_skills, skill) do
      {:ok, module} ->
        start_operator(
          supervisor,
          [name: skill, skill_module: module],
          client_registry
        )

      :error ->
        {:error, {:unknown_builtin_skill, skill}}
    end
  end

  def start_operator(supervisor, opts, client_registry) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    skill_module = Keyword.fetch!(opts, :skill_module)

    operator_opts =
      opts
      |> Keyword.drop([:name, :skill_module])
      |> Keyword.merge(
        name: via_registry(name),
        skill_module: skill_module
      )

    operator_opts =
      if client_registry do
        Keyword.put(operator_opts, :client_registry, client_registry)
      else
        operator_opts
      end

    DynamicSupervisor.start_child(supervisor, {Operator, operator_opts})
  end

  @doc """
  Stops an operator by name.
  """
  def stop_operator(supervisor \\ __MODULE__, name) do
    case Registry.lookup(Beamlens.OperatorRegistry, name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(supervisor, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists all running operators with their status.
  """
  def list_operators do
    Registry.select(Beamlens.OperatorRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {name, pid} ->
      status = Operator.status(pid)
      Map.put(status, :name, name)
    end)
  end

  @doc """
  Gets the status of a specific operator.
  """
  def operator_status(name) do
    case Registry.lookup(Beamlens.OperatorRegistry, name) do
      [{pid, _}] ->
        {:ok, Operator.status(pid)}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns the list of builtin skill names.
  """
  def builtin_skills do
    Map.keys(@builtin_skills)
  end

  defp via_registry(name) do
    {:via, Registry, {Beamlens.OperatorRegistry, name}}
  end
end
