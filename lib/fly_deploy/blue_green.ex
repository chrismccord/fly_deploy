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
            otp_app: :my_app,
            start: {__MODULE__, :start_app, [type, args]}
          )
        end

        def start_app(_type, _args) do
          children = [
            MyApp.Repo,
            {Phoenix.PubSub, name: MyApp.PubSub},
            # Gate blocks here until cutover signal
            {FlyDeploy.BlueGreen.Gate, []},
            MyAppWeb.Endpoint
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end

  ## How it works

  - **Dev/test**: Calls your `start_app` directly. Gate opens immediately. Zero overhead.
  - **Fly (parent)**: Starts the BlueGreen supervisor (PeerManager + Poller), which boots
    your app in a peer BEAM process. Returns `{:ok, supervisor_pid}`.
  - **Fly (peer)**: Calls your `start_app` directly. Gate blocks until cutover.

  ## Options

  - `:otp_app` - Your OTP application name (required)
  - `:start` - `{module, function, args}` MFA for starting your supervision tree (required)
  - `:endpoint` - Your Phoenix Endpoint module (auto-detected if not given)
  - `:poll_interval` - How often to poll S3 in ms (default: 1000)
  """

  require Logger

  @doc """
  Entry point for blue-green mode. Call this from `Application.start/2`.

  See module docs for setup instructions.
  """
  def start_link(opts) do
    {mod, fun, args} = Keyword.fetch!(opts, :start)
    otp_app = Keyword.fetch!(opts, :otp_app)

    if Application.get_env(:fly_deploy, :__role__) == :peer do
      # Parent already told us we're a peer — just run the user's app
      apply(mod, fun, args)
    else
      maybe_start_parent(otp_app, mod, fun, args, opts)
    end
  end

  defp maybe_start_parent(otp_app, mod, fun, args, opts) do
    if System.get_env("FLY_IMAGE_REF") do
      # We're on Fly — become the parent, boot app in a peer
      start_as_parent(otp_app, opts)
    else
      # Dev/test — just run normally, no peers
      apply(mod, fun, args)
    end
  end

  defp start_as_parent(otp_app, opts) do
    Logger.info("[BlueGreen] Starting as parent for #{otp_app}")

    # Start distributed Erlang if not already started
    ensure_distributed()

    FlyDeploy.BlueGreen.Supervisor.start_link(
      otp_app: otp_app,
      endpoint: Keyword.get(opts, :endpoint),
      poll_interval: Keyword.get(opts, :poll_interval, 1_000)
    )
  end

  defp ensure_distributed do
    if Node.alive?() do
      :ok
    else
      # On Fly.io, we need long names with the machine's IPv6 address.
      # ERL_AFLAGS="-proto_dist inet6_tcp" is already set at VM startup by env.sh,
      # so Node.start will use IPv6 distribution automatically.
      ip = System.get_env("FLY_PRIVATE_IP", "127.0.0.1")
      node_name = :"fly_deploy_parent_#{System.pid()}@#{ip}"
      {:ok, _} = Node.start(node_name, :longnames)
      :ok
    end
  end
end
