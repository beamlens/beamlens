defmodule Beamlens.Telemetry.HooksTest do
  use ExUnit.Case

  alias Beamlens.Telemetry.Hooks
  alias Beamlens.Tools

  describe "on_call_start/3" do
    test "emits llm call_start event with metadata" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-llm-start-#{inspect(ref)}",
        [:beamlens, :llm, :start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      context = %Puck.Context{
        messages: [%{role: :user}, %{role: :assistant}],
        metadata: %{trace_id: "trace-abc", iteration: 3}
      }

      result = Hooks.on_call_start(nil, "test content", context)

      assert result == {:cont, "test content"}

      assert_receive {:telemetry, [:beamlens, :llm, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.trace_id == "trace-abc"
      assert metadata.iteration == 3
      assert metadata.context_size == 2

      :telemetry.detach("test-llm-start-#{inspect(ref)}")
    end
  end

  describe "on_call_end/3" do
    test "emits llm stop event with tool info" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-llm-end-#{inspect(ref)}",
        [:beamlens, :llm, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      context = %Puck.Context{
        messages: [],
        metadata: %{trace_id: "trace-xyz", iteration: 2}
      }

      response = %Puck.Response{
        content: %Tools.GetMemoryStats{intent: "checking memory for issues"}
      }

      result = Hooks.on_call_end(nil, response, context)

      assert result == {:cont, response}

      assert_receive {:telemetry, [:beamlens, :llm, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.trace_id == "trace-xyz"
      assert metadata.iteration == 2
      assert metadata.tool_selected == "get_memory_stats"
      assert metadata.intent == "checking memory for issues"
      assert metadata.response == response.content

      :telemetry.detach("test-llm-end-#{inspect(ref)}")
    end

    test "handles nil intent" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-llm-end-nil-#{inspect(ref)}",
        [:beamlens, :llm, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      context = %Puck.Context{
        messages: [],
        metadata: %{trace_id: "trace-nil", iteration: 0}
      }

      response = %Puck.Response{
        content: %Tools.GetSystemInfo{intent: nil}
      }

      Hooks.on_call_end(nil, response, context)

      assert_receive {:telemetry, [:beamlens, :llm, :stop], _measurements, metadata}
      assert metadata.intent == ""

      :telemetry.detach("test-llm-end-nil-#{inspect(ref)}")
    end
  end

  describe "on_call_error/3" do
    test "emits llm exception event with error details" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-llm-error-#{inspect(ref)}",
        [:beamlens, :llm, :exception],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      context = %Puck.Context{
        messages: [],
        metadata: %{trace_id: "trace-err", iteration: 5}
      }

      error = {:error, :timeout}

      Hooks.on_call_error(nil, error, context)

      assert_receive {:telemetry, [:beamlens, :llm, :exception], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.trace_id == "trace-err"
      assert metadata.iteration == 5
      assert metadata.kind == :error
      assert metadata.reason == {:error, :timeout}
      assert is_list(metadata.stacktrace)

      :telemetry.detach("test-llm-error-#{inspect(ref)}")
    end
  end
end
