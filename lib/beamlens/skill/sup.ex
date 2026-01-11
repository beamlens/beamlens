defmodule Beamlens.Skill.Sup do
  @moduledoc """
  Supervisor monitoring skill.

  Provides callback functions for monitoring supervision trees.
  All functions are read-only with zero side effects.
  No PII/PHI exposure - only structural supervisor information.
  """

  @behaviour Beamlens.Skill

  @impl true
  def id, do: :sup

  @impl true
  def snapshot do
    supervisors = find_supervisors()

    %{
      supervisor_count: length(supervisors),
      total_children: count_all_children(supervisors)
    }
  end

  @impl true
  def callbacks do
    %{
      "sup_list" => &list_supervisors/0,
      "sup_children" => &get_children/1,
      "sup_tree" => &get_tree/1
    }
  end

  @impl true
  def callback_docs do
    """
    ### sup_list()
    All supervisors with: name, pid, child_count, active_children

    ### sup_children(supervisor_name)
    Direct children of a supervisor: id, pid, type

    ### sup_tree(supervisor_name)
    Full supervision tree (recursive): name, pid, children (nested)
    """
  end

  defp list_supervisors do
    find_supervisors()
    |> Enum.map(&supervisor_summary/1)
    |> Enum.reject(&is_nil/1)
  end

  defp get_children(supervisor_name) when is_binary(supervisor_name) do
    case resolve_supervisor(supervisor_name) do
      nil ->
        %{error: "supervisor_not_found", name: supervisor_name}

      pid ->
        children_info(pid)
    end
  end

  defp get_tree(supervisor_name) when is_binary(supervisor_name) do
    case resolve_supervisor(supervisor_name) do
      nil ->
        %{error: "supervisor_not_found", name: supervisor_name}

      pid ->
        build_tree(pid, 3)
    end
  end

  defp find_supervisors do
    Process.list()
    |> Enum.filter(&supervisor?/1)
  end

  defp supervisor?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        initial_call = dict[:"$initial_call"]
        supervisor_initial_call?(initial_call)

      nil ->
        false
    end
  end

  defp supervisor_initial_call?({Supervisor, :init, _}), do: true
  defp supervisor_initial_call?({:supervisor, :init, _}), do: true
  defp supervisor_initial_call?(_), do: false

  defp supervisor_summary(pid) do
    case safe_which_children(pid) do
      {:ok, children} ->
        %{
          name: process_name(pid),
          pid: inspect(pid),
          child_count: length(children),
          active_children: count_active_children(children)
        }

      :error ->
        nil
    end
  end

  defp children_info(pid) do
    case safe_which_children(pid) do
      {:ok, children} ->
        Enum.map(children, &format_child/1)

      :error ->
        %{error: "failed_to_get_children"}
    end
  end

  defp build_tree(pid, max_depth) when max_depth <= 0 do
    %{
      name: process_name(pid),
      pid: inspect(pid),
      truncated: true
    }
  end

  defp build_tree(pid, max_depth) do
    case safe_which_children(pid) do
      {:ok, children} ->
        %{
          name: process_name(pid),
          pid: inspect(pid),
          children: Enum.map(children, &build_child_tree(&1, max_depth - 1))
        }

      :error ->
        %{
          name: process_name(pid),
          pid: inspect(pid),
          error: "failed_to_get_children"
        }
    end
  end

  defp build_child_tree({id, pid, :supervisor, _modules}, max_depth) when is_pid(pid) do
    tree = build_tree(pid, max_depth)
    Map.put(tree, :id, format_id(id))
  end

  defp build_child_tree({id, pid, type, _modules}, _max_depth) do
    %{
      id: format_id(id),
      pid: format_pid(pid),
      type: type
    }
  end

  defp format_child({id, pid, type, _modules}) do
    %{
      id: format_id(id),
      pid: format_pid(pid),
      type: type
    }
  end

  defp safe_which_children(pid) do
    {:ok, Supervisor.which_children(pid)}
  catch
    :exit, _ -> :error
  end

  defp resolve_supervisor(name_string) do
    atom_name = string_to_existing_atom(name_string)

    if atom_name do
      case Process.whereis(atom_name) do
        nil -> find_supervisor_by_name(name_string)
        pid -> pid
      end
    else
      find_supervisor_by_name(name_string)
    end
  end

  defp string_to_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  defp find_supervisor_by_name(name_string) do
    find_supervisors()
    |> Enum.find(fn pid -> process_name(pid) == name_string end)
  end

  defp process_name(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> Atom.to_string(name)
      _ -> inspect(pid)
    end
  end

  defp count_all_children(supervisors) do
    Enum.reduce(supervisors, 0, fn pid, acc ->
      case safe_which_children(pid) do
        {:ok, children} -> acc + length(children)
        :error -> acc
      end
    end)
  end

  defp count_active_children(children) do
    Enum.count(children, fn {_id, pid, _type, _modules} ->
      is_pid(pid)
    end)
  end

  defp format_id(id) when is_atom(id), do: Atom.to_string(id)
  defp format_id(id), do: inspect(id)

  defp format_pid(pid) when is_pid(pid), do: inspect(pid)
  defp format_pid(:undefined), do: "undefined"
  defp format_pid(:restarting), do: "restarting"
  defp format_pid(other), do: inspect(other)
end
