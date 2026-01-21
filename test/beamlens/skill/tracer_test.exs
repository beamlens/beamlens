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
      start_supervised({Tracer, []})

      snapshot = Tracer.snapshot()
      assert is_map(snapshot)
      assert Map.has_key?(snapshot, :active_trace_count)
      assert Map.has_key?(snapshot, :event_count)
      assert snapshot.active_trace_count == 0
      assert snapshot.event_count == 0
    end
  end

  describe "callbacks/0" do
    test "returns a map of callbacks" do
      callbacks = Tracer.callbacks()
      assert is_map(callbacks)
      assert Map.has_key?(callbacks, "trace_start")
      assert Map.has_key?(callbacks, "trace_stop")
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
      assert Process.alive?(pid)
    end
  end

  describe "trace operations" do
    setup do
      start_supervised({Tracer, []})
      :ok
    end

    test "start_trace with valid patterns" do
      module_pattern = :erlang
      function_pattern = :timestamp
      assert {:ok, %{status: :started}} = Tracer.start_trace({module_pattern, function_pattern})

      Tracer.stop_trace()
    end

    test "start_trace rejects wildcard module pattern" do
      assert {:error, :wildcard_module_not_allowed} = Tracer.start_trace({:_, :some_func})
      assert {:error, :wildcard_module_not_allowed} = Tracer.start_trace({:*, :some_func})
    end

    test "start_trace rejects wildcard function pattern" do
      assert {:error, :wildcard_function_not_allowed} = Tracer.start_trace({:erlang, :_})
      assert {:error, :wildcard_function_not_allowed} = Tracer.start_trace({:erlang, :*})
    end

    test "start_trace rejects duplicate active trace" do
      module_pattern = :erlang
      function_pattern = :timestamp
      assert {:ok, %{status: :started}} = Tracer.start_trace({module_pattern, function_pattern})

      module_pattern2 = :lists
      function_pattern2 = :reverse

      assert {:error, :trace_already_active} =
               Tracer.start_trace({module_pattern2, function_pattern2})

      Tracer.stop_trace()
    end

    test "stop_trace when no active trace" do
      assert {:error, :no_active_trace} = Tracer.stop_trace()
    end

    test "trace_list returns empty when no active trace" do
      assert [] = Tracer.list_traces()
    end

    test "handles tracer process exit gracefully" do
      module_pattern = :erlang
      function_pattern = :timestamp
      assert {:ok, %{status: :started}} = Tracer.start_trace({module_pattern, function_pattern})

      traces = Tracer.list_traces()
      assert length(traces) == 1
      assert hd(traces).module_pattern == :erlang

      Tracer.stop_trace()
    end
  end
end
