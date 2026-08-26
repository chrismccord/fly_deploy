defmodule Mix.Tasks.FlyDeploy.BlueGreen do
  @moduledoc """
  Performs a blue-green deploy via peer nodes.

  This is equivalent to `mix fly_deploy.hot --mode blue_green`. It builds
  a full release tarball (beams, configs, NIFs, static assets) and triggers
  each machine's PeerManager to boot a new peer with the new code, then
  gracefully shut down the old peer.

  ## Quick Start

      mix fly_deploy.blue_green

      # Use staging config
      mix fly_deploy.blue_green --config fly-staging.toml

      # Pass Docker build arguments
      mix fly_deploy.blue_green --build-arg ELIXIR_VERSION=1.18.2

      # Preview without executing
      mix fly_deploy.blue_green --dry-run

  ## Options

  Accepts all the same options as `mix fly_deploy.hot` except `--mode`.
  See `Mix.Tasks.FlyDeploy.Hot` for the full list.
  """

  use Mix.Task

  @shortdoc "Blue-green deploy via peer nodes"

  @impl Mix.Task
  def run(args) do
    Mix.Tasks.FlyDeploy.Hot.run(args ++ ["--mode", "blue_green"])
  end
end
