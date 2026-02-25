defmodule FlyDeploy.BlueGreen.Gate do
  @moduledoc """
  A supervisor child that blocks until the parent node signals cutover.

  Place this in your supervision tree **above** your Phoenix Endpoint.
  In peer mode, `init/1` blocks via `receive` until the parent sends `:open`,
  preventing the Endpoint from starting until the old peer's port is freed.

  In non-peer mode (dev/test), the gate opens immediately — zero overhead.

  ## Example

      children = [
        MyApp.Repo,
        {Phoenix.PubSub, name: MyApp.PubSub},
        # Gate blocks here in peer mode until cutover
        {FlyDeploy.BlueGreen.Gate, []},
        MyAppWeb.Endpoint
      ]
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Opens the gate on a remote peer node, allowing the Endpoint to start.
  """
  def open(node) do
    send({__MODULE__, node}, :open)
  end

  @impl true
  def init(_opts) do
    if Application.get_env(:fly_deploy, :__role__) == :peer do
      # Block here. The supervisor won't start the next child (Endpoint)
      # until this receive completes and init returns.
      # The parent finds us by name (__MODULE__) on this node.
      receive do
        :open -> {:ok, :open}
      end
    else
      # Dev/test mode — open immediately, zero overhead
      {:ok, :open}
    end
  end

  @impl true
  def handle_info(:open, _state) do
    # Late/duplicate message — ignore
    {:noreply, :open}
  end
end
