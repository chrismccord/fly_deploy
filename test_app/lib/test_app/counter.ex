# Cache buster: 9999999999
defmodule TestApp.Counter do
  @moduledoc """
  A simple GenServer counter for testing hot code upgrades.
  """
  use GenServer

  @counter_vsn "v2"

  # Define a struct to test protocol implementations
  defmodule State do
    @moduledoc false
    defstruct [:count, :version, :protocol_version]
  end

  # V2 ONLY: New struct to test consolidated protocol dispatch changes
  defmodule MetricsSnapshot do
    @moduledoc false
    defstruct [:count, :timestamp]
  end

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

  def get_metrics_snapshot do
    GenServer.call(__MODULE__, :get_metrics_snapshot)
  end

  def vsn, do: @counter_vsn

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %State{count: 0, version: @counter_vsn, protocol_version: "v2"}}
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
    {:reply, %{
      count: state.count,
      version: state.version,
      pid: self(),
      protocol_version: state.protocol_version,
      string_representation: to_string(state),
      protocol_consolidated: Protocol.consolidated?(String.Chars)
    }, state}
  end

  @impl true
  def handle_call(:get_metrics_snapshot, _from, state) do
    snapshot = %MetricsSnapshot{count: state.count, timestamp: System.system_time(:second)}
    {:reply, to_string(snapshot), state}
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    {:ok, Map.put(state, :version, vsn())}
  end
end

# Protocol implementation for testing consolidated protocol hot upgrades
defimpl String.Chars, for: TestApp.Counter.State do
  def to_string(%TestApp.Counter.State{} = state) do
    "CounterV2[count=#{state.count}, version=#{state.version}, protocol_v=#{state.protocol_version}]"
  end
end

# V2 ONLY: New protocol implementation to force consolidated dispatch table change
defimpl String.Chars, for: TestApp.Counter.MetricsSnapshot do
  def to_string(%TestApp.Counter.MetricsSnapshot{} = snap) do
    "Metrics[count=#{snap.count}, ts=#{snap.timestamp}]"
  end
end
