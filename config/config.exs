import Config

# BeamLens configuration
#
# Required:
#   config :beamlens, api_key: System.get_env("ANTHROPIC_API_KEY")
#
# Optional:
#   config :beamlens,
#     model: "anthropic:claude-haiku-4-5",
#     mode: :periodic,           # :periodic | :manual
#     interval: :timer.minutes(5)

# Default configuration
config :beamlens,
  model: "anthropic:claude-haiku-4-5",
  mode: :periodic,
  interval: :timer.minutes(5)

# Import environment specific config
import_config "#{config_env()}.exs"
