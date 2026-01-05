import Config

# Force build baml_elixir NIF from source
config :rustler_precompiled, :force_build, baml_elixir: true

# Logger metadata keys used by BeamLens for tracing
config :logger, :default_handler, metadata: [:trace_id, :tool_name, :tool_count]

import_config "#{config_env()}.exs"
