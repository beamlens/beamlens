# Deployment

Beamlens works out of the box for single-node applications. For clustered deployments or scheduled monitoring, a few additional options are available.

## Basic Setup

Add Beamlens to your supervision tree:

```elixir
children = [
  {Beamlens,
    operators: [:beam, :ets],
    client_registry: client_registry()}
]
```

This starts operators that continuously monitor your application and a Coordinator that correlates alerts into insights.

## Running in a Cluster

When running multiple nodes, you probably want:
- Operators on every node (they monitor node-local metrics)
- A single Coordinator across the cluster (to avoid duplicate insights)
- Alerts from all nodes reaching that Coordinator

Add the `pubsub` option to enable this:

```elixir
children = [
  {Beamlens,
    operators: [:beam, :ets],
    client_registry: client_registry(),
    pubsub: MyApp.PubSub}
]
```

This requires two additional dependencies:

```elixir
{:highlander, "~> 0.2"},
{:phoenix_pubsub, "~> 2.1"}
```

## Scheduled Monitoring with Oban

If you prefer scheduled monitoring over continuous loops (useful for reducing LLM costs or running heavier analysis periodically), use `Operator.run_once/3` with Oban:

```elixir
defmodule MyApp.BeamlensWorker do
  use Oban.Worker, queue: :monitoring

  def perform(%{args: %{"skill" => skill}}) do
    {:ok, _alerts} = Beamlens.Operator.run_once(String.to_existing_atom(skill), client_registry())
    :ok
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
