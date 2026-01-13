defmodule Beamlens.Operator.Supervisor do
  @moduledoc """
  DynamicSupervisor for operator processes.

  Starts and supervises operator processes based on configuration.
  Each operator runs a continuous LLM-driven loop.

  ## Configuration

      config :beamlens,
        operators: [
          :beam,
          [name: :custom, skill: MyApp.Skill.Custom]
        ]

  ## Operator Specifications

  Operators can be specified in two forms:

    * `:skill` - Uses built-in skill module (e.g., `:beam` → `Beamlens.Skill.Beam`)
    * `[name: atom, skill: module, ...]` - Custom skill module with options

  ## Operator Options

    * `:name` - Required. Atom identifier for the operator
    * `:skill` - Required. Module implementing `Beamlens.Skill`
    * `:mode` - `:continuous` or `:on_demand` (default: `:continuous`)
    * `:compaction_max_tokens` - Token threshold before compaction (default: 50,000)
    * `:compaction_keep_last` - Messages to keep after compaction (default: 5)

  For one-shot analysis instead of continuous monitoring, use `Beamlens.Operator.run/3`.

  ## Example with Compaction

      config :beamlens,
        operators: [
          :beam,
          [name: :ets, skill: Beamlens.Skill.Ets,
           compaction_max_tokens: 100_000,
           compaction_keep_last: 10]
        ]
  """

  use DynamicSupervisor

  alias Beamlens.Operator
  alias Beamlens.Skill.{Beam, Ets, Gc, Logger, Ports, Sup, System}

  @builtin_skills %{
    beam: Beam,
    ets: Ets,
    gc: Gc,
    logger: Logger,
    ports: Ports,
    sup: Sup,
    system: System
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
          [name: skill, skill: module],
          client_registry
        )

      :error ->
        {:error, {:unknown_builtin_skill, skill}}
    end
  end

  def start_operator(supervisor, opts, client_registry) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    skill = Keyword.fetch!(opts, :skill)

    operator_opts =
      opts
      |> Keyword.drop([:name, :skill])
      |> Keyword.put_new(:mode, :continuous)
      |> Keyword.merge(
        name: via_registry(name),
        skill: skill
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
  Lists all configured operators with their status.

  Returns both running and stopped operators. Running operators include
  their full status from the Operator process, while stopped operators
  show `running: false`. All operators include `title` and `description`
  from their skill module for frontend display.
  """
  def list_operators do
    # Get running operators from registry
    running_operators =
      Registry.select(Beamlens.OperatorRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Map.new(fn {name, pid} ->
        status = Operator.status(pid)
        {name, Map.put(status, :name, name)}
      end)

    # Get all configured operator specs with skill modules
    configured_operator_specs()
    |> Enum.map(fn {name, skill_module} ->
      base_status =
        case Map.fetch(running_operators, name) do
          {:ok, status} ->
            status

          :error ->
            %{
              operator: name,
              name: name,
              running: false,
              state: :stopped,
              iteration: 0
            }
        end

      # Enrich with skill metadata
      Map.merge(base_status, %{
        title: skill_module.title(),
        description: skill_module.description()
      })
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

  @doc """
  Resolves an operator specification to {name, skill_module}.

  Handles both atom shortcuts for built-in skills and keyword list specs
  for custom skills.
  """
  def resolve_skill(skill) when is_atom(skill) do
    case Map.fetch(@builtin_skills, skill) do
      {:ok, module} -> {:ok, {skill, module}}
      :error -> {:error, {:unknown_builtin_skill, skill}}
    end
  end

  def resolve_skill(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    skill = Keyword.fetch!(opts, :skill)
    {:ok, {name, skill}}
  end

  @doc """
  Returns all configured operator names.

  This includes both built-in skills (specified as atoms) and custom skills
  (specified as keyword lists with `:name` key). Useful for discovering
  all operators that could be started, including custom skills.

  ## Example

      iex> Beamlens.Operator.Supervisor.configured_operators()
      [:beam, :ets, :my_custom_skill]

  """
  def configured_operators do
    # Read from persistent_term (set by Beamlens.Supervisor at startup)
    # Falls back to application env for backwards compatibility
    operators =
      case :persistent_term.get({Beamlens.Supervisor, :operators}, :not_found) do
        :not_found -> Application.get_env(:beamlens, :operators, [])
        ops -> ops
      end

    Enum.map(operators, &extract_operator_name/1)
  end

  defp extract_operator_name(skill) when is_atom(skill), do: skill
  defp extract_operator_name(opts) when is_list(opts), do: Keyword.fetch!(opts, :name)

  defp configured_operator_specs do
    operators =
      case :persistent_term.get({Beamlens.Supervisor, :operators}, :not_found) do
        :not_found -> Application.get_env(:beamlens, :operators, [])
        ops -> ops
      end

    Enum.map(operators, &extract_operator_spec/1)
  end

  defp extract_operator_spec(skill) when is_atom(skill) do
    {skill, Map.fetch!(@builtin_skills, skill)}
  end

  defp extract_operator_spec(opts) when is_list(opts) do
    {Keyword.fetch!(opts, :name), Keyword.fetch!(opts, :skill)}
  end

  defp via_registry(name) do
    {:via, Registry, {Beamlens.OperatorRegistry, name}}
  end
end
