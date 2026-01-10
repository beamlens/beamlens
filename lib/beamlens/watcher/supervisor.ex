defmodule Beamlens.Watcher.Supervisor do
  @moduledoc """
  DynamicSupervisor for watcher processes.

  Starts and supervises watcher processes based on configuration.
  Each watcher runs a continuous LLM-driven loop.

  ## Configuration

      config :beamlens,
        watchers: [
          :beam,
          [name: :custom, domain_module: MyApp.Domain.Custom]
        ]

  ## Watcher Specifications

  Watchers can be specified in two forms:

    * `:domain` - Uses built-in domain module (e.g., `:beam` → `Beamlens.Domain.Beam`)
    * `[name: atom, domain_module: module]` - Custom domain module
  """

  use DynamicSupervisor

  alias Beamlens.Domain.{Beam, Ets, Gc, Logger, Ports, Sup}
  alias Beamlens.Watcher

  @builtin_domains %{
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
  def init(opts) do
    watchers = Keyword.get(opts, :watchers, [])
    client_registry = Keyword.get(opts, :client_registry)

    if watchers != [] do
      send(self(), {:start_watchers, watchers, client_registry})
    end

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def handle_info({:start_watchers, watchers, client_registry}, state) do
    Enum.each(watchers, &start_watcher(__MODULE__, &1, client_registry))
    {:noreply, state}
  end

  @doc """
  Starts all configured watchers.

  Called after the supervisor is started to spawn watcher processes.
  """
  def start_watchers(supervisor \\ __MODULE__) do
    watchers = Application.get_env(:beamlens, :watchers, [])

    Enum.map(watchers, fn spec ->
      start_watcher(supervisor, spec)
    end)
  end

  @doc """
  Starts a single watcher under the supervisor.
  """
  def start_watcher(supervisor \\ __MODULE__, spec, client_registry \\ nil)

  def start_watcher(supervisor, domain, client_registry) when is_atom(domain) do
    case Map.fetch(@builtin_domains, domain) do
      {:ok, module} ->
        start_watcher(
          supervisor,
          [name: domain, domain_module: module],
          client_registry
        )

      :error ->
        {:error, {:unknown_builtin_domain, domain}}
    end
  end

  def start_watcher(supervisor, opts, client_registry) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    domain_module = Keyword.fetch!(opts, :domain_module)

    watcher_opts =
      opts
      |> Keyword.drop([:name, :domain_module])
      |> Keyword.merge(
        name: via_registry(name),
        domain_module: domain_module
      )

    watcher_opts =
      if client_registry do
        Keyword.put(watcher_opts, :client_registry, client_registry)
      else
        watcher_opts
      end

    DynamicSupervisor.start_child(supervisor, {Watcher, watcher_opts})
  end

  @doc """
  Stops a watcher by name.
  """
  def stop_watcher(supervisor \\ __MODULE__, name) do
    case Registry.lookup(Beamlens.WatcherRegistry, name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(supervisor, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists all running watchers with their status.
  """
  def list_watchers do
    Registry.select(Beamlens.WatcherRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {name, pid} ->
      status = Watcher.status(pid)
      Map.put(status, :name, name)
    end)
  end

  @doc """
  Gets the status of a specific watcher.
  """
  def watcher_status(name) do
    case Registry.lookup(Beamlens.WatcherRegistry, name) do
      [{pid, _}] ->
        {:ok, Watcher.status(pid)}

      [] ->
        {:error, :not_found}
    end
  end

  defp via_registry(name) do
    {:via, Registry, {Beamlens.WatcherRegistry, name}}
  end
end
