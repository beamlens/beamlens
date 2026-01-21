defmodule Beamlens.Skill.TracerTest do
  use ExUnit.Case, async: true

  alias Beamlens.Skill.Tracer

  describe "title/0" do
    test "returns the skill title" do
      assert Tracer.title() == "Tracer"
    end
  end

  describe "description/0" do
    test "returns the skill description" do
      assert Tracer.description() == "Production-safe function call tracing"
    end
  end

  describe "system_prompt/0" do
    test "returns a non-empty system prompt" do
      prompt = Tracer.system_prompt()
      assert is_binary(prompt)
      assert String.length(prompt) > 0
      assert String.contains?(prompt, "tracing")
    end
  end

  describe "snapshot/0" do
    test "returns a snapshot map" do
      snapshot = Tracer.snapshot()
      assert is_map(snapshot)
      assert Map.has_key?(snapshot, :active_trace_count)
      assert snapshot.active_trace_count == 0
    end
  end

  describe "callbacks/0" do
    test "returns a map of callbacks" do
      callbacks = Tracer.callbacks()
      assert is_map(callbacks)
      assert Map.has_key?(callbacks, "trace_list")
    end
  end

  describe "callback_docs/0" do
    test "returns documentation for callbacks" do
      docs = Tracer.callback_docs()
      assert is_binary(docs)
      assert String.length(docs) > 0
    end
  end

  describe "GenServer" do
    setup do
      {:ok, pid} = start_supervised({Tracer, []})
      %{pid: pid}
    end

    test "starts successfully", %{pid: pid} do
      assert Process.alive?(pid)
      assert is_pid(pid)
    end

    test "handle_info returns :noreply for unknown messages", %{pid: pid} do
      send(pid, :unknown_message)
      # Should not crash
      assert Process.alive?(pid)
    end
  end
end
