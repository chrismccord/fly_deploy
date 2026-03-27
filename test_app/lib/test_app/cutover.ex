defmodule TestApp.Cutover do
  @moduledoc """
  Cutover callbacks for blue-green deploy testing.

  `before_cutover` runs on the outgoing peer and writes handoff state
  to the parent via `FlyDeploy.BlueGreen.put_handoff/2`.

  `after_cutover` runs on the incoming peer and reads it back.
  """

  @handoff_key :test_app_cutover

  def before_cutover(incoming_node) do
    # Counter is already dead (terminated before sentinel), so read from handoff
    # where Counter.terminate/2 wrote its state.
    count = FlyDeploy.BlueGreen.get_handoff(:counter_state) || 0

    handoff = %{
      outgoing_counter: count,
      outgoing_node: node(),
      incoming_node: incoming_node,
      handed_off_at: System.system_time(:second)
    }

    FlyDeploy.BlueGreen.put_handoff(@handoff_key, handoff)
    handoff
  end

  def after_cutover(handoff_state) when is_map(handoff_state) or is_nil(handoff_state) do
    # The handoff state is already on the parent via put_handoff in before_cutover.
    # We can also write additional keys from the incoming peer side:
    FlyDeploy.BlueGreen.put_handoff(:test_app_after_cutover_ran, true)
  end

  def get_handoff_state do
    FlyDeploy.BlueGreen.get_handoff(@handoff_key)
  end
end
