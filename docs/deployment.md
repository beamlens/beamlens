# Deployment

Beamlens works out of the box for single-node applications. For scheduled monitoring, a few additional options are available.

## Basic Setup

Add Beamlens to your supervision tree:

```elixir
children = [
  {Beamlens, client_registry: client_registry()}
]
```

This starts a static supervision tree. Operators and Coordinator are always-running processes invoked via `Operator.run/2` or `Coordinator.run/2`.

Configure which skills to start:

```elixir
children = [
  {Beamlens,
   client_registry: client_registry(),
   skills: [Beamlens.Skill.Beam, Beamlens.Skill.Ets, MyApp.EctoSkill]}
]
```

## Scheduled Monitoring with Oban

For scheduled monitoring (useful for reducing LLM costs or running analysis periodically), use `Operator.run/2` with Oban:

```elixir
defmodule MyApp.BeamlensWorker do
  use Oban.Worker, queue: :monitoring

  @skills %{
    "beam" => Beamlens.Skill.Beam,
    "ets" => Beamlens.Skill.Ets,
    "gc" => Beamlens.Skill.Gc
  }

  def perform(%{args: %{"skill" => skill_name}}) do
    skill_module = Map.fetch!(@skills, skill_name)

    {:ok, _notifications} =
      Beamlens.Operator.run(
        skill_module,
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
