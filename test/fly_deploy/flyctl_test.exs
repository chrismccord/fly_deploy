defmodule FlyDeploy.FlyctlTest do
  use ExUnit.Case, async: true

  alias FlyDeploy.Flyctl

  test "machine_regions uses the selected config and explicitly requests JSON" do
    runner = fn executable, args, options ->
      assert executable == "fly"
      assert args == ["machine", "list", "--config", "fly-staging.toml", "--json"]
      assert options == []

      {Jason.encode!([
         %{
           id: "web",
           region: "ord",
           state: "started",
           config: %{services: [%{internal_port: 4000}], env: %{PRIVATE_VALUE: "not-forwarded"}}
         },
         %{id: "stopped", region: "ord", state: "stopped", config: %{services: [%{}]}},
         %{id: "worker", region: "ord", state: "started", config: %{services: []}},
         %{id: "orchestrator", region: "ord", state: "started", config: %{}}
       ]), 0}
    end

    assert {:ok, %{"web" => "ord"}} = Flyctl.machine_regions("fly-staging.toml", runner)
  end

  test "machine_regions accepts an empty machine list" do
    runner = fn "fly", _args, [] -> {"[]", 0} end

    assert {:ok, %{}} = Flyctl.machine_regions("fly.toml", runner)
  end

  test "machine_regions fails on malformed JSON instead of treating it as an empty list" do
    runner = fn "fly", _args, [] -> {"not JSON", 0} end

    assert_raise Jason.DecodeError, fn -> Flyctl.machine_regions("fly.toml", runner) end
  end

  test "machine_regions rejects a non-list JSON response" do
    runner = fn "fly", _args, [] -> {~s({"error":"unauthorized"}), 0} end

    assert_raise FunctionClauseError, fn -> Flyctl.machine_regions("fly.toml", runner) end
  end

  test "machine_regions returns the flyctl exit status without exposing its output" do
    runner = fn "fly", _args, [] ->
      {"an error that could contain sensitive output", 7}
    end

    assert {:error, {:exit_status, 7}} = Flyctl.machine_regions("fly.toml", runner)
  end
end
