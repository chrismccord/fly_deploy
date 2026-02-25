import Config

if System.get_env("PHX_SERVER") do
  config :test_app, TestAppWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing."

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :test_app, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Runtime config version — evaluated fresh at each boot
  config :test_app, :runtime_version, "v3"

  config :test_app, TestAppWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
