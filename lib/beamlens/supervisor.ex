defmodule Beamlens.Supervisor do
  @moduledoc """
  Main supervisor for BeamLens.

  Supervises the following components:

    * `Beamlens.TaskSupervisor` - For async tasks
    * `Beamlens.OperatorRegistry` - Registry for operator processes
    * `Beamlens.Domain.Logger.LogStore` - Log buffer (when `:logger` operator enabled)
    * `Beamlens.Domain.Exception.ExceptionStore` - Exception buffer (when `:exception` operator enabled)
    * `Beamlens.AlertForwarder` - Cross-node alert broadcasting (when `:pubsub` provided)
    * `Beamlens.Operator.Supervisor` - DynamicSupervisor for operators
    * `Beamlens.Coordinator` - Alert correlation and insight generation

  ## Single Node Configuration

      children = [
        {Beamlens,
          operators: [:beam, :ets],
          client_registry: client_registry()}
      ]

  ## Clustered Configuration

  When running in a cluster, provide a `:pubsub` option to enable cross-node
  alert propagation and automatic singleton coordination:

      children = [
        {Beamlens,
          operators: [:beam, :ets],
          client_registry: client_registry(),
          pubsub: MyApp.PubSub}
      ]

  When `pubsub` is provided:
    * `Beamlens.AlertForwarder` is started to broadcast alerts to PubSub
    * `Beamlens.Coordinator` is wrapped in Highlander for cluster singleton
    * Coordinator subscribes to PubSub for cross-node alerts

  ## Options

    * `:operators` - List of operators to start (default: from application config)
    * `:client_registry` - LLM client configuration
    * `:pubsub` - Phoenix.PubSub module for clustered mode (optional)
    * `:coordinator` - Additional options for the Coordinator

  ## Advanced Deployments

  For custom supervision trees, use the building blocks directly.
  See `docs/deployment.md` for examples.
  """

  use Supervisor

  alias Beamlens.AlertForwarder
  alias Beamlens.Coordinator
  alias Beamlens.Domain.Exception.ExceptionStore
  alias Beamlens.Domain.Logger.LogStore
  alias Beamlens.Operator.Supervisor, as: OperatorSupervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    operators = Keyword.get(opts, :operators, Application.get_env(:beamlens, :operators, []))
    client_registry = Keyword.get(opts, :client_registry)
    pubsub = Keyword.get(opts, :pubsub)

    coordinator_opts =
      opts
      |> Keyword.get(:coordinator, [])
      |> Keyword.put_new(:client_registry, client_registry)
      |> maybe_put(:pubsub, pubsub)

    children =
      ([
         {Task.Supervisor, name: Beamlens.TaskSupervisor},
         {Registry, keys: :unique, name: Beamlens.OperatorRegistry}
       ] ++
         alert_forwarder_children(pubsub) ++
         logger_children(operators) ++
         exception_children(operators) ++
         [
           {OperatorSupervisor, []},
           operator_starter_child(operators, client_registry),
           coordinator_child(coordinator_opts, pubsub)
         ])
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp alert_forwarder_children(nil), do: []
  defp alert_forwarder_children(pubsub), do: [{AlertForwarder, pubsub: pubsub}]

  defp coordinator_child(opts, nil) do
    {Coordinator, opts}
  end

  defp coordinator_child(opts, _pubsub) do
    {Highlander, {Coordinator, opts}}
  end

  defp operator_starter_child([], _client_registry), do: nil

  defp operator_starter_child(operators, client_registry) do
    %{
      id: :operator_starter,
      start:
        {Task, :start_link,
         [fn -> OperatorSupervisor.start_operators_with_opts(operators, client_registry) end]},
      restart: :temporary
    }
  end

  defp logger_children(operators) do
    if has_logger_operator?(operators) do
      [{LogStore, []}]
    else
      []
    end
  end

  defp exception_children(operators) do
    if has_exception_operator?(operators) do
      [{ExceptionStore, []}]
    else
      []
    end
  end

  defp has_logger_operator?(operators) do
    Enum.any?(operators, fn
      :logger -> true
      opts when is_list(opts) -> Keyword.get(opts, :name) == :logger
      _ -> false
    end)
  end

  defp has_exception_operator?(operators) do
    Enum.any?(operators, fn
      :exception -> true
      opts when is_list(opts) -> Keyword.get(opts, :name) == :exception
      _ -> false
    end)
  end
end
