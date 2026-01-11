defmodule Beamlens.Skill.SupTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Skill.Sup

  describe "id/0" do
    test "returns :sup" do
      assert Sup.id() == :sup
    end
  end

  describe "snapshot/0" do
    test "returns supervisor count and children" do
      snapshot = Sup.snapshot()

      assert is_integer(snapshot.supervisor_count)
      assert is_integer(snapshot.total_children)
    end

    test "supervisor_count is non-negative" do
      snapshot = Sup.snapshot()
      assert snapshot.supervisor_count >= 0
    end
  end

  describe "callbacks/0" do
    test "returns callback map with expected keys" do
      callbacks = Sup.callbacks()

      assert is_map(callbacks)
      assert Map.has_key?(callbacks, "sup_list")
      assert Map.has_key?(callbacks, "sup_children")
      assert Map.has_key?(callbacks, "sup_tree")
    end

    test "callbacks are functions with correct arity" do
      callbacks = Sup.callbacks()

      assert is_function(callbacks["sup_list"], 0)
      assert is_function(callbacks["sup_children"], 1)
      assert is_function(callbacks["sup_tree"], 1)
    end
  end

  describe "sup_list callback" do
    test "returns list of supervisors" do
      result = Sup.callbacks()["sup_list"].()

      assert is_list(result)
    end

    test "supervisor entries have expected fields when supervisors exist" do
      result = Sup.callbacks()["sup_list"].()

      if result != [] do
        [sup | _] = result
        assert Map.has_key?(sup, :name)
        assert Map.has_key?(sup, :pid)
        assert Map.has_key?(sup, :child_count)
        assert Map.has_key?(sup, :active_children)
      end
    end
  end

  describe "sup_children callback" do
    test "returns error for non-existent supervisor" do
      result = Sup.callbacks()["sup_children"].("nonexistent_supervisor_xyz")

      assert result.error == "supervisor_not_found"
    end
  end

  describe "sup_tree callback" do
    test "returns error for non-existent supervisor" do
      result = Sup.callbacks()["sup_tree"].("nonexistent_supervisor_xyz")

      assert result.error == "supervisor_not_found"
    end
  end

  describe "callback_docs/0" do
    test "returns non-empty string" do
      docs = Sup.callback_docs()

      assert is_binary(docs)
      assert String.length(docs) > 0
    end

    test "documents all callbacks" do
      docs = Sup.callback_docs()

      assert docs =~ "sup_list"
      assert docs =~ "sup_children"
      assert docs =~ "sup_tree"
    end
  end
end
