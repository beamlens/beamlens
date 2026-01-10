defmodule Beamlens.Supervisor do
  @moduledoc """
  Main supervisor for BeamLens.

  Supervises the following components:

    * `Beamlens.TaskSupervisor` - For async tasks
    * `Beamlens.WatcherRegistry` - Registry for watcher processes
    * `Beamlens.Domain.Logger.LogStore` - Log buffer (when `:logger` watcher enabled)
    * `Beamlens.Domain.Exception.ExceptionStore` - Exception buffer (when `:exception` watcher enabled)
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
  alias Beamlens.Domain.Exception.ExceptionStore
  alias Beamlens.Domain.Logger.LogStore
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

    children =
      [
        {Task.Supervisor, name: Beamlens.TaskSupervisor},
        {Registry, keys: :unique, name: Beamlens.WatcherRegistry}
      ] ++
        logger_children(watchers) ++
        exception_children(watchers) ++
        [
          {WatcherSupervisor, watcher_opts},
          {Coordinator, coordinator_opts}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp logger_children(watchers) do
    if has_logger_watcher?(watchers) do
      [{LogStore, []}]
    else
      []
    end
  end

  defp exception_children(watchers) do
    if has_exception_watcher?(watchers) do
      [{ExceptionStore, []}]
    else
      []
    end
  end

  defp has_logger_watcher?(watchers) do
    Enum.any?(watchers, fn
      :logger -> true
      opts when is_list(opts) -> Keyword.get(opts, :name) == :logger
      _ -> false
    end)
  end

  defp has_exception_watcher?(watchers) do
    Enum.any?(watchers, fn
      :exception -> true
      opts when is_list(opts) -> Keyword.get(opts, :name) == :exception
      _ -> false
    end)
  end
end
