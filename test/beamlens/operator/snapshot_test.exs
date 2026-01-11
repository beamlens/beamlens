defmodule Beamlens.Operator.SnapshotTest do
  use ExUnit.Case, async: true

  alias Beamlens.Operator.Snapshot

  describe "new/1" do
    test "creates snapshot with data" do
      data = %{memory_utilization_pct: 45.0, process_count: 100}
      snapshot = Snapshot.new(data)

      assert snapshot.data == data
    end

    test "generates unique id" do
      snapshot = Snapshot.new(%{})

      assert is_binary(snapshot.id)
      assert String.length(snapshot.id) == 16
      assert snapshot.id =~ ~r/^[a-f0-9]+$/
    end

    test "sets captured_at to current time" do
      before = DateTime.utc_now()
      snapshot = Snapshot.new(%{})
      after_time = DateTime.utc_now()

      assert DateTime.compare(snapshot.captured_at, before) in [:gt, :eq]
      assert DateTime.compare(snapshot.captured_at, after_time) in [:lt, :eq]
    end

    test "generates unique ids on each call" do
      ids = for _ <- 1..100, do: Snapshot.new(%{}).id
      unique_ids = Enum.uniq(ids)

      assert length(unique_ids) == 100
    end
  end

  describe "Jason.Encoder" do
    test "encodes snapshot to JSON" do
      snapshot = Snapshot.new(%{test: "data"})

      assert {:ok, json} = Jason.encode(snapshot)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["data"]["test"] == "data"
    end
  end
end
