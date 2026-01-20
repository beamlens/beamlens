defmodule Beamlens.Skill.ExceptionTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Beamlens.ExceptionTestHelper

  alias Beamlens.Skill.Exception, as: ExceptionDomain
  alias Beamlens.Skill.Exception.ExceptionStore

  setup do
    start_supervised!({ExceptionStore, name: ExceptionStore})
    :ok
  end

  describe "title/0" do
    test "returns a non-empty string" do
      title = ExceptionDomain.title()

      assert is_binary(title)
      assert String.length(title) > 0
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      description = ExceptionDomain.description()

      assert is_binary(description)
      assert String.length(description) > 0
    end
  end

  describe "system_prompt/0" do
    test "returns a non-empty string" do
      system_prompt = ExceptionDomain.system_prompt()

      assert is_binary(system_prompt)
      assert String.length(system_prompt) > 0
    end
  end

  describe "snapshot/0" do
    test "returns expected keys" do
      snapshot = ExceptionDomain.snapshot()

      assert Map.has_key?(snapshot, :total_exceptions_5m)
      assert Map.has_key?(snapshot, :by_kind)
      assert Map.has_key?(snapshot, :by_level)
      assert Map.has_key?(snapshot, :top_exception_types)
      assert Map.has_key?(snapshot, :unique_exception_types)
    end

    test "returns correct types" do
      snapshot = ExceptionDomain.snapshot()

      assert is_integer(snapshot.total_exceptions_5m)
      assert is_map(snapshot.by_kind)
      assert is_map(snapshot.by_level)
      assert is_list(snapshot.top_exception_types)
      assert is_integer(snapshot.unique_exception_types)
    end

    test "total_exceptions_5m reflects injected exception count" do
      inject_exception(%RuntimeError{message: "error 1"})
      inject_exception(%RuntimeError{message: "error 2"})
      inject_exception(%ArgumentError{message: "error 3"})

      snapshot = ExceptionDomain.snapshot()

      assert snapshot.total_exceptions_5m == 3
    end

    test "by_kind counts match injected exception kinds" do
      inject_exception(%RuntimeError{message: "error"}, kind: :error)
      inject_exception(%RuntimeError{message: "exit"}, kind: :exit)
      inject_exception(%RuntimeError{message: "exit 2"}, kind: :exit)

      snapshot = ExceptionDomain.snapshot()

      assert snapshot.by_kind.error == 1
      assert snapshot.by_kind.exit == 2
    end

    test "top_exception_types includes injected types" do
      inject_exception(%ArgumentError{message: "arg 1"})
      inject_exception(%ArgumentError{message: "arg 2"})
      inject_exception(%RuntimeError{message: "runtime"})

      snapshot = ExceptionDomain.snapshot()

      assert %{type: "ArgumentError", count: 2} in snapshot.top_exception_types
      assert %{type: "RuntimeError", count: 1} in snapshot.top_exception_types
    end

    test "unique_exception_types reflects distinct types" do
      inject_exception(%ArgumentError{message: "arg"})
      inject_exception(%RuntimeError{message: "runtime"})
      inject_exception(%KeyError{key: :foo, term: %{}})

      snapshot = ExceptionDomain.snapshot()

      assert snapshot.unique_exception_types == 3
    end
  end

  describe "callbacks/0" do
    test "returns all expected callback keys" do
      callbacks = ExceptionDomain.callbacks()

      assert Map.has_key?(callbacks, "exception_stats")
      assert Map.has_key?(callbacks, "exception_recent")
      assert Map.has_key?(callbacks, "exception_by_type")
      assert Map.has_key?(callbacks, "exception_search")
      assert Map.has_key?(callbacks, "exception_stacktrace")
    end

    test "all callbacks are functions" do
      callbacks = ExceptionDomain.callbacks()

      Enum.each(callbacks, fn {name, callback} ->
        assert is_function(callback), "#{name} should be a function"
      end)
    end

    test "exception_stats callback returns stats" do
      callbacks = ExceptionDomain.callbacks()
      stats = callbacks["exception_stats"].()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_count)
      assert Map.has_key?(stats, :by_kind)
    end

    test "exception_recent callback returns exceptions" do
      callbacks = ExceptionDomain.callbacks()
      exceptions = callbacks["exception_recent"].(10, nil)

      assert is_list(exceptions)
    end

    test "exception_by_type callback returns exceptions" do
      callbacks = ExceptionDomain.callbacks()
      exceptions = callbacks["exception_by_type"].("ArgumentError", 10)

      assert is_list(exceptions)
    end

    test "exception_search callback returns results" do
      callbacks = ExceptionDomain.callbacks()
      results = callbacks["exception_search"].("test", 10)

      assert is_list(results)
    end

    test "exception_stacktrace callback returns nil for unknown id" do
      callbacks = ExceptionDomain.callbacks()
      result = callbacks["exception_stacktrace"].("unknown-id")

      assert is_nil(result)
    end
  end

  describe "callbacks with injected data" do
    test "exception_stats returns counts matching injected exceptions" do
      inject_exception(%RuntimeError{message: "error 1"})
      inject_exception(%RuntimeError{message: "error 2"})
      inject_exception(%ArgumentError{message: "arg error"}, kind: :exit)

      callbacks = ExceptionDomain.callbacks()
      stats = callbacks["exception_stats"].()

      assert stats.total_count == 3
      assert stats.by_kind.error == 2
      assert stats.by_kind.exit == 1
    end

    test "exception_recent returns injected exceptions in order" do
      inject_exception(%RuntimeError{message: "first"})
      inject_exception(%RuntimeError{message: "second"})
      inject_exception(%RuntimeError{message: "third"})

      callbacks = ExceptionDomain.callbacks()
      exceptions = callbacks["exception_recent"].(10, nil)

      assert length(exceptions) == 3
      messages = Enum.map(exceptions, & &1.message)
      assert messages == ["first", "second", "third"]
    end

    test "exception_recent filters by kind correctly" do
      inject_exception(%RuntimeError{message: "error"}, kind: :error)
      inject_exception(%RuntimeError{message: "exit"}, kind: :exit)
      inject_exception(%RuntimeError{message: "throw"}, kind: :throw)

      callbacks = ExceptionDomain.callbacks()
      error_exceptions = callbacks["exception_recent"].(10, "error")
      exit_exceptions = callbacks["exception_recent"].(10, "exit")

      assert length(error_exceptions) == 1
      assert hd(error_exceptions).kind == :error

      assert length(exit_exceptions) == 1
      assert hd(exit_exceptions).kind == :exit
    end

    test "exception_by_type finds matching type and excludes others" do
      inject_exception(%ArgumentError{message: "arg error"})
      inject_exception(%RuntimeError{message: "runtime error"})
      inject_exception(%ArgumentError{message: "another arg error"})

      callbacks = ExceptionDomain.callbacks()
      arg_errors = callbacks["exception_by_type"].("ArgumentError", 10)
      runtime_errors = callbacks["exception_by_type"].("RuntimeError", 10)

      assert length(arg_errors) == 2
      assert Enum.all?(arg_errors, &(&1.type == "ArgumentError"))

      assert length(runtime_errors) == 1
      assert hd(runtime_errors).type == "RuntimeError"
    end

    test "exception_search matches message patterns" do
      inject_exception(%RuntimeError{message: "database connection failed"})
      inject_exception(%RuntimeError{message: "authentication error"})
      inject_exception(%RuntimeError{message: "database timeout"})

      callbacks = ExceptionDomain.callbacks()
      results = callbacks["exception_search"].("database", 10)

      assert length(results) == 2
      assert Enum.all?(results, &String.contains?(&1.message, "database"))
    end

    test "exception_stacktrace returns stacktrace for known id" do
      stacktrace = [
        {MyModule, :my_function, 2, [file: ~c"lib/my_module.ex", line: 42]},
        {OtherModule, :other_function, 1, [file: ~c"lib/other_module.ex", line: 10]}
      ]

      event = inject_exception(%RuntimeError{message: "test"}, stacktrace: stacktrace)

      callbacks = ExceptionDomain.callbacks()
      result = callbacks["exception_stacktrace"].(event.id)

      assert length(result) == 2
      [first, second] = result
      assert first.module == "MyModule"
      assert first.function == "my_function/2"
      assert first.line == 42
      assert second.module == "OtherModule"
    end

    test "exception_recent respects limit" do
      for i <- 1..10 do
        inject_exception(%RuntimeError{message: "error #{i}"})
      end

      callbacks = ExceptionDomain.callbacks()
      exceptions = callbacks["exception_recent"].(5, nil)

      assert length(exceptions) == 5
    end
  end

  describe "callback_docs/0" do
    test "returns documentation string" do
      docs = ExceptionDomain.callback_docs()

      assert is_binary(docs)
      assert String.contains?(docs, "exception_stats")
      assert String.contains?(docs, "exception_recent")
      assert String.contains?(docs, "exception_by_type")
      assert String.contains?(docs, "exception_search")
      assert String.contains?(docs, "exception_stacktrace")
    end
  end
end
