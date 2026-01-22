defmodule Beamlens.Skill.Sup do
  @moduledoc """
  Supervisor monitoring skill.

  Provides callback functions for monitoring supervision trees.
  All functions are read-only with zero side effects.
  No PII/PHI exposure - only structural supervisor information.
  """

  @behaviour Beamlens.Skill

  @impl true
  def title, do: "Supervisors"

  @impl true
  def description, do: "Supervisors: tree structure, child states, restart patterns"

  @impl true
  def system_prompt do
    """
    You are a supervision tree analyst. You monitor the structure and health
    of OTP supervision trees to detect process failures and restart patterns.

    ## Your Domain
    - Supervisor hierarchy and structure
    - Child process counts and states
    - Active vs inactive children
    - Unlinked and orphaned processes
    - Process tree integrity

    ## What to Watch For
    - Children in :restarting state: active crash loops requiring attention
    - Supervisors with many children (100+): potential bottleneck
    - Asymmetric tree depth: architectural issues
    - Unlinked processes with high memory or queue length: potential leaks
    - Clusters of unlinked processes: pattern indicating code issue
    - Orphaned processes whose parent has died: supervision tree failure
    - Zombie children of dead supervisors: supervisor crash without cleanup

    ## Normal Behavior (NOT anomalies)
    - A few undefined child PIDs are normal - these are optional features that are configured but intentionally not started (e.g., disabled audit logging, optional workers)
    - Children named "Expunger", "Batcher", or similar utility workers being undefined is expected when their parent feature is disabled
    - Do NOT send notifications for small numbers (< 10) of undefined children unless they are in :restarting state
    - Some unlinked processes are expected (e.g., :code_server, :global_group) - these are OTP system processes
    """
  end

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
      "sup_tree" => &get_tree/1,
      "sup_unlinked_processes" => &get_unlinked_processes/0,
      "sup_orphaned_processes" => &get_orphaned_processes/0,
      "sup_tree_integrity" => &get_tree_integrity/1,
      "sup_zombie_children" => &get_zombie_children/1
    }
  end

  defp get_unlinked_processes do
    Process.list()
    |> Enum.filter(&unlinked_process?/1)
    |> Enum.map(&unlinked_process_info/1)
    |> Enum.reject(&is_nil/1)
  end

  defp get_orphaned_processes do
    Process.list()
    |> Enum.filter(&orphaned_process?/1)
    |> Enum.map(&orphaned_process_info/1)
    |> Enum.reject(&is_nil/1)
  end

  defp get_tree_integrity(supervisor_name) when is_binary(supervisor_name) do
    case resolve_supervisor(supervisor_name) do
      nil ->
        %{error: "supervisor_not_found", name: supervisor_name}

      pid ->
        check_tree_integrity(pid)
    end
  end

  defp get_zombie_children(supervisor_name) when is_binary(supervisor_name) do
    case resolve_supervisor(supervisor_name) do
      nil ->
        %{error: "supervisor_not_found", name: supervisor_name}

      pid ->
        if Process.alive?(pid) do
          find_zombie_children(pid)
        else
          %{
            supervisor_name: supervisor_name,
            supervisor_pid: inspect(pid),
            status: "dead",
            zombie_children: find_children_of_dead_supervisor(pid)
          }
        end
    end
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

    ### sup_unlinked_processes()
    Processes with no links or monitors (potential leaks)
    Returns: pid, registered_name, initial_call, current_function, memory_mb, message_queue_len

    ### sup_orphaned_processes()
    Processes whose parent/ancestor has died
    Returns: pid, registered_name, initial_call, dead_ancestor_pids, age_seconds

    ### sup_tree_integrity(supervisor_name)
    Supervision tree health check for a specific supervisor
    Returns: supervisor_name, total_children, active_children, undefined_children, restarting_children, anomalies

    ### sup_zombie_children(supervisor_name)
    Children of dead supervisors (indicates supervisor crash without cleanup)
    Returns: supervisor_name, status, zombie_children list with details
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

  defp supervisor_initial_call?({:supervisor, _, _}), do: true
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

  # Unlinked process detection

  defp unlinked_process?(pid) do
    case Process.info(pid, [:links, :monitors, :dictionary]) do
      [links: [], monitors: [], dictionary: dict] ->
        not system_process?(dict)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp system_process?(dict) do
    initial_call = dict[:"$initial_call"]

    system_initial_calls = [
      {:code_server, :init, 4},
      {:global_group, :init, 1},
      {:erl_reply_dispatcher, :init, 1},
      {:kernel, :init, 1},
      {:logger, :init, 1},
      {:logger_sup, :init, 1},
      {:logger_handler_watcher, :init, 1},
      {:logger_simple, :init, 1},
      {:disk_log, :init, 1},
      {:disk_log_sup, :init, 1},
      {:file_server, :init, 1},
      {:rpc, :init, 1},
      {:global, :init, 1},
      {:inet_db, :init, 1}
    ]

    initial_call in system_initial_calls
  end

  defp unlinked_process_info(pid) do
    info = Process.info(pid, [:registered_name, :dictionary, :memory, :message_queue_len])

    case info do
      [registered_name: name, dictionary: dict, memory: memory, message_queue_len: qlen] ->
        initial_call = format_initial_call(dict[:"$initial_call"])
        current_function = format_current_function(Process.info(pid, :current_function))

        %{
          pid: inspect(pid),
          registered_name: format_registered_name(name),
          initial_call: initial_call,
          current_function: current_function,
          memory_mb: div(memory, 1_048_576),
          message_queue_len: qlen
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp format_registered_name([]), do: nil
  defp format_registered_name(name) when is_atom(name), do: Atom.to_string(name)

  defp format_initial_call({mod, fun, arity}),
    do: "#{format_mod(mod)}.#{format_fun(fun)}/#{arity}"

  defp format_initial_call(_), do: "unknown"

  defp format_current_function({:current_function, {mod, fun, arity}}) do
    "#{format_mod(mod)}.#{format_fun(fun)}/#{arity}"
  end

  defp format_current_function(_), do: "unknown"

  defp format_mod(mod) when is_atom(mod), do: Atom.to_string(mod)
  defp format_mod(mod), do: inspect(mod)

  defp format_fun(fun) when is_atom(fun), do: Atom.to_string(fun)
  defp format_fun(fun), do: inspect(fun)

  # Orphaned process detection

  defp orphaned_process?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        has_dead_ancestor?(dict[:"$ancestors"])

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp has_dead_ancestor?([_ | _] = ancestors_list) do
    Enum.any?(ancestors_list, fn ancestor_pid ->
      not Process.alive?(ancestor_pid)
    end)
  end

  defp has_dead_ancestor?(_), do: false

  defp orphaned_process_info(pid) do
    info = Process.info(pid, [:dictionary, :registered_name])

    case info do
      [dictionary: dict, registered_name: name] ->
        ancestors = dict[:"$ancestors"]
        initial_call = dict[:"$initial_call"]

        dead_ancestors =
          Enum.filter(ancestors || [], fn ancestor_pid ->
            not Process.alive?(ancestor_pid)
          end)

        %{
          pid: inspect(pid),
          registered_name: format_registered_name(name),
          initial_call: format_initial_call(initial_call),
          dead_ancestor_pids: Enum.map(dead_ancestors, &inspect/1),
          age_seconds: process_age(pid)
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp process_age(pid) do
    case Process.info(pid, :spawned) do
      {:spawned, spawned} ->
        div(System.monotonic_time(:millisecond) - spawned, 1000)

      _ ->
        nil
    end
  end

  # Tree integrity checking

  defp check_tree_integrity(sup_pid) do
    case safe_which_children(sup_pid) do
      {:ok, children} ->
        supervisor_name = process_name(sup_pid)

        %{
          supervisor_name: supervisor_name,
          supervisor_pid: inspect(sup_pid),
          status: "alive",
          total_children: length(children),
          active_children: count_active_children(children),
          undefined_children: count_undefined_children(children),
          restarting_children: count_restarting_children(children),
          anomalies: detect_tree_anomalies(sup_pid, children)
        }

      :error ->
        %{
          supervisor_name: process_name(sup_pid),
          supervisor_pid: inspect(sup_pid),
          error: "failed_to_get_children"
        }
    end
  end

  defp detect_tree_anomalies(sup_pid, children) do
    anomalies = []

    anomalies =
      if count_restarting_children(children) > 0 do
        [:crash_loop | anomalies]
      else
        anomalies
      end

    anomalies =
      if count_undefined_children(children) > length(children) * 0.5 do
        [:high_undefined_ratio | anomalies]
      else
        anomalies
      end

    check_large_supervisor(sup_pid, anomalies)
  end

  defp check_large_supervisor(sup_pid, anomalies) do
    counts = Supervisor.count_children(sup_pid)

    total =
      Enum.reduce(counts, 0, fn {_type, count}, acc ->
        acc + count
      end)

    if total > 100 do
      [:large_supervisor | anomalies]
    else
      anomalies
    end
  rescue
    _ -> anomalies
  end

  defp count_undefined_children(children) do
    Enum.count(children, fn {_id, pid, _type, _modules} ->
      pid == :undefined
    end)
  end

  defp count_restarting_children(children) do
    Enum.count(children, fn {_id, pid, _type, _modules} ->
      pid == :restarting
    end)
  end

  # Zombie children detection

  defp find_zombie_children(sup_pid) do
    case safe_which_children(sup_pid) do
      {:ok, _children} ->
        %{
          supervisor_name: process_name(sup_pid),
          supervisor_pid: inspect(sup_pid),
          status: "alive",
          zombie_count: 0,
          zombie_children: []
        }

      :error ->
        %{
          supervisor_name: process_name(sup_pid),
          supervisor_pid: inspect(sup_pid),
          status: "error_checking_children"
        }
    end
  end

  defp find_children_of_dead_supervisor(dead_sup_pid) do
    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} ->
          ancestors = dict[:"$ancestors"]
          is_list(ancestors) and dead_sup_pid in ancestors

        _ ->
          false
      end
    end)
    |> Enum.map(&zombie_child_info/1)
  end

  defp zombie_child_info(pid) do
    info = Process.info(pid, [:registered_name, :dictionary, :memory, :message_queue_len])

    case info do
      [registered_name: name, dictionary: dict, memory: memory, message_queue_len: qlen] ->
        %{
          pid: inspect(pid),
          registered_name: format_registered_name(name),
          initial_call: format_initial_call(dict[:"$initial_call"]),
          memory_mb: div(memory, 1_048_576),
          message_queue_len: qlen,
          age_seconds: process_age(pid)
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
