# Deployment

Beamlens works out of the box for single-node applications. For scheduled monitoring, a few additional options are available.

## Basic Setup

Add Beamlens to your supervision tree:

```elixir
children = [
  {Beamlens, client_registry: client_registry()}
]
```

This starts the supervision infrastructure. Operators are started on-demand via `Operator.run/2` or `Coordinator.run/2`.

## Scheduled Monitoring with Oban

For scheduled monitoring (useful for reducing LLM costs or running analysis periodically), use `Operator.run/2` with Oban:

```elixir
defmodule MyApp.BeamlensWorker do
  use Oban.Worker, queue: :monitoring

  def perform(%{args: %{"skill" => skill}}) do
    {:ok, _notifications} =
      Beamlens.Operator.run(
        String.to_existing_atom(skill),
        %{reason: "scheduled monitoring check"},
        client_registry: client_registry()
      )

    :ok
  end

  defp client_registry do
    # Return your client_registry configuration
    %{}
  end
end
```

Then schedule it:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron, crontab: [
      {"*/5 * * * *", MyApp.BeamlensWorker, args: %{skill: "beam"}}
    ]}
  ]
```
