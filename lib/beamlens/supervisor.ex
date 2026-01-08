defmodule Beamlens.Supervisor do
  @moduledoc """
  Main supervisor for the BeamLens orchestrator-workers architecture.

  Supervises the following components:

    * `Beamlens.TaskSupervisor` - For async tasks
    * `Beamlens.CircuitBreaker` - Rate limiting for LLM calls (optional)
    * `Beamlens.WatcherRegistry` - Registry for watcher processes
    * `Beamlens.AlertQueue` - Queue for watcher alerts
    * `Beamlens.Watchers.Supervisor` - DynamicSupervisor for watchers
    * `Beamlens.AlertHandler` - Handles alerts and triggers investigation

  ## Configuration

      config :beamlens,
        watchers: [
          {:beam, "*/1 * * * *"}
        ],
        client_registry: %{
          primary: "Ollama",
          clients: [
            %{name: "Ollama", provider: "openai-generic",
              options: %{base_url: "http://localhost:11434/v1", model: "qwen3:4b"}}
          ]
        },
        alert_handler: [
          trigger: :on_alert
        ],
        circuit_breaker: [
          enabled: true
        ]
  """

  use Supervisor

  alias Beamlens.{AlertHandler, AlertQueue}
  alias Beamlens.Watchers.Supervisor, as: WatchersSupervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    watchers = Keyword.get(opts, :watchers, Application.get_env(:beamlens, :watchers, []))
    alert_handler_opts = Keyword.get(opts, :alert_handler, [])
    circuit_breaker_opts = Keyword.get(opts, :circuit_breaker, [])
    client_registry = Keyword.get(opts, :client_registry)

    watcher_opts = [watchers: watchers, client_registry: client_registry]
    alert_handler_opts = merge_client_registry(alert_handler_opts, client_registry)

    children =
      [
        {Task.Supervisor, name: Beamlens.TaskSupervisor},
        maybe_circuit_breaker(circuit_breaker_opts),
        {Registry, keys: :unique, name: Beamlens.WatcherRegistry},
        AlertQueue,
        {WatchersSupervisor, watcher_opts},
        {AlertHandler, alert_handler_opts}
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp merge_client_registry(alert_handler_opts, nil), do: alert_handler_opts

  defp merge_client_registry(alert_handler_opts, client_registry) do
    agent_opts = Keyword.get(alert_handler_opts, :agent_opts, [])
    agent_opts = Keyword.put_new(agent_opts, :client_registry, client_registry)
    Keyword.put(alert_handler_opts, :agent_opts, agent_opts)
  end

  defp maybe_circuit_breaker(opts) do
    if Keyword.get(opts, :enabled, false) do
      {Beamlens.CircuitBreaker, Keyword.delete(opts, :enabled)}
    else
      nil
    end
  end
end
