defmodule Beamlens.Skill.TracerTest do
  use ExUnit.Case, async: false

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

    test "documents safety restrictions" do
      prompt = Tracer.system_prompt()
      assert String.contains?(prompt, "blocked")
      assert String.contains?(prompt, "arity")
    end
  end

  describe "snapshot/0" do
    test "returns a snapshot map" do
      start_supervised({Tracer, []})

      snapshot = Tracer.snapshot()
      assert is_map(snapshot)
      assert Map.has_key?(snapshot, :active)
      assert Map.has_key?(snapshot, :trace_count)
      assert snapshot.active == false
      assert snapshot.trace_count == 0
    end

    test "includes elapsed_ms when active" do
      start_supervised({Tracer, []})

      assert {:ok, _} = Tracer.start_trace({:erlang, :timestamp, 0})
      snapshot = Tracer.snapshot()

      assert snapshot.active == true
      assert is_integer(snapshot.elapsed_ms)

      Tracer.stop_trace()
    end
  end

  describe "callbacks/0" do
    test "returns a map of callbacks" do
      callbacks = Tracer.callbacks()
      assert is_map(callbacks)
      assert Map.has_key?(callbacks, "trace_start")
      assert Map.has_key?(callbacks, "trace_stop")
      assert Map.has_key?(callbacks, "trace_get")
    end
  end

  describe "callback_docs/0" do
    test "returns documentation for callbacks" do
      docs = Tracer.callback_docs()
      assert is_binary(docs)
      assert String.contains?(docs, "arity")
      assert String.contains?(docs, "REQUIRED")
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

  describe "safety validations" do
    setup do
      start_supervised({Tracer, []})
      on_exit(fn -> :recon_trace.clear() end)
      :ok
    end

    test "rejects wildcard module" do
      assert {:error, :wildcard_module_not_allowed} = Tracer.start_trace({:_, :func, 0})
    end

    test "rejects wildcard function" do
      assert {:error, :wildcard_function_not_allowed} = Tracer.start_trace({:erlang, :_, 0})
    end

    test "rejects wildcard arity" do
      assert {:error, :arity_required} = Tracer.start_trace({:erlang, :timestamp, :_})
    end

    test "rejects invalid arity" do
      assert {:error, :invalid_arity} = Tracer.start_trace({:erlang, :timestamp, -1})
      assert {:error, :invalid_arity} = Tracer.start_trace({:erlang, :timestamp, 256})
      assert {:error, :invalid_arity} = Tracer.start_trace({:erlang, :timestamp, "0"})
    end

    test "rejects blocked functions" do
      assert {:error, {:blocked_function, {:erlang, :send, 2}}} =
               Tracer.start_trace({:erlang, :send, 2})

      assert {:error, {:blocked_function, {GenServer, :call, 2}}} =
               Tracer.start_trace({GenServer, :call, 2})

      assert {:error, {:blocked_function, {:ets, :lookup, 2}}} =
               Tracer.start_trace({:ets, :lookup, 2})
    end
  end

  describe "trace operations" do
    setup do
      start_supervised({Tracer, []})
      on_exit(fn -> :recon_trace.clear() end)
      :ok
    end

    test "start_trace with valid patterns" do
      assert {:ok, %{status: :started, matches: matches}} =
               Tracer.start_trace({:erlang, :timestamp, 0})

      assert is_integer(matches)
      Tracer.stop_trace()
    end

    test "start_trace rejects duplicate active trace" do
      assert {:ok, %{status: :started}} = Tracer.start_trace({:erlang, :timestamp, 0})
      assert {:error, :trace_already_active} = Tracer.start_trace({:erlang, :now, 0})
      Tracer.stop_trace()
    end

    test "stop_trace returns trace count" do
      assert {:ok, _} = Tracer.start_trace({:erlang, :timestamp, 0})
      assert {:ok, %{status: :stopped, trace_count: count}} = Tracer.stop_trace()
      assert is_integer(count)
    end

    test "stop_trace when no active trace" do
      assert {:ok, %{status: :stopped, trace_count: 0}} = Tracer.stop_trace()
    end

    test "get_traces returns empty list when no traces collected" do
      assert [] = Tracer.get_traces()
    end

    test "snapshot reflects active trace state" do
      start_supervised({Tracer, []})

      assert %{active: false} = Tracer.snapshot()

      assert {:ok, _} = Tracer.start_trace({:erlang, :timestamp, 0})
      assert %{active: true, trace_spec: {:erlang, :timestamp, 0}} = Tracer.snapshot()

      Tracer.stop_trace()
      assert %{active: false} = Tracer.snapshot()
    end
  end
end
