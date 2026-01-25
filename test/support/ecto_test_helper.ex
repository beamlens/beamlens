defmodule Beamlens.EctoTestHelper do
  @moduledoc false

  alias Beamlens.Skill.Ecto.TelemetryStore

  @doc """
  Builds a telemetry event measurements map with the given options.

  ## Options

    * `:total_time_ms` - Total query time in milliseconds (default: 10)
    * `:queue_time_ms` - Queue/wait time in milliseconds (default: 0)
    * `:result` - `:ok` or `:error` (default: :ok)
    * `:source` - Source location string (default: nil)

  """
  def build_query_event(opts \\ []) do
    total_time_ms = Keyword.get(opts, :total_time_ms, 10)
    queue_time_ms = Keyword.get(opts, :queue_time_ms, 0)
    result = Keyword.get(opts, :result, :ok)
    source = Keyword.get(opts, :source, nil)

    measurements = %{
      total_time: ms_to_native(total_time_ms),
      query_time: ms_to_native(total_time_ms * 0.8),
      decode_time: ms_to_native(total_time_ms * 0.1),
      queue_time: ms_to_native(queue_time_ms),
      idle_time: ms_to_native(0)
    }

    metadata = %{
      source: source,
      result: if(result == :ok, do: {:ok, []}, else: {:error, :fake_error})
    }

    {measurements, metadata}
  end

  @doc """
  Injects a query event via telemetry for the given repo.

  ## Options

  See `build_query_event/1` for available options.
  """
  def inject_query(repo, opts \\ []) do
    {measurements, metadata} = build_query_event(opts)
    telemetry_prefix = repo.config()[:telemetry_prefix]
    :telemetry.execute(telemetry_prefix ++ [:query], measurements, metadata)

    TelemetryStore.flush(repo)
  end

  @doc """
  Convenience for injecting a slow query (200ms by default).
  """
  def inject_slow_query(repo, opts \\ []) do
    opts = Keyword.put_new(opts, :total_time_ms, 200)
    inject_query(repo, opts)
  end

  @doc """
  Convenience for injecting an error query.
  """
  def inject_error_query(repo, opts \\ []) do
    opts = Keyword.put(opts, :result, :error)
    inject_query(repo, opts)
  end

  @doc """
  Converts milliseconds to native time units.
  """
  def ms_to_native(ms) do
    System.convert_time_unit(trunc(ms * 1000), :microsecond, :native)
  end
end
