defmodule Beamlens.Supervisor do
  @moduledoc """
  Main supervisor for BeamLens.

  Supervises the following components:

    * `Beamlens.TaskSupervisor` - For async tasks
    * `Beamlens.OperatorRegistry` - Registry for operator processes
    * `Beamlens.Domain.Logger.LogStore` - Log buffer (when `:logger` operator enabled)
    * `Beamlens.Domain.Exception.ExceptionStore` - Exception buffer (when `:exception` operator enabled)
    * `Beamlens.Operator.Supervisor` - DynamicSupervisor for operators
    * `Beamlens.Coordinator` - Alert correlation and insight generation

  ## Configuration

      config :beamlens,
        operators: [
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
  alias Beamlens.Operator.Supervisor, as: OperatorSupervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    operators = Keyword.get(opts, :operators, Application.get_env(:beamlens, :operators, []))
    client_registry = Keyword.get(opts, :client_registry)
    coordinator_opts = Keyword.get(opts, :coordinator, [])

    coordinator_opts =
      Keyword.put_new(coordinator_opts, :client_registry, client_registry)

    children =
      ([
         {Task.Supervisor, name: Beamlens.TaskSupervisor},
         {Registry, keys: :unique, name: Beamlens.OperatorRegistry}
       ] ++
         logger_children(operators) ++
         exception_children(operators) ++
         [
           {OperatorSupervisor, []},
           operator_starter_child(operators, client_registry),
           {Coordinator, coordinator_opts}
         ])
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
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
