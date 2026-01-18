defmodule Beamlens.Testing do
  @moduledoc """
  Deterministic testing helpers for Beamlens agents.
  """

  def mock_client(responses) when is_list(responses) do
    mock_client(responses, [])
  end

  def mock_client(responses, opts) when is_list(responses) and is_list(opts) do
    default = Keyword.get(opts, :default, {:error, :mock_responses_exhausted})
    model = Keyword.get(opts, :model, "mock")
    hooks = Keyword.get(opts, :hooks, Beamlens.Telemetry.Hooks)
    {:ok, queue_pid} = Agent.start_link(fn -> responses end)

    Puck.Client.new(
      {Beamlens.Testing.MockBackend, queue_pid: queue_pid, default: default, model: model},
      hooks: hooks
    )
  end
end
