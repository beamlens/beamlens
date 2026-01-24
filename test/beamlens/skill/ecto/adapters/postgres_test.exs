defmodule Beamlens.Skill.Ecto.Adapters.PostgresTest do
  use ExUnit.Case, async: true

  alias Beamlens.Skill.Ecto.Adapters.Postgres

  describe "format_rows/3" do
    test "transforms rows to maps with string keys" do
      columns = ["name", "size", "count"]
      rows = [["users", 1024, 100], ["posts", 2048, 50]]

      result = Postgres.format_rows(rows, columns)

      assert result == [
               %{"name" => "users", "size" => 1024, "count" => 100},
               %{"name" => "posts", "size" => 2048, "count" => 50}
             ]
    end

    test "excludes specified columns" do
      columns = ["name", "query", "duration"]
      rows = [["lock1", "SELECT * FROM users", 100]]

      result = Postgres.format_rows(rows, columns, ["query"])

      assert result == [%{"name" => "lock1", "duration" => 100}]
    end

    test "handles empty rows" do
      columns = ["name", "size"]
      rows = []

      result = Postgres.format_rows(rows, columns)

      assert result == []
    end

    test "handles empty excluded list" do
      columns = ["a", "b"]
      rows = [[1, 2]]

      result = Postgres.format_rows(rows, columns, [])

      assert result == [%{"a" => 1, "b" => 2}]
    end
  end
end
