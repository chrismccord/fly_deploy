defmodule TestApp.Counter do
  @moduledoc """
  A simple GenServer counter for testing hot code upgrades.
  """
  use GenServer

  @counter_vsn "v3"

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def increment do
    GenServer.call(__MODULE__, :increment)
  end

  def get_value do
    GenServer.call(__MODULE__, :get_value)
  end

  def get_info do
    GenServer.call(__MODULE__, :get_info)
  end

  def vsn, do: @counter_vsn

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %{count: 0, version: @counter_vsn}}
  end

  @impl true
  def handle_call(:increment, _from, state) do
    new_state = %{state | count: state.count + 1}
    {:reply, new_state.count, new_state}
  end

  @impl true
  def handle_call(:get_value, _from, state) do
    {:reply, state.count, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    {:reply, %{count: state.count, version: Map.get(state, :version, 1), pid: self()}, state}
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    # Migrate state - update version to new module version to prove code_change was called
    # Preserve count but update version field to match new module version
    {:ok, Map.put(state, :version, vsn())}
  end
end
