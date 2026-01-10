defmodule Beamlens.LLM.UtilsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.LLM.Utils

  describe "add_result/2" do
    test "encodes valid result as JSON user message" do
      context = %{messages: []}
      result = %{key: "value", count: 42}

      updated = Utils.add_result(context, result)

      assert length(updated.messages) == 1
      [message] = updated.messages
      assert message.role == :user
      assert message.metadata.tool_result == true
      [part] = message.content
      assert part.text == ~s({"count":42,"key":"value"})
    end

    test "appends to existing messages" do
      existing = Puck.Message.new(:user, "hello", %{})
      context = %{messages: [existing]}
      result = %{data: "test"}

      updated = Utils.add_result(context, result)

      assert length(updated.messages) == 2
      assert hd(updated.messages) == existing
    end

    test "handles encoding failures gracefully" do
      context = %{messages: []}
      result = {:tuple, "cannot encode tuples"}

      updated = Utils.add_result(context, result)

      assert length(updated.messages) == 1
      [message] = updated.messages
      assert message.role == :user
      assert message.metadata.tool_result == true
      [part] = message.content
      assert part.text =~ "Failed to encode tool result"
    end
  end

  describe "format_messages_for_baml/1" do
    test "formats list of Puck messages to BAML format" do
      messages = [
        %Puck.Message{role: :user, content: "Hello", metadata: %{}},
        %Puck.Message{role: :assistant, content: "Hi there", metadata: %{}}
      ]

      result = Utils.format_messages_for_baml(messages)

      assert result == [
               %{role: "user", content: "Hello"},
               %{role: "assistant", content: "Hi there"}
             ]
    end

    test "converts role atoms to strings" do
      messages = [%Puck.Message{role: :system, content: "You are helpful", metadata: %{}}]

      [formatted] = Utils.format_messages_for_baml(messages)

      assert formatted.role == "system"
    end

    test "handles empty list" do
      assert Utils.format_messages_for_baml([]) == []
    end
  end

  describe "extract_text_content/1" do
    test "returns binary content unchanged" do
      assert Utils.extract_text_content("hello world") == "hello world"
    end

    test "extracts text from list of content blocks" do
      content = [
        %{type: "text", text: "First line"},
        %{type: "text", text: "Second line"}
      ]

      assert Utils.extract_text_content(content) == "First line\nSecond line"
    end

    test "ignores non-text content blocks" do
      content = [
        %{type: "text", text: "Text content"},
        %{type: "image", url: "http://example.com"}
      ]

      assert Utils.extract_text_content(content) == "Text content\n"
    end

    test "handles empty content" do
      assert Utils.extract_text_content("") == ""
      assert Utils.extract_text_content([]) == ""
    end

    test "returns empty string for other types" do
      assert Utils.extract_text_content(nil) == ""
      assert Utils.extract_text_content(123) == ""
    end
  end

  describe "maybe_add_client_registry/2" do
    test "returns config unchanged when registry is nil" do
      config = %{option: "value"}

      assert Utils.maybe_add_client_registry(config, nil) == config
    end

    test "adds registry to config when provided" do
      config = %{option: "value"}
      registry = %{primary: "OpenAI", clients: []}

      result = Utils.maybe_add_client_registry(config, registry)

      assert result == %{option: "value", client_registry: registry}
    end
  end
end
