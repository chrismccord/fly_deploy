defmodule FlyDeploy.BlueGreen.EndpointsTest do
  use ExUnit.Case, async: true

  alias FlyDeploy.BlueGreen

  test "normalizes explicit endpoints and the legacy single endpoint" do
    assert BlueGreen.configured_endpoints(endpoints: [Public.Endpoint, Internal.Endpoint]) ==
             [Public.Endpoint, Internal.Endpoint]

    assert BlueGreen.configured_endpoints(endpoint: Public.Endpoint) == [Public.Endpoint]
    assert BlueGreen.configured_endpoints(endpoints: []) == []
    assert BlueGreen.configured_endpoints([]) == nil
    assert BlueGreen.configured_endpoints(endpoint: nil) == nil
  end

  test "deduplicates endpoints" do
    assert BlueGreen.configured_endpoints(endpoints: [Public.Endpoint, Public.Endpoint]) ==
             [Public.Endpoint]
  end

  test "public entry point rejects conflicting options before starting the application" do
    assert_raise ArgumentError, ~r/cannot specify both/, fn ->
      BlueGreen.start_link(
        otp_app: :logger,
        start: {__MODULE__, :must_not_start, []},
        endpoint: Public.Endpoint,
        endpoints: [Internal.Endpoint]
      )
    end
  end

  test "rejects ambiguous and malformed endpoint options" do
    assert_raise ArgumentError, ~r/cannot specify both/, fn ->
      BlueGreen.configured_endpoints(endpoint: Public.Endpoint, endpoints: [Internal.Endpoint])
    end

    for opts <- [
          [endpoints: Public.Endpoint],
          [endpoints: [nil]],
          [endpoints: ["Internal.Endpoint"]],
          [endpoint: [Public.Endpoint]]
        ] do
      assert_raise ArgumentError, fn -> BlueGreen.configured_endpoints(opts) end
    end
  end

  test "parent supervisor forwards all configured endpoints" do
    assert {:ok, {_, children}} =
             FlyDeploy.BlueGreen.Supervisor.init(
               otp_app: :logger,
               endpoints: [Public.Endpoint, Internal.Endpoint]
             )

    manager = Enum.find(children, &(&1.id == FlyDeploy.BlueGreen.PeerManager))
    {_, :start_link, [opts]} = manager.start
    assert opts[:endpoints] == [Public.Endpoint, Internal.Endpoint]
  end
end
