defmodule Beamlens.ExceptionTestHelper do
  @moduledoc false

  alias Beamlens.Skill.Exception.ExceptionStore

  def build_event(opts) do
    %Tower.Event{
      id: Keyword.get(opts, :id, UUIDv7.generate()),
      datetime: Keyword.get(opts, :datetime, DateTime.utc_now()),
      level: Keyword.get(opts, :level, :error),
      kind: Keyword.get(opts, :kind, :error),
      reason: Keyword.get(opts, :reason, %ArgumentError{message: "test error"}),
      stacktrace: Keyword.get(opts, :stacktrace, default_stacktrace()),
      log_event: nil,
      plug_conn: nil,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  def inject_exception(reason, opts \\ []) do
    event = build_event(Keyword.put(opts, :reason, reason))
    GenServer.cast(ExceptionStore, {:exception_event, event})
    ExceptionStore.flush()
    event
  end

  defp default_stacktrace do
    [{TestModule, :test_fn, 1, [file: ~c"test.ex", line: 1]}]
  end
end
