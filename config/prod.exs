import Config

# Production configuration
# Ensure ANTHROPIC_API_KEY is set in the environment

config :beamlens,
  mode: :periodic,
  interval: :timer.minutes(5)
