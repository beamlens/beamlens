defmodule Beamlens.Skill.Beam.AtomStoreTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.Skill.Beam.AtomStore

  @moduletag :capture_log

  describe "start_link/1" do
    test "starts the atom store" do
      start_supervised!({AtomStore, [name: AtomStore]})

      assert Process.whereis(AtomStore) != nil
    end
  end

  describe "get_samples/0" do
    test "returns list of samples" do
      start_supervised!({AtomStore, [name: AtomStore]})

      samples = AtomStore.get_samples()

      assert is_list(samples)
    end

    test "samples contain timestamp, count, and limit" do
      start_supervised!({AtomStore, [name: AtomStore]})

      samples = AtomStore.get_samples()

      assert samples != []

      [sample | _] = samples

      assert is_integer(sample.timestamp)
      assert is_integer(sample.count)
      assert is_integer(sample.limit)
    end
  end

  describe "get_latest/0" do
    test "returns most recent sample" do
      start_supervised!({AtomStore, [name: AtomStore]})

      latest = AtomStore.get_latest()

      assert latest != nil
      assert is_integer(latest.timestamp)
      assert is_integer(latest.count)
      assert is_integer(latest.limit)
    end

    test "returns newest sample not oldest" do
      start_supervised!({AtomStore, [name: AtomStore]})

      samples = AtomStore.get_samples()
      latest = AtomStore.get_latest()

      assert latest == List.last(samples)
    end
  end
end
