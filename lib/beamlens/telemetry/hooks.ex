defmodule Beamlens.Telemetry.Hooks do
  @moduledoc """
  Puck.Hooks implementation that emits BeamLens-specific telemetry events.

  This module bridges Puck's hook system with BeamLens telemetry,
  ensuring clients depend only on BeamLens telemetry events.

  ## Usage

  The hooks are automatically attached when using `Beamlens.Agent.run/1`.
  Trace context is read from `Puck.Context.metadata`:

      context = Context.new(metadata: %{
        trace_id: Beamlens.Telemetry.generate_trace_id(),
        iteration: 1
      })
  """

  @behaviour Puck.Hooks

  @impl true
  def on_call_start(_agent, content, context) do
    metadata = extract_trace_metadata(context)
    Process.put(:beamlens_llm_start_time, System.monotonic_time())

    :telemetry.execute(
      [:beamlens, :llm, :start],
      %{system_time: System.system_time()},
      Map.put(metadata, :context_size, length(context.messages))
    )

    {:cont, content}
  end

  @impl true
  def on_call_end(_agent, response, context) do
    metadata = extract_trace_metadata(context)
    {tool_name, intent} = extract_tool_info(response.content)
    start_time = Process.delete(:beamlens_llm_start_time) || System.monotonic_time()
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:beamlens, :llm, :stop],
      %{duration: duration},
      Map.merge(metadata, %{tool_selected: tool_name, intent: intent, response: response.content})
    )

    {:cont, response}
  end

  @impl true
  def on_call_error(_agent, error, context) do
    metadata = extract_trace_metadata(context)
    start_time = Process.delete(:beamlens_llm_start_time) || System.monotonic_time()
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:beamlens, :llm, :exception],
      %{duration: duration},
      Map.merge(metadata, %{kind: :error, reason: error, stacktrace: []})
    )
  end

  defp extract_trace_metadata(context) do
    %{
      trace_id: context.metadata[:trace_id],
      iteration: context.metadata[:iteration] || 0
    }
  end

  defp extract_tool_info(content) when is_struct(content) do
    tool_name =
      content.__struct__
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    intent = Map.get(content, :intent) || ""
    {tool_name, intent}
  end

  defp extract_tool_info(_content), do: {"unknown", ""}
end
