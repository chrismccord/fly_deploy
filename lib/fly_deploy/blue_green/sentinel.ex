defmodule FlyDeploy.BlueGreen.Sentinel do
  @moduledoc """
  A GenServer injected as the first child in the peer's wrapper supervisor.

  OTP shuts down children in reverse order, so the sentinel terminates **last**
  — after all user processes (Endpoint, Counter, PubSub, etc.) have already
  run their `terminate/2` callbacks and written any handoff state.

  Before calling `:init.stop()`, PeerManager arms the sentinel via `:erpc.call`.
  When armed, `terminate/2` runs the `before_cutover` callback and writes
  the result to the parent's handoff ETS at key `:__before_cutover_result__`.

  When NOT armed (normal restarts, crashes), `terminate/2` is a no-op.
  """

  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Arms the sentinel with a before_cutover callback. Called via `:erpc.call`
  from PeerManager before `:init.stop()`.
  """
  def arm(before_cutover_mfa, incoming_node) do
    GenServer.call(__MODULE__, {:arm, before_cutover_mfa, incoming_node})
  end

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    {:ok, %{before_cutover: nil, incoming_node: nil}}
  end

  @impl true
  def handle_call({:arm, mfa, incoming_node}, _from, state) do
    {:reply, :ok, %{state | before_cutover: mfa, incoming_node: incoming_node}}
  end

  @impl true
  def terminate(_reason, %{before_cutover: {mod, fun, args}, incoming_node: incoming_node}) do
    result =
      try do
        apply(mod, fun, [incoming_node | args])
      catch
        kind, reason ->
          Logger.error("[BlueGreen.Sentinel] before_cutover failed: #{kind}: #{inspect(reason)}")

          nil
      end

    FlyDeploy.BlueGreen.put_handoff(:__before_cutover_result__, result)
  end

  def terminate(_reason, _state), do: :ok
end
