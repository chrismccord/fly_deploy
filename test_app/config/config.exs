import Config

config :test_app,
  generators: [timestamp_type: :utc_datetime],
  compile_version: "v2"

config :test_app, TestAppWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: TestAppWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TestApp.PubSub,
  live_view: [signing_salt: "8DruCBzp"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
