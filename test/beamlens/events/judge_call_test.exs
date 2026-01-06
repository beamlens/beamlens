defmodule Beamlens.Events.JudgeCallTest do
  use ExUnit.Case

  alias Beamlens.Events.JudgeCall

  describe "struct creation" do
    test "creates struct with required fields" do
      event = %JudgeCall{
        occurred_at: DateTime.utc_now(),
        attempt: 1,
        verdict: :accept,
        confidence: :high
      }

      assert event.verdict == :accept
      assert event.confidence == :high
      assert event.attempt == 1
      assert event.issues == []
      assert event.feedback == ""
    end

    test "creates struct with all fields" do
      now = DateTime.utc_now()

      event = %JudgeCall{
        occurred_at: now,
        attempt: 2,
        verdict: :retry,
        confidence: :medium,
        issues: ["Missing data", "Incorrect threshold"],
        feedback: "Please gather more metrics before concluding."
      }

      assert event.occurred_at == now
      assert event.attempt == 2
      assert event.verdict == :retry
      assert event.confidence == :medium
      assert event.issues == ["Missing data", "Incorrect threshold"]
      assert event.feedback == "Please gather more metrics before concluding."
    end
  end

  describe "JSON encoding" do
    test "encodes to JSON successfully" do
      event = %JudgeCall{
        occurred_at: ~U[2024-01-15 10:30:00Z],
        attempt: 1,
        verdict: :accept,
        confidence: :high,
        issues: [],
        feedback: ""
      }

      assert {:ok, json} = Jason.encode(event)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["verdict"] == "accept"
      assert decoded["confidence"] == "high"
      assert decoded["attempt"] == 1
      assert decoded["issues"] == []
    end

    test "encodes retry verdict with issues" do
      event = %JudgeCall{
        occurred_at: ~U[2024-01-15 10:30:00Z],
        attempt: 2,
        verdict: :retry,
        confidence: :low,
        issues: ["Insufficient data"],
        feedback: "Need more metrics"
      }

      {:ok, json} = Jason.encode(event)
      decoded = Jason.decode!(json)

      assert decoded["verdict"] == "retry"
      assert decoded["confidence"] == "low"
      assert decoded["issues"] == ["Insufficient data"]
      assert decoded["feedback"] == "Need more metrics"
    end
  end
end
