defmodule Beamlens.TelemetryTest do
  use ExUnit.Case

  alias Beamlens.Telemetry

  describe "generate_trace_id/0" do
    test "returns a 32-character lowercase hex string" do
      trace_id = Telemetry.generate_trace_id()

      assert is_binary(trace_id)
      assert String.length(trace_id) == 32
      assert trace_id =~ ~r/^[a-f0-9]+$/
    end

    test "returns unique values on each call" do
      trace_ids = for _ <- 1..100, do: Telemetry.generate_trace_id()
      unique_ids = Enum.uniq(trace_ids)

      assert length(unique_ids) == 100
    end
  end

  describe "event_names/0" do
    test "returns all 35 event names" do
      events = Telemetry.event_names()

      assert length(events) == 35
    end

    test "all events start with :beamlens" do
      events = Telemetry.event_names()

      for event <- events do
        assert [:beamlens | _] = event
      end
    end

    test "includes agent, llm, tool, judge, schedule, and circuit breaker events" do
      events = Telemetry.event_names()

      assert [:beamlens, :agent, :start] in events
      assert [:beamlens, :agent, :stop] in events
      assert [:beamlens, :agent, :exception] in events
      assert [:beamlens, :llm, :start] in events
      assert [:beamlens, :llm, :stop] in events
      assert [:beamlens, :llm, :exception] in events
      assert [:beamlens, :tool, :start] in events
      assert [:beamlens, :tool, :stop] in events
      assert [:beamlens, :tool, :exception] in events
      assert [:beamlens, :judge, :start] in events
      assert [:beamlens, :judge, :stop] in events
      assert [:beamlens, :judge, :exception] in events
      assert [:beamlens, :schedule, :triggered] in events
      assert [:beamlens, :schedule, :skipped] in events
      assert [:beamlens, :schedule, :completed] in events
      assert [:beamlens, :schedule, :failed] in events
      assert [:beamlens, :circuit_breaker, :state_change] in events
      assert [:beamlens, :circuit_breaker, :rejected] in events
    end
  end

  describe "tool_span/2" do
    test "emits start and stop events with metadata" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "test-tool-handler-#{inspect(ref)}",
        [
          [:beamlens, :tool, :start],
          [:beamlens, :tool, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      metadata = %{
        trace_id: "test-trace-123",
        iteration: 1,
        tool_name: "get_memory_stats",
        intent: "check memory usage"
      }

      result = Telemetry.tool_span(metadata, fn -> {:ok, %{total: 1024}} end)

      assert result == {:ok, %{total: 1024}}

      assert_receive {:telemetry, [:beamlens, :tool, :start], start_measurements, start_metadata}
      assert is_integer(start_measurements.system_time)
      assert start_metadata.trace_id == "test-trace-123"
      assert start_metadata.iteration == 1
      assert start_metadata.tool_name == "get_memory_stats"
      assert start_metadata.intent == "check memory usage"

      assert_receive {:telemetry, [:beamlens, :tool, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_metadata.trace_id == "test-trace-123"

      :telemetry.detach("test-tool-handler-#{inspect(ref)}")
    end

    test "emits exception event and re-raises on error" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-tool-exception-handler-#{inspect(ref)}",
        [:beamlens, :tool, :exception],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      metadata = %{
        trace_id: "test-trace-456",
        iteration: 2,
        tool_name: "get_atom_stats",
        intent: "check atoms"
      }

      assert_raise RuntimeError, "tool failed", fn ->
        Telemetry.tool_span(metadata, fn -> raise "tool failed" end)
      end

      assert_receive {:telemetry, [:beamlens, :tool, :exception], measurements, event_metadata}
      assert is_integer(measurements.duration)
      assert event_metadata.trace_id == "test-trace-456"
      assert event_metadata.tool_name == "get_atom_stats"
      assert event_metadata.kind == :error
      assert %RuntimeError{} = event_metadata.reason
      assert is_list(event_metadata.stacktrace)

      :telemetry.detach("test-tool-exception-handler-#{inspect(ref)}")
    end
  end

  describe "span/2" do
    test "emits start and stop events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "test-handler-#{inspect(ref)}",
        [
          [:beamlens, :agent, :start],
          [:beamlens, :agent, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      result =
        Beamlens.Telemetry.span(%{node: "test@node"}, fn ->
          {:my_result, %{}, %{custom: "metadata"}}
        end)

      assert result == :my_result

      assert_receive {:telemetry, [:beamlens, :agent, :start], start_measurements, start_metadata}
      assert is_integer(start_measurements.system_time)
      assert start_metadata.node == "test@node"

      assert_receive {:telemetry, [:beamlens, :agent, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_metadata.custom == "metadata"

      :telemetry.detach("test-handler-#{inspect(ref)}")
    end

    test "emits exception event on error" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-exception-handler-#{inspect(ref)}",
        [:beamlens, :agent, :exception],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      assert_raise RuntimeError, fn ->
        Beamlens.Telemetry.span(%{node: "test@node"}, fn ->
          raise "test error"
        end)
      end

      assert_receive {:telemetry, [:beamlens, :agent, :exception], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert metadata.node == "test@node"

      :telemetry.detach("test-exception-handler-#{inspect(ref)}")
    end
  end

  describe "emit_tool_start/1 and emit_tool_stop/3" do
    test "emits start and stop events with result and duration" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "test-emit-tool-handler-#{inspect(ref)}",
        [
          [:beamlens, :tool, :start],
          [:beamlens, :tool, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      metadata = %{
        trace_id: "test-trace-emit",
        iteration: 0,
        tool_name: "get_system_info",
        intent: "get_system_info"
      }

      Telemetry.emit_tool_start(metadata)
      start_time = System.monotonic_time()

      result = %{node: "test@host", uptime_seconds: 3600}

      Telemetry.emit_tool_stop(metadata, result, start_time)

      assert_receive {:telemetry, [:beamlens, :tool, :start], start_measurements, start_metadata}
      assert is_integer(start_measurements.system_time)
      assert start_metadata.trace_id == "test-trace-emit"
      assert start_metadata.tool_name == "get_system_info"

      assert_receive {:telemetry, [:beamlens, :tool, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_metadata.trace_id == "test-trace-emit"
      assert stop_metadata.result == result
      assert stop_metadata.result.node == "test@host"

      :telemetry.detach("test-emit-tool-handler-#{inspect(ref)}")
    end
  end

  describe "emit_judge_start/1 and emit_judge_stop/3" do
    test "emits start and stop events with verdict and duration" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "test-emit-judge-handler-#{inspect(ref)}",
        [
          [:beamlens, :judge, :start],
          [:beamlens, :judge, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      metadata = %{
        trace_id: "test-judge-trace",
        attempt: 1
      }

      Telemetry.emit_judge_start(metadata)
      start_time = System.monotonic_time()

      judge_event = %{verdict: :accept}

      Telemetry.emit_judge_stop(metadata, judge_event, start_time)

      assert_receive {:telemetry, [:beamlens, :judge, :start], start_measurements, start_metadata}
      assert is_integer(start_measurements.system_time)
      assert start_metadata.trace_id == "test-judge-trace"
      assert start_metadata.attempt == 1

      assert_receive {:telemetry, [:beamlens, :judge, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_metadata.trace_id == "test-judge-trace"
      assert stop_metadata.verdict == :accept

      :telemetry.detach("test-emit-judge-handler-#{inspect(ref)}")
    end
  end

  describe "emit_judge_exception/5" do
    test "emits exception event with error details" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-emit-judge-exception-handler-#{inspect(ref)}",
        [:beamlens, :judge, :exception],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      metadata = %{
        trace_id: "test-judge-exception-trace",
        attempt: 2
      }

      start_time = System.monotonic_time()
      error = :timeout

      Telemetry.emit_judge_exception(metadata, error, start_time)

      assert_receive {:telemetry, [:beamlens, :judge, :exception], measurements, event_metadata}
      assert is_integer(measurements.duration)
      assert event_metadata.trace_id == "test-judge-exception-trace"
      assert event_metadata.attempt == 2
      assert event_metadata.kind == :error
      assert event_metadata.reason == :timeout

      :telemetry.detach("test-emit-judge-exception-handler-#{inspect(ref)}")
    end
  end

  describe "attach_default_logger/1" do
    test "attaches handler to all event names" do
      # Clean up any existing handler first
      :telemetry.detach("beamlens-telemetry-default-logger")

      assert :ok = Telemetry.attach_default_logger()

      # Verify handler is attached by emitting an event and checking no crash
      :telemetry.execute([:beamlens, :tool, :start], %{system_time: 123}, %{trace_id: "test"})

      # Clean up
      assert :ok = Telemetry.detach_default_logger()
    end

    test "returns error when already attached" do
      :telemetry.detach("beamlens-telemetry-default-logger")

      assert :ok = Telemetry.attach_default_logger()
      assert {:error, :already_exists} = Telemetry.attach_default_logger()

      # Clean up
      Telemetry.detach_default_logger()
    end

    test "accepts custom log level" do
      :telemetry.detach("beamlens-telemetry-default-logger")

      assert :ok = Telemetry.attach_default_logger(level: :info)

      # Clean up
      Telemetry.detach_default_logger()
    end
  end

  describe "detach_default_logger/0" do
    test "detaches the handler" do
      :telemetry.detach("beamlens-telemetry-default-logger")
      Telemetry.attach_default_logger()

      assert :ok = Telemetry.detach_default_logger()
    end

    test "returns error when not attached" do
      :telemetry.detach("beamlens-telemetry-default-logger")

      assert {:error, :not_found} = Telemetry.detach_default_logger()
    end
  end
end
