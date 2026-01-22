defmodule Beamlens.Skill.SupTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Skill.Sup

  describe "title/0" do
    test "returns a non-empty string" do
      title = Sup.title()

      assert is_binary(title)
      assert String.length(title) > 0
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      description = Sup.description()

      assert is_binary(description)
      assert String.length(description) > 0
    end
  end

  describe "system_prompt/0" do
    test "returns a non-empty string" do
      system_prompt = Sup.system_prompt()

      assert is_binary(system_prompt)
      assert String.length(system_prompt) > 0
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
      assert Map.has_key?(callbacks, "sup_unlinked_processes")
      assert Map.has_key?(callbacks, "sup_orphaned_processes")
      assert Map.has_key?(callbacks, "sup_tree_integrity")
      assert Map.has_key?(callbacks, "sup_zombie_children")
    end

    test "callbacks are functions with correct arity" do
      callbacks = Sup.callbacks()

      assert is_function(callbacks["sup_list"], 0)
      assert is_function(callbacks["sup_children"], 1)
      assert is_function(callbacks["sup_tree"], 1)
      assert is_function(callbacks["sup_unlinked_processes"], 0)
      assert is_function(callbacks["sup_orphaned_processes"], 0)
      assert is_function(callbacks["sup_tree_integrity"], 1)
      assert is_function(callbacks["sup_zombie_children"], 1)
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
      assert docs =~ "sup_unlinked_processes"
      assert docs =~ "sup_orphaned_processes"
      assert docs =~ "sup_tree_integrity"
      assert docs =~ "sup_zombie_children"
    end
  end

  describe "sup_unlinked_processes callback" do
    test "returns a list" do
      result = Sup.callbacks()["sup_unlinked_processes"].()

      assert is_list(result)
    end

    test "process entries have expected fields when unlinked processes exist" do
      result = Sup.callbacks()["sup_unlinked_processes"].()

      if result != [] do
        [proc | _] = result
        assert Map.has_key?(proc, :pid)
        assert Map.has_key?(proc, :registered_name)
        assert Map.has_key?(proc, :initial_call)
        assert Map.has_key?(proc, :current_function)
        assert Map.has_key?(proc, :memory_mb)
        assert Map.has_key?(proc, :message_queue_len)
      end
    end
  end

  describe "sup_orphaned_processes callback" do
    test "returns a list" do
      result = Sup.callbacks()["sup_orphaned_processes"].()

      assert is_list(result)
    end

    test "process entries have expected fields when orphaned processes exist" do
      result = Sup.callbacks()["sup_orphaned_processes"].()

      if result != [] do
        [proc | _] = result
        assert Map.has_key?(proc, :pid)
        assert Map.has_key?(proc, :registered_name)
        assert Map.has_key?(proc, :initial_call)
        assert Map.has_key?(proc, :dead_ancestor_pids)
        assert Map.has_key?(proc, :age_seconds)
      end
    end
  end

  describe "sup_tree_integrity callback" do
    test "returns error for non-existent supervisor" do
      result = Sup.callbacks()["sup_tree_integrity"].("nonexistent_supervisor_xyz")

      assert result.error == "supervisor_not_found"
    end

    test "returns integrity map for valid supervisor when supervisors exist" do
      supervisors = Sup.callbacks()["sup_list"].()

      if supervisors != [] do
        sup_name = hd(supervisors).name
        result = Sup.callbacks()["sup_tree_integrity"].(sup_name)

        refute Map.has_key?(result, :error)
        assert Map.has_key?(result, :supervisor_name)
        assert Map.has_key?(result, :total_children)
        assert Map.has_key?(result, :active_children)
        assert Map.has_key?(result, :undefined_children)
        assert Map.has_key?(result, :restarting_children)
        assert Map.has_key?(result, :anomalies)
        assert is_list(result.anomalies)
      end
    end
  end

  describe "sup_zombie_children callback" do
    test "returns error for non-existent supervisor" do
      result = Sup.callbacks()["sup_zombie_children"].("nonexistent_supervisor_xyz")

      assert result.error == "supervisor_not_found"
    end

    test "returns zombie children map for valid supervisor when supervisors exist" do
      supervisors = Sup.callbacks()["sup_list"].()

      if supervisors != [] do
        sup_name = hd(supervisors).name
        result = Sup.callbacks()["sup_zombie_children"].(sup_name)

        refute Map.has_key?(result, :error)
        assert Map.has_key?(result, :supervisor_name)
        assert Map.has_key?(result, :status)
      end
    end
  end
end
