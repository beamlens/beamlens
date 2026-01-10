defmodule Beamlens.LLM.Utils do
  @moduledoc false

  @doc """
  Adds a tool result to the context as a user message.
  """
  def add_result(context, result) do
    case Jason.encode(result) do
      {:ok, encoded} ->
        message = Puck.Message.new(:user, encoded, %{tool_result: true})
        %{context | messages: context.messages ++ [message]}

      {:error, reason} ->
        error_msg = "Failed to encode tool result: #{inspect(reason)}"
        message = Puck.Message.new(:user, error_msg, %{tool_result: true})
        %{context | messages: context.messages ++ [message]}
    end
  end

  @doc """
  Formats Puck messages for BAML function calls.
  """
  def format_messages_for_baml(messages) do
    Enum.map(messages, fn %Puck.Message{role: role, content: content} ->
      %{
        role: to_string(role),
        content: extract_text_content(content)
      }
    end)
  end

  @doc """
  Extracts text content from message content (handles both string and list formats).
  """
  def extract_text_content(content) when is_binary(content), do: content

  def extract_text_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{type: "text", text: text} -> text
      _ -> ""
    end)
  end

  def extract_text_content(_), do: ""

  @doc """
  Adds client_registry to config if provided.
  """
  def maybe_add_client_registry(config, nil), do: config

  def maybe_add_client_registry(config, client_registry) when is_map(client_registry) do
    Map.put(config, :client_registry, client_registry)
  end
end
