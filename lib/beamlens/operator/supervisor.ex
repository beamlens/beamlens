defmodule Beamlens.Operator.Supervisor do
  @moduledoc """
  Supervisor for static operator processes.

  Supervises operator processes as static, always-running children.
  Operators wait in `:idle` status until invoked.

  ## Configuration

  Skills are configured via the `:skills` option. If not specified,
  all built-in skills are started by default.

      # Use built-in skills (default)
      children = [Beamlens]

      # Use specific skills only
      children = [
        {Beamlens, skills: [Beamlens.Skill.Beam, Beamlens.Skill.Ets, MyApp.CustomSkill]}
      ]

  ## Skill Specifications

  Skills can be specified as:

    * `Module` - A module implementing `Beamlens.Skill` behaviour
    * `[skill: module, ...]` - Keyword list with skill module and options

  ## Skill Options

    * `:skill` - Required. Module implementing `Beamlens.Skill`
    * `:compaction_max_tokens` - Token threshold before compaction (default: 50,000)
    * `:compaction_keep_last` - Messages to keep after compaction (default: 5)

  For one-shot analysis, use `Beamlens.Operator.run/2`.
  """

  use Supervisor

  alias Beamlens.Operator

  @builtin_skill_modules [
    Beamlens.Skill.Beam,
    Beamlens.Skill.Ets,
    Beamlens.Skill.Gc,
    Beamlens.Skill.Logger,
    Beamlens.Skill.Ports,
    Beamlens.Skill.Sup,
    Beamlens.Skill.System,
    Beamlens.Skill.SystemMonitor
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    skills = Keyword.get(opts, :skills, @builtin_skill_modules)
    client_registry = Keyword.get(opts, :client_registry)

    children =
      skills
      |> Enum.map(&build_operator_child_spec(&1, client_registry))
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_operator_child_spec(skill_module, client_registry) when is_atom(skill_module) do
    case resolve_skill(skill_module) do
      {:ok, module} ->
        build_operator_child_spec([skill: module], client_registry)

      {:error, reason} ->
        :telemetry.execute(
          [:beamlens, :operator_supervisor, :skill_resolution_failed],
          %{system_time: System.system_time()},
          %{skill: skill_module, reason: reason}
        )

        nil
    end
  end

  defp build_operator_child_spec(opts, client_registry) when is_list(opts) do
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

    Supervisor.child_spec({Operator, operator_opts}, id: skill)
  end

  @doc """
  Lists all configured operators with their status.

  All operators are now static and always running. Returns status
  from each operator process including `title` and `description`
  from their skill module for frontend display.
  """
  def list_operators do
    configured_operator_specs()
    |> Enum.map(fn {name, skill_module} ->
      base_status =
        case Registry.lookup(Beamlens.OperatorRegistry, name) do
          [{pid, _}] ->
            status = Operator.status(pid)
            Map.put(status, :name, name)

          [] ->
            %{
              operator: name,
              name: name,
              running: false,
              state: :stopped,
              iteration: 0
            }
        end

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
    Enum.map(get_skills(), &extract_skill_module/1)
  end

  defp extract_skill_module(skill_module) when is_atom(skill_module),
    do: normalize_skill(skill_module)

  defp extract_skill_module(opts) when is_list(opts),
    do: opts |> Keyword.fetch!(:skill) |> normalize_skill()

  defp configured_operator_specs do
    Enum.map(get_skills(), fn skill ->
      module = extract_skill_module(skill)
      {module, module}
    end)
  end

  defp get_skills do
    case :persistent_term.get({Beamlens.Supervisor, :skills}, :not_found) do
      :not_found -> Application.get_env(:beamlens, :skills, @builtin_skill_modules)
      skills -> skills
    end
  end

  defp normalize_skill(:beam), do: Beamlens.Skill.Beam
  defp normalize_skill(:ets), do: Beamlens.Skill.Ets
  defp normalize_skill(:gc), do: Beamlens.Skill.Gc
  defp normalize_skill(:logger), do: Beamlens.Skill.Logger
  defp normalize_skill(:ports), do: Beamlens.Skill.Ports
  defp normalize_skill(:sup), do: Beamlens.Skill.Sup
  defp normalize_skill(:system), do: Beamlens.Skill.System
  defp normalize_skill(:system_monitor), do: Beamlens.Skill.SystemMonitor
  defp normalize_skill(:exception), do: Beamlens.Skill.Exception
  defp normalize_skill(skill_module), do: skill_module

  defp via_registry(name) do
    {:via, Registry, {Beamlens.OperatorRegistry, name}}
  end
end
