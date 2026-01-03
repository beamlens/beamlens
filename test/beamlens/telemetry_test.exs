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
    test "returns all 13 event names" do
      events = Telemetry.event_names()

      assert length(events) == 13
    end

    test "all events start with :beamlens" do
      events = Telemetry.event_names()

      for event <- events do
        assert [:beamlens | _] = event
      end
    end

    test "includes agent, llm, tool, and schedule events" do
      events = Telemetry.event_names()

      assert [:beamlens, :agent, :start] in events
      assert [:beamlens, :agent, :stop] in events
      assert [:beamlens, :agent, :exception] in events
      assert [:beamlens, :llm, :call_start] in events
      assert [:beamlens, :llm, :call_stop] in events
      assert [:beamlens, :llm, :call_error] in events
      assert [:beamlens, :tool, :start] in events
      assert [:beamlens, :tool, :stop] in events
      assert [:beamlens, :tool, :exception] in events
      assert [:beamlens, :schedule, :triggered] in events
      assert [:beamlens, :schedule, :skipped] in events
      assert [:beamlens, :schedule, :completed] in events
      assert [:beamlens, :schedule, :failed] in events
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
      assert %RuntimeError{} = event_metadata.error

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
end
