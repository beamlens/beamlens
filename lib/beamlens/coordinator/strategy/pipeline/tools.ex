defmodule Beamlens.Coordinator.Strategy.Pipeline.Tools do
  @moduledoc false

  defmodule ClassifyResult do
    @moduledoc false
    defstruct [:intent, :skills, :operator_context]

    @type t :: %__MODULE__{
            intent: :question | :investigation,
            skills: [String.t()],
            operator_context: String.t()
          }
  end

  defmodule SynthesizeResult do
    @moduledoc false
    defstruct [:answer]

    @type t :: %__MODULE__{answer: String.t()}
  end

  def classify_schema do
    Zoi.object(%{
      intent:
        Zoi.enum(["question", "investigation"])
        |> Zoi.transform(&atomize_intent/1),
      skills: Zoi.list(Zoi.string()),
      operator_context: Zoi.string()
    })
    |> Zoi.transform(fn data -> {:ok, struct!(ClassifyResult, data)} end)
  end

  def synthesize_schema do
    Zoi.object(%{
      answer: Zoi.string()
    })
    |> Zoi.transform(fn data -> {:ok, struct!(SynthesizeResult, data)} end)
  end

  defp atomize_intent("question"), do: {:ok, :question}
  defp atomize_intent("investigation"), do: {:ok, :investigation}
end
