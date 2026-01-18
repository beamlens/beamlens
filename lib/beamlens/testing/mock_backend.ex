defmodule Beamlens.Testing.MockBackend do
  @moduledoc false

  @behaviour Puck.Backend

  alias Puck.Response

  @impl true
  def call(config, _messages, opts) do
    response = pop_response(config)
    normalize_response(response, config, opts)
  end

  @impl true
  def stream(config, _messages, opts) do
    response = pop_response(config)

    case normalize_response(response, config, opts) do
      {:ok, %Response{} = response} ->
        stream =
          Stream.map([response.content], fn content ->
            %{type: :content, content: content, metadata: %{partial: false, backend: :mock}}
          end)

        {:ok, stream}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def introspect(config) do
    %{
      provider: "mock",
      model: Map.get(config, :model, "mock"),
      operation: :chat
    }
  end

  defp pop_response(config) do
    queue_pid = Map.fetch!(config, :queue_pid)
    default = Map.get(config, :default, {:error, :mock_responses_exhausted})

    Agent.get_and_update(queue_pid, fn
      [next | rest] -> {next, rest}
      [] -> {default, []}
    end)
  end

  defp normalize_response({:error, reason}, _config, _opts), do: {:error, reason}
  defp normalize_response(%Response{} = response, _config, _opts), do: {:ok, response}

  defp normalize_response(response, config, opts) do
    content = maybe_parse_response(response, Keyword.get(opts, :output_schema))

    {:ok,
     Response.new(
       content: content,
       finish_reason: :stop,
       metadata: %{backend: :mock, model: Map.get(config, :model, "mock")}
     )}
  end

  defp maybe_parse_response(response, nil), do: response

  defp maybe_parse_response(response, schema) when is_map(response) do
    case Zoi.parse(schema, response) do
      {:ok, parsed} -> parsed
      {:error, _} -> response
    end
  end

  defp maybe_parse_response(response, _schema), do: response
end
