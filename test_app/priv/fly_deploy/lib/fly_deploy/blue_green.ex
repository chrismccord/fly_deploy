defmodule FlyDeploy.BlueGreen do
  @moduledoc """
  Blue-green deploys via `:peer` nodes.

  Instead of hot-patching code in a running BEAM (suspend → load → code_change → resume),
  this starts the user's app in a child BEAM process and swaps to a new one on upgrade.
  No suspension, no `code_change/3`, clean start.

  ## Setup

  In your `Application` module, rename `start/2` to `start_app/2` and delegate:

      defmodule MyApp.Application do
        use Application

        def start(type, args) do
          FlyDeploy.BlueGreen.start_link(
            [
              {DNSCluster, query: Application.get_env(:my_app, :dns_cluster_query) || :ignore}
            ],
            otp_app: :my_app,
            start: {__MODULE__, :start_app, [type, args]}
          )
        end

        def start_app(_type, _args) do
          children = [
            MyApp.Repo,
            {Phoenix.PubSub, name: MyApp.PubSub},
            MyAppWeb.Endpoint
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end

  The first argument is a list of child specs to run on the **parent** node.
  This is important for children like `DNSCluster` that rely on a consistent
  node basename for discovery — peer nodes have machine-specific names that
  prevent cross-machine discovery, but parent nodes share a consistent basename
  set by `RELEASE_NODE`.

  ## How it works

  - **Dev/test**: Calls your `start_app` directly. Zero overhead.
  - **Fly (parent)**: Starts the BlueGreen supervisor (PeerManager + Poller), which boots
    your app in a peer BEAM process. Returns `{:ok, supervisor_pid}`.
  - **Fly (peer)**: Calls your `start_app` directly. Endpoint binds via SO_REUSEPORT.

  ## Options

  - `:otp_app` - Your OTP application name (required)
  - `:start` - `{module, function, args}` MFA for starting your supervision tree (required)
  - `:endpoint` - Your Phoenix Endpoint module (auto-detected if not given)
  - `:poll_interval` - How often to poll S3 in ms (default: 1000)
  - `:shutdown_timeout` - Max time in ms to wait for the outgoing peer to shut down
    before force-killing it. `nil` (default) means wait indefinitely, trusting
    the app's supervision tree timeouts.
  """

  require Logger

  @doc """
  Entry point for blue-green mode with parent-level children.

  The first argument is a list of child specs to supervise on the parent node.
  These start before PeerManager and Poller, making them ideal for clustering
  (e.g., `DNSCluster`) that needs the parent's consistent node basename.

  See module docs for setup instructions.
  """
  def start_link(children, opts) when is_list(children) do
    do_start_link(children, opts)
  end

  @doc """
  Entry point for blue-green mode without parent-level children.

  See `start_link/2` for the variant that accepts parent children.
  """
  def start_link(opts) when is_list(opts) do
    do_start_link([], opts)
  end

  defp do_start_link(children, opts) do
    {mod, fun, args} = Keyword.fetch!(opts, :start)
    otp_app = Keyword.fetch!(opts, :otp_app)

    if Application.get_env(:fly_deploy, :__role__) == :peer do
      # Parent already told us we're a peer — just run the user's app
      apply(mod, fun, args)
    else
      maybe_start_parent(otp_app, mod, fun, args, children, opts)
    end
  end

  defp maybe_start_parent(otp_app, mod, fun, args, children, opts) do
    if System.get_env("FLY_IMAGE_REF") do
      # We're on Fly — become the parent, boot app in a peer
      start_as_parent(otp_app, children, opts)
    else
      # Dev/test — just run normally, no peers
      apply(mod, fun, args)
    end
  end

  defp start_as_parent(otp_app, children, opts) do
    Logger.info("[BlueGreen] Starting as parent for #{otp_app}")

    FlyDeploy.BlueGreen.Supervisor.start_link(
      otp_app: otp_app,
      children: children,
      endpoint: Keyword.get(opts, :endpoint),
      poll_interval: Keyword.get(opts, :poll_interval, 1_000),
      shutdown_timeout: Keyword.get(opts, :shutdown_timeout)
    )
  end
end
