defmodule Beamlens.ResultHandler do
  @moduledoc """
  Behaviour for handling agent results.

  Implement this behaviour to react to health analysis results,
  such as sending alerts, storing to a database, or triggering actions.

  ## Example

      defmodule MyApp.AlertHandler do
        @behaviour Beamlens.ResultHandler

        alias Beamlens.HealthAnalysis

        def handle_result(%HealthAnalysis{status: :critical} = analysis, opts) do
          MyApp.PagerDuty.alert(analysis.summary, severity: :high, trace_id: opts[:trace_id])
          :ok
        end

        def handle_result(%HealthAnalysis{status: :warning} = analysis, _opts) do
          MyApp.Slack.notify("#ops", analysis.summary)
          :ok
        end

        def handle_result(%HealthAnalysis{status: :healthy}, _opts), do: :ok
      end

  Configure in your supervision tree:

      {Beamlens,
        schedules: [{:default, "*/5 * * * *"}],
        result_handler: MyApp.AlertHandler}

  ## Callback Options

  The `opts` keyword list includes:

    * `:trace_id` - Correlation ID for the agent run
    * `:node` - Node where the analysis ran
    * `:schedule` - Schedule name (only for scheduled runs)
    * `:duration_ms` - Time taken for the analysis in milliseconds
  """

  alias Beamlens.HealthAnalysis

  @callback handle_result(analysis :: HealthAnalysis.t(), opts :: keyword()) ::
              :ok | {:error, term()}
end
