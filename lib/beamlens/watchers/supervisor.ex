defmodule Beamlens.Watchers.Supervisor do
  @moduledoc """
  DynamicSupervisor for watcher processes.

  Starts and supervises `Server` processes based on configuration.
  Each watcher runs independently on its own cron schedule.

  ## Configuration

      config :beamlens,
        watchers: [
          {:beam, "*/1 * * * *"},
          [name: :custom, watcher_module: MyApp.CustomWatcher, cron: "*/5 * * * *", config: []]
        ]

  ## Watcher Specifications

  Watchers can be specified in two forms:

    * `{domain, cron}` - Uses built-in watcher for the domain
    * `[name: atom, watcher_module: module, cron: string, config: keyword]` - Custom watcher
  """

  use DynamicSupervisor

  alias Beamlens.Watchers.{BeamWatcher, Server, Status}

  @builtin_watchers %{
    beam: BeamWatcher
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
      spawn_link(fn ->
        Process.sleep(50)
        Enum.each(watchers, &start_watcher(__MODULE__, &1, client_registry))
      end)
    end

    DynamicSupervisor.init(strategy: :one_for_one)
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

  def start_watcher(supervisor, {domain, cron}, client_registry)
      when is_atom(domain) and is_binary(cron) do
    case Map.fetch(@builtin_watchers, domain) do
      {:ok, module} ->
        start_watcher(
          supervisor,
          [name: domain, watcher_module: module, cron: cron, config: []],
          client_registry
        )

      :error ->
        {:error, {:unknown_builtin_watcher, domain}}
    end
  end

  def start_watcher(supervisor, opts, client_registry) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    watcher_module = Keyword.fetch!(opts, :watcher_module)
    cron = Keyword.fetch!(opts, :cron)
    config = Keyword.get(opts, :config, [])

    server_opts = [
      name: via_registry(name),
      watcher_module: watcher_module,
      cron: cron,
      config: config
    ]

    server_opts =
      if client_registry do
        Keyword.put(server_opts, :client_registry, client_registry)
      else
        server_opts
      end

    child_spec = {Server, server_opts}

    DynamicSupervisor.start_child(supervisor, child_spec)
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
      %Status{} = status = Server.status(pid)
      %{status | name: name}
    end)
  end

  @doc """
  Triggers an immediate check for a watcher by name.
  """
  def trigger_watcher(name) do
    case Registry.lookup(Beamlens.WatcherRegistry, name) do
      [{pid, _}] ->
        Server.trigger(pid)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets the status of a specific watcher.
  """
  def watcher_status(name) do
    case Registry.lookup(Beamlens.WatcherRegistry, name) do
      [{pid, _}] ->
        {:ok, Server.status(pid)}

      [] ->
        {:error, :not_found}
    end
  end

  defp via_registry(name) do
    {:via, Registry, {Beamlens.WatcherRegistry, name}}
  end
end
