defmodule Beamlens.Supervisor do
  @moduledoc """
  Main supervisor for BeamLens.

  Supervises the following components:

    * `Beamlens.TaskSupervisor` - For async tasks
    * `Beamlens.WatcherRegistry` - Registry for watcher processes
    * `Beamlens.Watcher.Supervisor` - DynamicSupervisor for watchers
    * `Beamlens.Coordinator` - Alert correlation and insight generation

  ## Configuration

      config :beamlens,
        watchers: [
          :beam
        ],
        client_registry: %{
          primary: "Ollama",
          clients: [
            %{name: "Ollama", provider: "openai-generic",
              options: %{base_url: "http://localhost:11434/v1", model: "qwen3:4b"}}
          ]
        }
  """

  use Supervisor

  alias Beamlens.Coordinator
  alias Beamlens.Watcher.Supervisor, as: WatcherSupervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    watchers = Keyword.get(opts, :watchers, Application.get_env(:beamlens, :watchers, []))
    client_registry = Keyword.get(opts, :client_registry)
    coordinator_opts = Keyword.get(opts, :coordinator, [])

    watcher_opts = [watchers: watchers, client_registry: client_registry]

    coordinator_opts =
      Keyword.put_new(coordinator_opts, :client_registry, client_registry)

    children = [
      {Task.Supervisor, name: Beamlens.TaskSupervisor},
      {Registry, keys: :unique, name: Beamlens.WatcherRegistry},
      {WatcherSupervisor, watcher_opts},
      {Coordinator, coordinator_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
