defmodule Beamlens.Domain.ExceptionTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.Domain.Exception, as: ExceptionDomain
  alias Beamlens.Domain.Exception.ExceptionStore

  setup do
    start_supervised!({ExceptionStore, name: ExceptionStore})
    :ok
  end

  describe "domain/0" do
    test "returns :exception" do
      assert ExceptionDomain.domain() == :exception
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
