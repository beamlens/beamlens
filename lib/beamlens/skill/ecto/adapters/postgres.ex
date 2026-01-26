defmodule Beamlens.Skill.Ecto.Adapters.Postgres do
  @moduledoc """
  PostgreSQL-specific database insights via ecto_psql_extras.

  Most functions return data from pg_stat_statements which uses parameterized
  SQL ($1, $2 placeholders) to avoid PII exposure. Functions that query
  pg_stat_activity (locks, long_running_queries) exclude query text entirely
  to prevent PII exposure.
  """

  @compile {:no_warn_undefined, EctoPSQLExtras}

  @locks_excluded_columns ~w(query_snippet)
  @long_running_excluded_columns ~w(query)

  @doc """
  Checks if ecto_psql_extras is available.
  """
  def available? do
    Code.ensure_loaded?(EctoPSQLExtras)
  end

  @doc """
  Index usage statistics showing scan counts per index.
  """
  def index_usage(repo) do
    with_extras(fn ->
      case EctoPSQLExtras.index_usage(repo, format: :raw) do
        {:ok, %{rows: rows, columns: columns}} ->
          format_rows(rows, columns)

        {:error, reason} ->
          %{error: inspect(reason)}
      end
    end)
  end

  @doc """
  Indexes with zero scans that may be candidates for removal.
  """
  def unused_indexes(repo) do
    with_extras(fn ->
      case EctoPSQLExtras.unused_indexes(repo, format: :raw) do
        {:ok, %{rows: rows, columns: columns}} ->
          format_rows(rows, columns)

        {:error, reason} ->
          %{error: inspect(reason)}
      end
    end)
  end

  @doc """
  Table sizes including row counts, table size, and index size.
  """
  def table_sizes(repo, limit \\ 20) do
    with_extras(fn ->
      case EctoPSQLExtras.table_size(repo, format: :raw) do
        {:ok, %{rows: rows, columns: columns}} ->
          rows
          |> Enum.take(limit)
          |> format_rows(columns)

        {:error, reason} ->
          %{error: inspect(reason)}
      end
    end)
  end

  @doc """
  Buffer cache hit ratios for tables and indexes.
  """
  def cache_hit(repo) do
    with_extras(fn ->
      case EctoPSQLExtras.cache_hit(repo, format: :raw) do
        {:ok, %{rows: rows, columns: columns}} ->
          format_rows(rows, columns)

        {:error, reason} ->
          %{error: inspect(reason)}
      end
    end)
  end

  @doc """
  Active database locks.

  Query text is excluded to prevent PII exposure.
  """
  def locks(repo) do
    with_extras(fn ->
      case EctoPSQLExtras.locks(repo, format: :raw) do
        {:ok, %{rows: rows, columns: columns}} ->
          format_rows(rows, columns, @locks_excluded_columns)

        {:error, reason} ->
          %{error: inspect(reason)}
      end
    end)
  end

  @doc """
  Long-running queries exceeding threshold.

  Query text is excluded to prevent PII exposure.
  """
  def long_running_queries(repo) do
    with_extras(fn ->
      case EctoPSQLExtras.long_running_queries(repo, format: :raw) do
        {:ok, %{rows: rows, columns: columns}} ->
          format_rows(rows, columns, @long_running_excluded_columns)

        {:error, reason} ->
          %{error: inspect(reason)}
      end
    end)
  end

  @doc """
  Table and index bloat statistics.
  """
  def bloat(repo, limit \\ 20) do
    with_extras(fn ->
      case EctoPSQLExtras.bloat(repo, format: :raw) do
        {:ok, %{rows: rows, columns: columns}} ->
          rows
          |> Enum.take(limit)
          |> format_rows(columns)

        {:error, reason} ->
          %{error: inspect(reason)}
      end
    end)
  end

  @doc """
  Slow queries from pg_stat_statements.

  Query text is parameterized (e.g., "SELECT * FROM users WHERE id = $1")
  to avoid exposing PII.
  """
  def slow_queries(repo, limit \\ 10) do
    with_extras(fn ->
      case EctoPSQLExtras.outliers(repo, format: :raw) do
        {:ok, %{rows: rows, columns: columns}} ->
          rows
          |> Enum.take(limit)
          |> format_rows(columns)

        {:error, reason} ->
          %{error: inspect(reason)}
      end
    end)
  end

  @doc """
  Database connections status.
  """
  def connections(repo) do
    with_extras(fn ->
      case EctoPSQLExtras.connections(repo, format: :raw) do
        {:ok, %{rows: rows, columns: columns}} ->
          format_rows(rows, columns)

        {:error, reason} ->
          %{error: inspect(reason)}
      end
    end)
  end

  defp with_extras(fun) do
    if available?() do
      fun.()
    else
      %{error: "ecto_psql_extras not available"}
    end
  end

  defp format_rows(rows, columns, excluded \\ []) do
    excluded_set = MapSet.new(excluded)

    column_names =
      columns
      |> Enum.reject(&MapSet.member?(excluded_set, &1))

    column_indices =
      columns
      |> Enum.with_index()
      |> Enum.reject(fn {col, _idx} -> MapSet.member?(excluded_set, col) end)
      |> Enum.map(fn {_col, idx} -> idx end)

    Enum.map(rows, fn row ->
      values = Enum.map(column_indices, &Enum.at(row, &1))

      column_names
      |> Enum.zip(values)
      |> Map.new()
    end)
  end
end
