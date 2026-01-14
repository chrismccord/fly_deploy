defmodule TestApp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # FlyDeploy MUST be first - it blocks to apply hot upgrades before other processes start
      {FlyDeploy, otp_app: :test_app},
      {DNSCluster, query: Application.get_env(:test_app, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TestApp.PubSub},
      # Start the counter GenServer for hot upgrade testing
      TestApp.Counter,
      # Start to serve requests, typically the last entry
      TestAppWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TestApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TestAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
