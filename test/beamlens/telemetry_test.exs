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
    test "returns all 32 event names" do
      events = Telemetry.event_names()

      assert length(events) == 32
    end

    test "all events start with :beamlens" do
      events = Telemetry.event_names()

      for event <- events do
        assert [:beamlens | _] = event
      end
    end

    test "includes llm, tool, and watcher events" do
      events = Telemetry.event_names()

      assert [:beamlens, :llm, :start] in events
      assert [:beamlens, :llm, :stop] in events
      assert [:beamlens, :llm, :exception] in events
      assert [:beamlens, :tool, :start] in events
      assert [:beamlens, :tool, :stop] in events
      assert [:beamlens, :tool, :exception] in events
      assert [:beamlens, :watcher, :started] in events
      assert [:beamlens, :watcher, :alert_fired] in events
      assert [:beamlens, :watcher, :state_change] in events
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

  describe "emit_tool_exception/5" do
    test "emits exception event with error details" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-emit-tool-exception-handler-#{inspect(ref)}",
        [:beamlens, :tool, :exception],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      metadata = %{
        trace_id: "test-tool-exception-trace",
        iteration: 2,
        tool_name: "execute"
      }

      start_time = System.monotonic_time()
      error = :timeout

      Telemetry.emit_tool_exception(metadata, error, start_time)

      assert_receive {:telemetry, [:beamlens, :tool, :exception], measurements, event_metadata}
      assert is_integer(measurements.duration)
      assert event_metadata.trace_id == "test-tool-exception-trace"
      assert event_metadata.kind == :error
      assert event_metadata.reason == :timeout

      :telemetry.detach("test-emit-tool-exception-handler-#{inspect(ref)}")
    end
  end

  describe "attach_default_logger/1" do
    test "attaches handler to all event names" do
      :telemetry.detach("beamlens-telemetry-default-logger")

      assert :ok = Telemetry.attach_default_logger()

      :telemetry.execute([:beamlens, :tool, :start], %{system_time: 123}, %{trace_id: "test"})

      assert :ok = Telemetry.detach_default_logger()
    end

    test "returns error when already attached" do
      :telemetry.detach("beamlens-telemetry-default-logger")

      assert :ok = Telemetry.attach_default_logger()
      assert {:error, :already_exists} = Telemetry.attach_default_logger()

      Telemetry.detach_default_logger()
    end

    test "accepts custom log level" do
      :telemetry.detach("beamlens-telemetry-default-logger")

      assert :ok = Telemetry.attach_default_logger(level: :info)

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
