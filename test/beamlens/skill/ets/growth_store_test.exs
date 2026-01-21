defmodule Beamlens.Skill.Ets.GrowthStoreTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.Skill.Ets.GrowthStore

  @moduletag :capture_log

  describe "start_link/1" do
    test "starts the growth store" do
      start_supervised!({GrowthStore, [name: GrowthStore]})

      assert Process.whereis(GrowthStore) != nil
    end
  end

  describe "get_samples/0" do
    test "returns list of samples" do
      start_supervised!({GrowthStore, [name: GrowthStore]})

      samples = GrowthStore.get_samples()

      assert is_list(samples)
    end

    test "samples contain timestamp and tables" do
      start_supervised!({GrowthStore, [name: GrowthStore]})

      samples = GrowthStore.get_samples()

      assert samples != []

      [sample | _] = samples

      assert is_integer(sample.timestamp)
      assert is_list(sample.tables)
    end
  end

  describe "get_latest/0" do
    test "returns most recent sample" do
      start_supervised!({GrowthStore, [name: GrowthStore]})

      latest = GrowthStore.get_latest()

      assert latest != nil
      assert is_integer(latest.timestamp)
      assert is_list(latest.tables)
    end

    test "returns newest sample not oldest" do
      start_supervised!({GrowthStore, [name: GrowthStore]})

      samples = GrowthStore.get_samples()
      latest = GrowthStore.get_latest()

      assert latest == List.last(samples)
    end
  end
end
