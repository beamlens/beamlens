import Config

# Runtime configuration - loaded at runtime, not compile time
# This is where you set environment-dependent values

if api_key = System.get_env("ANTHROPIC_API_KEY") do
  config :beamlens, api_key: api_key
end
