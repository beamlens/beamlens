defmodule Beamlens.JudgeTest do
  use ExUnit.Case

  alias Beamlens.Judge

  describe "feedback_schema/0" do
    test "returns a valid Zoi schema" do
      schema = Judge.feedback_schema()
      assert schema != nil
    end

    test "parses valid accept response" do
      schema = Judge.feedback_schema()

      input = %{
        verdict: "accept",
        confidence: "high",
        issues: [],
        feedback: ""
      }

      assert {:ok, feedback} = Zoi.parse(schema, input)
      assert feedback.verdict == :accept
      assert feedback.confidence == :high
      assert feedback.issues == []
      assert feedback.feedback == ""
    end

    test "parses valid retry response" do
      schema = Judge.feedback_schema()

      input = %{
        verdict: "retry",
        confidence: "medium",
        issues: ["Missing data", "Incorrect threshold"],
        feedback: "Please gather more metrics."
      }

      assert {:ok, feedback} = Zoi.parse(schema, input)
      assert feedback.verdict == :retry
      assert feedback.confidence == :medium
      assert feedback.issues == ["Missing data", "Incorrect threshold"]
      assert feedback.feedback == "Please gather more metrics."
    end

    test "transforms string verdict to atom" do
      schema = Judge.feedback_schema()

      input = %{
        verdict: "accept",
        confidence: "low",
        issues: [],
        feedback: ""
      }

      assert {:ok, feedback} = Zoi.parse(schema, input)
      assert is_atom(feedback.verdict)
      assert is_atom(feedback.confidence)
    end

    test "rejects invalid verdict" do
      schema = Judge.feedback_schema()

      input = %{
        verdict: "invalid",
        confidence: "high",
        issues: [],
        feedback: ""
      }

      assert {:error, _} = Zoi.parse(schema, input)
    end

    test "rejects invalid confidence" do
      schema = Judge.feedback_schema()

      input = %{
        verdict: "accept",
        confidence: "very_high",
        issues: [],
        feedback: ""
      }

      assert {:error, _} = Zoi.parse(schema, input)
    end
  end

  describe "Feedback struct" do
    test "has expected fields" do
      feedback = %Judge.Feedback{
        verdict: :accept,
        confidence: :high,
        issues: [],
        feedback: ""
      }

      assert feedback.verdict == :accept
      assert feedback.confidence == :high
      assert feedback.issues == []
      assert feedback.feedback == ""
    end
  end
end
