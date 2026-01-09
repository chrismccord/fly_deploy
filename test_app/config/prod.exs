import Config

# Do not print debug messages in production
config :logger, level: :info

# Configure static asset serving with cache manifest
# This enables serving digested (fingerprinted) assets
config :test_app, TestAppWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
