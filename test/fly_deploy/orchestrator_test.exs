defmodule FlyDeploy.OrchestratorTest do
  use ExUnit.Case, async: false

  alias FlyDeploy.Orchestrator

  @env_vars ["FLY_DEPLOY_MACHINE_REGIONS", "FLY_API_TOKEN", "FLY_APP_NAME"]

  setup do
    env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    req_options = Req.default_options()
    Enum.each(@env_vars, &System.delete_env/1)
    Req.default_options(plug: {Req.Test, __MODULE__}, retry: false)

    on_exit(fn ->
      Enum.each(env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Req.default_options(req_options)
    end)
  end

  test "uses the local machine snapshot without needing an API token" do
    System.put_env("FLY_DEPLOY_MACHINE_REGIONS", ~s({"web":"ord","api":"iad"}))

    assert Orchestrator.machine_regions() == %{"web" => "ord", "api" => "iad"}
  end

  test "an empty snapshot does not fall back to remote discovery" do
    System.put_env("FLY_DEPLOY_MACHINE_REGIONS", "{}")

    assert Orchestrator.machine_regions() == %{}
  end

  test "malformed snapshot JSON fails instead of falling back" do
    System.put_env("FLY_DEPLOY_MACHINE_REGIONS", "not JSON")

    assert_raise Jason.DecodeError, &Orchestrator.machine_regions/0
  end

  test "direct callers can still discover machines using FLY_API_TOKEN" do
    System.put_env("FLY_API_TOKEN", "test-placeholder")
    System.put_env("FLY_APP_NAME", "test-app")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/apps/test-app/machines"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-placeholder"]

      Req.Test.json(conn, [
        %{id: "web", region: "ord", state: "started", config: %{services: [%{}]}},
        %{id: "worker", region: "ord", state: "started", config: %{services: []}}
      ])
    end)

    assert Orchestrator.machine_regions() == %{"web" => "ord"}
    Req.Test.verify!()
  end

  test "remote discovery rejects an unsuccessful response" do
    System.put_env("FLY_API_TOKEN", "test-placeholder")
    System.put_env("FLY_APP_NAME", "test-app")

    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(403) |> Req.Test.json([])
    end)

    assert_raise MatchError, &Orchestrator.machine_regions/0
    Req.Test.verify!()
  end
end
