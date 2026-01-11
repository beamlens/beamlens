defmodule Beamlens.Skill.Ecto.Adapters.GenericTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Skill.Ecto.Adapters.Generic

  @not_available %{error: "not_available_for_this_database"}

  describe "available?/0" do
    test "returns true" do
      assert Generic.available?() == true
    end
  end

  describe "adapter functions return not_available error" do
    test "index_usage/1" do
      assert Generic.index_usage(:fake_repo) == @not_available
    end

    test "unused_indexes/1" do
      assert Generic.unused_indexes(:fake_repo) == @not_available
    end

    test "table_sizes/2" do
      assert Generic.table_sizes(:fake_repo) == @not_available
      assert Generic.table_sizes(:fake_repo, 10) == @not_available
    end

    test "cache_hit/1" do
      assert Generic.cache_hit(:fake_repo) == @not_available
    end

    test "locks/1" do
      assert Generic.locks(:fake_repo) == @not_available
    end

    test "long_running_queries/1" do
      assert Generic.long_running_queries(:fake_repo) == @not_available
    end

    test "bloat/2" do
      assert Generic.bloat(:fake_repo) == @not_available
      assert Generic.bloat(:fake_repo, 10) == @not_available
    end

    test "slow_queries/2" do
      assert Generic.slow_queries(:fake_repo) == @not_available
      assert Generic.slow_queries(:fake_repo, 5) == @not_available
    end

    test "connections/1" do
      assert Generic.connections(:fake_repo) == @not_available
    end
  end
end
