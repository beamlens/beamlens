import Config

# Force build baml_elixir NIF from source
config :rustler_precompiled, :force_build, baml_elixir: true

import_config "#{config_env()}.exs"
