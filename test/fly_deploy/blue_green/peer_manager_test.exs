defmodule FlyDeploy.BlueGreen.PeerManagerTest do
  @moduledoc """
  Boots a real `:peer` node through PeerManager and verifies that stopping
  PeerManager's supervisor shuts the peer down gracefully.

  This is the path taken by `:init.stop()` on the parent node (SIGTERM,
  `fly machine stop`, cold deploys). PeerManager must trap exits so that its
  `terminate/2` runs and sends `:init.stop()` to the peer; otherwise the
  supervisor's exit signal kills PeerManager outright and the peer is either
  halted without running its shutdown callbacks or leaked entirely.

  Requires a local `epmd` (started automatically by `Node.start/2` on most
  systems; run `epmd -daemon` if distribution fails to start).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FlyDeploy.BlueGreen.PeerManager

  @node_name :"fly_deploy_peer_manager_test@127.0.0.1"

  setup_all do
    unless Node.alive?() do
      {:ok, _} = Node.start(@node_name, :longnames)
    end

    # PeerManager reads FLY_PRIVATE_IP to pick the peer's host. Point it at
    # loopback so the peer's node name resolves without a routable hostname.
    previous = System.get_env("FLY_PRIVATE_IP")
    System.put_env("FLY_PRIVATE_IP", "127.0.0.1")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("FLY_PRIVATE_IP")
        value -> System.put_env("FLY_PRIVATE_IP", value)
      end
    end)

    :ok
  end

  @tag timeout: 120_000
  test "supervisor shutdown gracefully stops the active peer" do
    # :logger is a tiny OTP app with no endpoint, so the peer boots quickly.
    {:ok, sup} =
      Supervisor.start_link([{PeerManager, otp_app: :logger}], strategy: :one_for_one)

    manager = Process.whereis(PeerManager)
    assert is_pid(manager)

    %{active_peer: control_pid, active_node: peer_node} = :sys.get_state(manager)

    on_exit(fn ->
      # If the fix regresses, the peer is leaked; don't let it outlive the test.
      if Process.alive?(control_pid), do: :peer.stop(control_pid)
    end)

    assert Node.ping(peer_node) == :pong

    log =
      capture_log(fn ->
        :ok = Supervisor.stop(sup)
      end)

    refute Process.alive?(manager)
    refute Process.alive?(control_pid)
    assert Node.ping(peer_node) == :pang

    assert log =~ "PeerManager terminating"
    assert log =~ "Sending :init.stop() to peer #{peer_node}"
    assert log =~ "Peer #{peer_node} stopped gracefully"
  end

  test "traps exits so terminate/2 runs on supervisor shutdown" do
    {:ok, sup} =
      Supervisor.start_link([{PeerManager, otp_app: :logger}], strategy: :one_for_one)

    manager = Process.whereis(PeerManager)
    %{active_peer: control_pid} = :sys.get_state(manager)

    on_exit(fn ->
      if Process.alive?(control_pid), do: :peer.stop(control_pid)
    end)

    # Without trapping exits, the supervisor's exit signal kills PeerManager
    # before terminate/2 can send :init.stop() to the peer.
    assert Process.info(manager, :trap_exit) == {:trap_exit, true}

    capture_log(fn -> :ok = Supervisor.stop(sup) end)
  end
end
