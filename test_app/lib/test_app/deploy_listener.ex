defmodule TestApp.DeployListener do
  @moduledoc """
  Subscribes to FlyDeploy lifecycle events and stores them for test verification.
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_events do
    GenServer.call(__MODULE__, :get_events)
  end

  @impl true
  def init(_opts) do
    FlyDeploy.subscribe()
    {:ok, %{events: []}}
  end

  @impl true
  def handle_call(:get_events, _from, state) do
    {:reply, state.events, state}
  end

  @impl true
  def handle_info({:fly_deploy, event, metadata}, state) do
    {:noreply, %{state | events: state.events ++ [{event, metadata}]}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
