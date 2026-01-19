defmodule Beamlens.Operator.Supervisor do
  @moduledoc """
  DynamicSupervisor for operator processes.

  Supervises operator processes started via `start_operator/3`.

  ## Starting Operators

      {:ok, pid} = Beamlens.Operator.Supervisor.start_operator(Beamlens.Skill.Beam)

      {:ok, pid} = Beamlens.Operator.Supervisor.start_operator(
        skill: MyApp.Skill.Custom
      )

  ## Operator Specifications

  Operators can be specified as:

    * `Module` - A module implementing `Beamlens.Skill` behaviour
    * `[skill: module, ...]` - Keyword list with skill module and options

  ## Operator Options

    * `:skill` - Required. Module implementing `Beamlens.Skill`
    * `:compaction_max_tokens` - Token threshold before compaction (default: 50,000)
    * `:compaction_keep_last` - Messages to keep after compaction (default: 5)

  For one-shot analysis, use `Beamlens.Operator.run/2`.
  """

  use DynamicSupervisor

  alias Beamlens.Operator

  @builtin_skill_modules [
    Beamlens.Skill.Beam,
    Beamlens.Skill.Ets,
    Beamlens.Skill.Gc,
    Beamlens.Skill.Logger,
    Beamlens.Skill.Ports,
    Beamlens.Skill.Sup,
    Beamlens.Skill.System
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a single operator under the supervisor.
  """
  def start_operator(supervisor \\ __MODULE__, spec, client_registry \\ nil)

  def start_operator(supervisor, skill_module, client_registry)
      when is_atom(skill_module) and not is_nil(skill_module) do
    case resolve_skill(skill_module) do
      {:ok, module} ->
        start_operator(supervisor, [skill: module], client_registry)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start_operator(supervisor, opts, client_registry) when is_list(opts) do
    skill = Keyword.fetch!(opts, :skill)

    operator_opts =
      opts
      |> Keyword.drop([:skill])
      |> Keyword.merge(
        name: via_registry(skill),
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
  Returns the list of builtin skill modules.
  """
  def builtin_skills do
    @builtin_skill_modules
  end

  @doc """
  Resolves a skill module, validating it implements the required callbacks.

  Returns `{:ok, module}` if valid, `{:error, reason}` otherwise.
  """
  def resolve_skill(skill_module) when is_atom(skill_module) do
    skill_module = normalize_skill(skill_module)

    if Code.ensure_loaded?(skill_module) and
         function_exported?(skill_module, :title, 0) and
         function_exported?(skill_module, :snapshot, 0) do
      {:ok, skill_module}
    else
      {:error, {:invalid_skill_module, skill_module}}
    end
  end

  def resolve_skill(opts) when is_list(opts) do
    skill = Keyword.fetch!(opts, :skill)
    resolve_skill(skill)
  end

  @doc """
  Returns all configured operator modules.

  Returns the list of skill modules configured for this application.

  ## Example

      iex> Beamlens.Operator.Supervisor.configured_operators()
      [Beamlens.Skill.Beam, Beamlens.Skill.Ets, MyApp.CustomSkill]

  """
  def configured_operators do
    Enum.map(get_operators(), &extract_skill_module/1)
  end

  defp extract_skill_module(skill_module) when is_atom(skill_module),
    do: normalize_skill(skill_module)

  defp extract_skill_module(opts) when is_list(opts),
    do: opts |> Keyword.fetch!(:skill) |> normalize_skill()

  defp configured_operator_specs do
    Enum.map(get_operators(), &extract_operator_spec/1)
  end

  defp get_operators do
    case :persistent_term.get({Beamlens.Supervisor, :operators}, :not_found) do
      :not_found -> Application.get_env(:beamlens, :operators, [])
      ops -> ops
    end
  end

  defp extract_operator_spec(skill_module) when is_atom(skill_module) do
    module = normalize_skill(skill_module)
    {module, module}
  end

  defp extract_operator_spec(opts) when is_list(opts) do
    module = opts |> Keyword.fetch!(:skill) |> normalize_skill()
    {module, module}
  end

  defp normalize_skill(:beam), do: Beamlens.Skill.Beam
  defp normalize_skill(:ets), do: Beamlens.Skill.Ets
  defp normalize_skill(:gc), do: Beamlens.Skill.Gc
  defp normalize_skill(:logger), do: Beamlens.Skill.Logger
  defp normalize_skill(:ports), do: Beamlens.Skill.Ports
  defp normalize_skill(:sup), do: Beamlens.Skill.Sup
  defp normalize_skill(:system), do: Beamlens.Skill.System
  defp normalize_skill(:exception), do: Beamlens.Skill.Exception
  defp normalize_skill(skill_module), do: skill_module

  defp via_registry(name) do
    {:via, Registry, {Beamlens.OperatorRegistry, name}}
  end
end
