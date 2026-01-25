defmodule Beamlens.Coordinator.InsightTest do
  use ExUnit.Case, async: true

  alias Beamlens.Coordinator.Insight

  describe "new/1" do
    test "creates insight with required fields" do
      attrs = %{
        notification_ids: ["notification1", "notification2"],
        correlation_type: :causal,
        summary: "Memory spike caused scheduler contention",
        matched_observations: ["Memory at 85%", "Run queue depth at 50"],
        hypothesis_grounded: true,
        confidence: :high
      }

      insight = Insight.new(attrs)

      assert insight.notification_ids == ["notification1", "notification2"]
      assert insight.correlation_type == :causal
      assert insight.summary == "Memory spike caused scheduler contention"
      assert insight.matched_observations == ["Memory at 85%", "Run queue depth at 50"]
      assert insight.hypothesis_grounded == true
      assert insight.confidence == :high
    end

    test "generates unique 16-character id" do
      attrs = %{
        notification_ids: ["n1"],
        correlation_type: :temporal,
        summary: "test",
        matched_observations: ["observation1"],
        hypothesis_grounded: false,
        confidence: :low
      }

      insight = Insight.new(attrs)

      assert is_binary(insight.id)
      assert String.length(insight.id) == 16
      assert insight.id =~ ~r/^[a-f0-9]+$/
    end

    test "generates unique ids on each call" do
      attrs = %{
        notification_ids: ["n1"],
        correlation_type: :temporal,
        summary: "test",
        matched_observations: ["observation1"],
        hypothesis_grounded: false,
        confidence: :low
      }

      ids = for _ <- 1..100, do: Insight.new(attrs).id
      unique_ids = Enum.uniq(ids)

      assert length(unique_ids) == 100
    end

    test "sets created_at to current time" do
      attrs = %{
        notification_ids: ["n1"],
        correlation_type: :temporal,
        summary: "test",
        matched_observations: ["observation1"],
        hypothesis_grounded: false,
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
        notification_ids: ["n1"],
        correlation_type: :symptomatic,
        summary: "Multiple symptoms of memory leak",
        matched_observations: ["Memory at 85%", "ETS table size 500MB"],
        hypothesis_grounded: true,
        root_cause_hypothesis: "Possible unbounded ETS table growth",
        confidence: :medium
      }

      insight = Insight.new(attrs)

      assert insight.root_cause_hypothesis == "Possible unbounded ETS table growth"
    end

    test "root_cause_hypothesis defaults to nil" do
      attrs = %{
        notification_ids: ["n1"],
        correlation_type: :temporal,
        summary: "test",
        matched_observations: ["observation1"],
        hypothesis_grounded: false,
        confidence: :low
      }

      insight = Insight.new(attrs)

      assert insight.root_cause_hypothesis == nil
    end

    test "raises on missing notification_ids" do
      assert_raise KeyError, fn ->
        Insight.new(%{
          correlation_type: :temporal,
          summary: "test",
          matched_observations: ["observation1"],
          hypothesis_grounded: false,
          confidence: :low
        })
      end
    end

    test "raises on missing correlation_type" do
      assert_raise KeyError, fn ->
        Insight.new(%{
          notification_ids: ["n1"],
          summary: "test",
          matched_observations: ["observation1"],
          hypothesis_grounded: false,
          confidence: :low
        })
      end
    end

    test "raises on missing summary" do
      assert_raise KeyError, fn ->
        Insight.new(%{
          notification_ids: ["n1"],
          correlation_type: :temporal,
          matched_observations: ["observation1"],
          hypothesis_grounded: false,
          confidence: :low
        })
      end
    end

    test "raises on missing confidence" do
      assert_raise KeyError, fn ->
        Insight.new(%{
          notification_ids: ["n1"],
          correlation_type: :temporal,
          summary: "test",
          matched_observations: ["observation1"],
          hypothesis_grounded: false
        })
      end
    end

    test "raises on missing matched_observations" do
      assert_raise KeyError, fn ->
        Insight.new(%{
          notification_ids: ["n1"],
          correlation_type: :temporal,
          summary: "test",
          hypothesis_grounded: false,
          confidence: :low
        })
      end
    end

    test "raises on missing hypothesis_grounded" do
      assert_raise KeyError, fn ->
        Insight.new(%{
          notification_ids: ["n1"],
          correlation_type: :temporal,
          summary: "test",
          matched_observations: ["observation1"],
          confidence: :low
        })
      end
    end
  end

  describe "Jason.Encoder" do
    test "encodes insight to JSON" do
      insight =
        Insight.new(%{
          notification_ids: ["n1", "n2"],
          correlation_type: :causal,
          summary: "test correlation",
          matched_observations: ["Memory at 85%", "Run queue at 50"],
          hypothesis_grounded: true,
          confidence: :high
        })

      assert {:ok, json} = Jason.encode(insight)
      assert is_binary(json)
    end

    test "encoded JSON contains all fields" do
      insight =
        Insight.new(%{
          notification_ids: ["n1"],
          correlation_type: :temporal,
          summary: "test",
          matched_observations: ["observation1"],
          hypothesis_grounded: false,
          root_cause_hypothesis: "hypothesis",
          confidence: :medium
        })

      {:ok, json} = Jason.encode(insight)
      decoded = Jason.decode!(json)

      assert decoded["notification_ids"] == ["n1"]
      assert decoded["correlation_type"] == "temporal"
      assert decoded["summary"] == "test"
      assert decoded["matched_observations"] == ["observation1"]
      assert decoded["hypothesis_grounded"] == false
      assert decoded["root_cause_hypothesis"] == "hypothesis"
      assert decoded["confidence"] == "medium"
      assert is_binary(decoded["id"])
      assert is_binary(decoded["created_at"])
    end
  end
end
