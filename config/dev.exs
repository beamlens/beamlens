import Config

# Development configuration
# Set your API key in the environment:
#   export ANTHROPIC_API_KEY=your-key-here

# No auto-scheduling in dev by default
config :beamlens, schedules: []
