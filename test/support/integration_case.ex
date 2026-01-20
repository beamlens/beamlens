defmodule Beamlens.IntegrationCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Beamlens.TestSupport.Provider

  using do
    quote do
      @moduletag :integration
      import Beamlens.IntegrationCase, only: [start_operator: 2]
    end
  end

  @doc """
  Builds a client registry for tests.

  Returns `{:ok, registry}` or `{:error, reason}`.

  Provider can be "anthropic", "openai", "google-ai", "ollama", or "mock".
  Defaults to BEAMLENS_TEST_PROVIDER env var or "anthropic".
  """
  def build_client_registry(provider \\ nil) do
    case Provider.build_context(provider) do
      {:ok, %{client_registry: registry}} -> {:ok, registry}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Starts an operator under the test supervisor.

  Uses `start_supervised/2` so the operator is automatically cleaned up
  when the test ends. The GenServer is now responsive during LLM calls
  (via Task.async), so normal shutdown works.

  ## Example

      {:ok, pid} = start_operator(context, skill: MySkill)

  """
  def start_operator(%{puck_client: %Puck.Client{} = puck_client} = context, opts) do
    opts =
      opts
      |> Keyword.put(:client_registry, context.client_registry)
      |> Keyword.put_new(:puck_client, puck_client)

    start_supervised({Beamlens.Operator, opts})
  end

  def start_operator(context, opts) do
    opts = Keyword.put(opts, :client_registry, context.client_registry)
    start_supervised({Beamlens.Operator, opts})
  end

  setup do
    # Configure operators for coordinator tests (set in persistent_term like Beamlens.Supervisor does)
    :persistent_term.put(
      {Beamlens.Supervisor, :skills},
      [Beamlens.Skill.Beam, Beamlens.Skill.Ets, Beamlens.Skill.Gc]
    )

    on_exit(fn ->
      :persistent_term.erase({Beamlens.Supervisor, :skills})
    end)

    case Provider.build_context() do
      {:ok, context} ->
        {:ok, context}

      {:error, reason} ->
        flunk(reason)
    end
  end
end
