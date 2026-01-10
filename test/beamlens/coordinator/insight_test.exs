defmodule Beamlens.Coordinator.InsightTest do
  use ExUnit.Case, async: true

  alias Beamlens.Coordinator.Insight

  describe "new/1" do
    test "creates insight with required fields" do
      attrs = %{
        alert_ids: ["alert1", "alert2"],
        correlation_type: :causal,
        summary: "Memory spike caused scheduler contention",
        confidence: :high
      }

      insight = Insight.new(attrs)

      assert insight.alert_ids == ["alert1", "alert2"]
      assert insight.correlation_type == :causal
      assert insight.summary == "Memory spike caused scheduler contention"
      assert insight.confidence == :high
    end

    test "generates unique 16-character id" do
      attrs = %{
        alert_ids: ["a1"],
        correlation_type: :temporal,
        summary: "test",
        confidence: :low
      }

      insight = Insight.new(attrs)

      assert is_binary(insight.id)
      assert String.length(insight.id) == 16
      assert insight.id =~ ~r/^[a-f0-9]+$/
    end

    test "generates unique ids on each call" do
      attrs = %{
        alert_ids: ["a1"],
        correlation_type: :temporal,
        summary: "test",
        confidence: :low
      }

      ids = for _ <- 1..100, do: Insight.new(attrs).id
      unique_ids = Enum.uniq(ids)

      assert length(unique_ids) == 100
    end

    test "sets created_at to current time" do
      attrs = %{
        alert_ids: ["a1"],
        correlation_type: :temporal,
        summary: "test",
        confidence: :low
      }

      before = DateTime.utc_now()
      insight = Insight.new(attrs)
      after_time = DateTime.utc_now()

      assert DateTime.compare(insight.created_at, before) in [:gt, :eq]
      assert DateTime.compare(insight.created_at, after_time) in [:lt, :eq]
    end

    test "stores optional root_cause_hypothesis" do
      attrs = %{
        alert_ids: ["a1"],
        correlation_type: :symptomatic,
        summary: "Multiple symptoms of memory leak",
        root_cause_hypothesis: "Possible unbounded ETS table growth",
        confidence: :medium
      }

      insight = Insight.new(attrs)

      assert insight.root_cause_hypothesis == "Possible unbounded ETS table growth"
    end

    test "root_cause_hypothesis defaults to nil" do
      attrs = %{
        alert_ids: ["a1"],
        correlation_type: :temporal,
        summary: "test",
        confidence: :low
      }

      insight = Insight.new(attrs)

      assert insight.root_cause_hypothesis == nil
    end

    test "raises on missing alert_ids" do
      assert_raise KeyError, fn ->
        Insight.new(%{
          correlation_type: :temporal,
          summary: "test",
          confidence: :low
        })
      end
    end

    test "raises on missing correlation_type" do
      assert_raise KeyError, fn ->
        Insight.new(%{
          alert_ids: ["a1"],
          summary: "test",
          confidence: :low
        })
      end
    end

    test "raises on missing summary" do
      assert_raise KeyError, fn ->
        Insight.new(%{
          alert_ids: ["a1"],
          correlation_type: :temporal,
          confidence: :low
        })
      end
    end

    test "raises on missing confidence" do
      assert_raise KeyError, fn ->
        Insight.new(%{
          alert_ids: ["a1"],
          correlation_type: :temporal,
          summary: "test"
        })
      end
    end
  end

  describe "Jason.Encoder" do
    test "encodes insight to JSON" do
      insight =
        Insight.new(%{
          alert_ids: ["a1", "a2"],
          correlation_type: :causal,
          summary: "test correlation",
          confidence: :high
        })

      assert {:ok, json} = Jason.encode(insight)
      assert is_binary(json)
    end

    test "encoded JSON contains all fields" do
      insight =
        Insight.new(%{
          alert_ids: ["a1"],
          correlation_type: :temporal,
          summary: "test",
          root_cause_hypothesis: "hypothesis",
          confidence: :medium
        })

      {:ok, json} = Jason.encode(insight)
      decoded = Jason.decode!(json)

      assert decoded["alert_ids"] == ["a1"]
      assert decoded["correlation_type"] == "temporal"
      assert decoded["summary"] == "test"
      assert decoded["root_cause_hypothesis"] == "hypothesis"
      assert decoded["confidence"] == "medium"
      assert is_binary(decoded["id"])
      assert is_binary(decoded["created_at"])
    end
  end
end
