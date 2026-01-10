defmodule Beamlens.Domain.Exception.ExceptionStoreTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.Domain.Exception.ExceptionStore

  @test_name :test_exception_store

  setup do
    {:ok, pid} = start_supervised({ExceptionStore, name: @test_name, max_size: 100})
    {:ok, store: pid}
  end

  defp build_event(opts) do
    %Tower.Event{
      id: Keyword.get(opts, :id, UUIDv7.generate()),
      datetime: Keyword.get(opts, :datetime, DateTime.utc_now()),
      level: Keyword.get(opts, :level, :error),
      kind: Keyword.get(opts, :kind, :error),
      reason: Keyword.get(opts, :reason, %ArgumentError{message: "test error"}),
      stacktrace:
        Keyword.get(opts, :stacktrace, [
          {MyModule, :my_function, 2, [file: ~c"lib/my_module.ex", line: 42]}
        ]),
      log_event: nil,
      plug_conn: nil,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp report_event(name, event) do
    GenServer.cast(name, {:exception_event, event})
    ExceptionStore.flush(name)
  end

  describe "get_stats/1" do
    test "returns empty stats when no exceptions" do
      stats = ExceptionStore.get_stats(@test_name)

      assert stats.total_count == 0
      assert stats.by_kind == %{error: 0, exit: 0, throw: 0, message: 0}
      assert stats.by_level == %{}
      assert stats.top_types == []
      assert stats.type_count == 0
    end

    test "aggregates exception events by kind" do
      report_event(@test_name, build_event(kind: :error))
      report_event(@test_name, build_event(kind: :exit, reason: :normal))
      report_event(@test_name, build_event(kind: :throw, reason: :some_value))

      stats = ExceptionStore.get_stats(@test_name)

      assert stats.total_count == 3
      assert stats.by_kind.error == 1
      assert stats.by_kind.exit == 1
      assert stats.by_kind.throw == 1
    end

    test "aggregates by level" do
      report_event(@test_name, build_event(level: :error))
      report_event(@test_name, build_event(level: :error))
      report_event(@test_name, build_event(level: :warning))

      stats = ExceptionStore.get_stats(@test_name)

      assert stats.by_level.error == 2
      assert stats.by_level.warning == 1
    end

    test "tracks top exception types" do
      report_event(@test_name, build_event(reason: %ArgumentError{message: "arg error"}))
      report_event(@test_name, build_event(reason: %ArgumentError{message: "another arg error"}))
      report_event(@test_name, build_event(reason: %RuntimeError{message: "runtime error"}))

      stats = ExceptionStore.get_stats(@test_name)

      assert stats.type_count == 2
      assert {"ArgumentError", 2} in stats.top_types
      assert {"RuntimeError", 1} in stats.top_types
    end
  end

  describe "get_exceptions/2" do
    test "returns empty list when no exceptions" do
      exceptions = ExceptionStore.get_exceptions(@test_name)
      assert exceptions == []
    end

    test "returns exceptions" do
      report_event(@test_name, build_event(reason: %ArgumentError{message: "first"}))
      report_event(@test_name, build_event(reason: %RuntimeError{message: "second"}))

      exceptions = ExceptionStore.get_exceptions(@test_name)

      assert length(exceptions) == 2
      [first, second] = exceptions
      assert first.message == "first"
      assert second.message == "second"
    end

    test "filters by kind" do
      report_event(@test_name, build_event(kind: :error))
      report_event(@test_name, build_event(kind: :exit, reason: :normal))

      exceptions = ExceptionStore.get_exceptions(@test_name, kind: :error)

      assert length(exceptions) == 1
      assert Enum.all?(exceptions, &(&1.kind == :error))
    end

    test "filters by level" do
      report_event(@test_name, build_event(level: :error))
      report_event(@test_name, build_event(level: :warning))

      exceptions = ExceptionStore.get_exceptions(@test_name, level: :error)

      assert length(exceptions) == 1
      assert Enum.all?(exceptions, &(&1.level == :error))
    end

    test "respects limit" do
      for i <- 1..10 do
        report_event(@test_name, build_event(reason: %RuntimeError{message: "error #{i}"}))
      end

      exceptions = ExceptionStore.get_exceptions(@test_name, limit: 5)

      assert length(exceptions) == 5
    end
  end

  describe "get_by_type/3" do
    test "returns exceptions matching type name" do
      report_event(@test_name, build_event(reason: %ArgumentError{message: "arg error"}))
      report_event(@test_name, build_event(reason: %RuntimeError{message: "runtime error"}))

      exceptions = ExceptionStore.get_by_type(@test_name, "ArgumentError", 10)

      assert length(exceptions) == 1
      assert hd(exceptions).type == "ArgumentError"
    end

    test "returns empty list for no matches" do
      report_event(@test_name, build_event(reason: %ArgumentError{message: "arg error"}))

      exceptions = ExceptionStore.get_by_type(@test_name, "KeyError", 10)

      assert exceptions == []
    end

    test "respects limit" do
      for _ <- 1..10 do
        report_event(@test_name, build_event(reason: %ArgumentError{message: "arg error"}))
      end

      exceptions = ExceptionStore.get_by_type(@test_name, "ArgumentError", 3)

      assert length(exceptions) == 3
    end
  end

  describe "search/3" do
    test "returns matching exceptions" do
      report_event(@test_name, build_event(reason: %RuntimeError{message: "user not found"}))
      report_event(@test_name, build_event(reason: %RuntimeError{message: "user logged out"}))
      report_event(@test_name, build_event(reason: %RuntimeError{message: "system error"}))

      results = ExceptionStore.search(@test_name, "user", limit: 10)

      assert length(results) == 2
    end

    test "returns empty list for no matches" do
      report_event(@test_name, build_event(reason: %RuntimeError{message: "hello world"}))

      results = ExceptionStore.search(@test_name, "xyznotfound123", limit: 10)

      assert results == []
    end

    test "handles invalid regex gracefully" do
      report_event(@test_name, build_event(reason: %RuntimeError{message: "test message"}))

      results = ExceptionStore.search(@test_name, "[invalid", limit: 10)

      assert results == []
    end
  end

  describe "get_stacktrace/2" do
    test "returns stacktrace for exception" do
      event_id = UUIDv7.generate()

      stacktrace = [
        {MyModule, :my_function, 2, [file: ~c"lib/my_module.ex", line: 42]},
        {OtherModule, :other_function, 1, [file: ~c"lib/other_module.ex", line: 10]}
      ]

      report_event(@test_name, build_event(id: event_id, stacktrace: stacktrace))

      result = ExceptionStore.get_stacktrace(@test_name, event_id)

      assert length(result) == 2
      [first, second] = result
      assert first.module == "MyModule"
      assert first.function == "my_function/2"
      assert first.line == 42
      assert second.module == "OtherModule"
    end

    test "returns nil for unknown exception id" do
      result = ExceptionStore.get_stacktrace(@test_name, "unknown-id")
      assert result == nil
    end

    test "formats stacktrace entries with args list" do
      event_id = UUIDv7.generate()

      stacktrace = [
        {MyModule, :my_function, [:arg1, :arg2], [file: ~c"lib/my_module.ex", line: 42]}
      ]

      report_event(@test_name, build_event(id: event_id, stacktrace: stacktrace))

      result = ExceptionStore.get_stacktrace(@test_name, event_id)

      assert [%{function: "my_function/2"}] = result
    end

    test "formats unexpected stacktrace entries with raw inspect" do
      event_id = UUIDv7.generate()
      stacktrace = [{:unexpected_format}]
      report_event(@test_name, build_event(id: event_id, stacktrace: stacktrace))

      result = ExceptionStore.get_stacktrace(@test_name, event_id)

      assert [%{raw: _}] = result
    end
  end

  describe "filter edge cases" do
    test "filter_by_kind returns all entries for non-existent atom kind" do
      report_event(@test_name, build_event(kind: :error))
      exceptions = ExceptionStore.get_exceptions(@test_name, kind: "nonexistent_kind")
      assert length(exceptions) == 1
    end
  end

  describe "message truncation" do
    test "truncates messages exceeding 2048 bytes" do
      long_message = String.duplicate("x", 3000)
      report_event(@test_name, build_event(reason: %RuntimeError{message: long_message}))

      exceptions = ExceptionStore.get_exceptions(@test_name, limit: 1)
      [exception] = exceptions

      assert String.length(exception.message) < 3000
      assert String.ends_with?(exception.message, "... (truncated)")
    end
  end

  describe "ring buffer behavior" do
    test "enforces max size" do
      stop_supervised!(ExceptionStore)
      {:ok, _pid} = start_supervised({ExceptionStore, name: @test_name, max_size: 5})

      for i <- 1..10 do
        report_event(@test_name, build_event(reason: %RuntimeError{message: "error #{i}"}))
      end

      stats = ExceptionStore.get_stats(@test_name)

      assert stats.total_count == 5
    end
  end

  describe "when store not running" do
    test "get_stats returns empty stats for non-existent store" do
      stats = ExceptionStore.get_stats(:nonexistent_store)

      assert stats.total_count == 0
      assert stats.by_kind == %{error: 0, exit: 0, throw: 0, message: 0}
    end

    test "get_exceptions returns empty list for non-existent store" do
      exceptions = ExceptionStore.get_exceptions(:nonexistent_store)
      assert exceptions == []
    end

    test "get_by_type returns empty list for non-existent store" do
      exceptions = ExceptionStore.get_by_type(:nonexistent_store, "ArgumentError", 10)
      assert exceptions == []
    end

    test "search returns empty list for non-existent store" do
      results = ExceptionStore.search(:nonexistent_store, "test", limit: 10)
      assert results == []
    end

    test "get_stacktrace returns nil for non-existent store" do
      result = ExceptionStore.get_stacktrace(:nonexistent_store, "some-id")
      assert result == nil
    end
  end
end
