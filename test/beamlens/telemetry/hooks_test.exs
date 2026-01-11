defmodule Beamlens.Telemetry.HooksTest do
  use ExUnit.Case

  alias Beamlens.Operator.Tools
  alias Beamlens.Telemetry.Hooks

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
        content: %Tools.TakeSnapshot{intent: "checking memory for issues"}
      }

      result = Hooks.on_call_end(nil, response, context)

      assert result == {:cont, response}

      assert_receive {:telemetry, [:beamlens, :llm, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.trace_id == "trace-xyz"
      assert metadata.iteration == 2
      assert metadata.tool_selected == "take_snapshot"
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
        content: %Tools.Wait{intent: nil, ms: 1000}
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

  describe "on_compaction_start/3" do
    test "emits compaction start event with message count and strategy" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-compaction-start-#{inspect(ref)}",
        [:beamlens, :compaction, :start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      context = %Puck.Context{
        messages: [%{role: :user}, %{role: :assistant}, %{role: :user}],
        metadata: %{trace_id: "trace-compact", iteration: 7}
      }

      result =
        Hooks.on_compaction_start(context, Puck.Compaction.Summarize, %{max_tokens: 50_000})

      assert result == {:cont, context}

      assert_receive {:telemetry, [:beamlens, :compaction, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert measurements.message_count == 3
      assert metadata.trace_id == "trace-compact"
      assert metadata.iteration == 7
      assert metadata.strategy == Puck.Compaction.Summarize
      assert metadata.config == %{max_tokens: 50_000}

      :telemetry.detach("test-compaction-start-#{inspect(ref)}")
    end

    test "handles missing trace metadata gracefully" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-compaction-start-no-meta-#{inspect(ref)}",
        [:beamlens, :compaction, :start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      context = %Puck.Context{
        messages: [%{role: :user}],
        metadata: %{}
      }

      result =
        Hooks.on_compaction_start(context, Puck.Compaction.SlidingWindow, %{window_size: 20})

      assert result == {:cont, context}

      assert_receive {:telemetry, [:beamlens, :compaction, :start], measurements, metadata}
      assert measurements.message_count == 1
      assert metadata.trace_id == nil
      assert metadata.iteration == 0
      assert metadata.strategy == Puck.Compaction.SlidingWindow

      :telemetry.detach("test-compaction-start-no-meta-#{inspect(ref)}")
    end
  end

  describe "on_compaction_end/2" do
    test "emits compaction stop event with reduced message count" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-compaction-end-#{inspect(ref)}",
        [:beamlens, :compaction, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      context = %Puck.Context{
        messages: [%{role: :user}],
        metadata: %{trace_id: "trace-compact-end", iteration: 8}
      }

      result = Hooks.on_compaction_end(context, %{})

      assert result == {:cont, context}

      assert_receive {:telemetry, [:beamlens, :compaction, :stop], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert measurements.message_count == 1
      assert metadata.trace_id == "trace-compact-end"
      assert metadata.iteration == 8

      :telemetry.detach("test-compaction-end-#{inspect(ref)}")
    end

    test "handles empty messages list" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-compaction-end-empty-#{inspect(ref)}",
        [:beamlens, :compaction, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      context = %Puck.Context{
        messages: [],
        metadata: %{trace_id: "trace-empty", iteration: 0}
      }

      result = Hooks.on_compaction_end(context, %{})

      assert result == {:cont, context}

      assert_receive {:telemetry, [:beamlens, :compaction, :stop], measurements, _metadata}
      assert measurements.message_count == 0

      :telemetry.detach("test-compaction-end-empty-#{inspect(ref)}")
    end
  end
end
