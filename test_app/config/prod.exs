import Config

# Do not print debug messages in production
config :logger, level: :info

# Configure static asset serving with cache manifest
config :test_app, TestAppWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# -- Config override tests -------------------------------------------------
# These values are set here in prod.exs and ALSO set in runtime.exs.
# After blue-green deploy, the runtime.exs values must win. This tests that
# load_release_config deep-merges correctly:
#
# Scalar: simple replace (runtime.exs value should replace prod.exs value)
config :test_app, :prod_override_scalar, "from-prod"
#
# Plain list: NOT a keyword list — must not be passed to Keyword.merge
# (which crashes on plain lists), must be replaced entirely.
config :test_app, :prod_override_list, ["prod.example.com"]
