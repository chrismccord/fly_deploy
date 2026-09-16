defmodule FlyDeploy.FlyctlTest do
  use ExUnit.Case, async: true

  alias FlyDeploy.Flyctl

  test "orchestrator_token mints an app-scoped token for a local user session" do
    runner = fn executable, args, options ->
      assert executable == "fly"

      assert args == [
               "tokens",
               "create",
               "machine-exec",
               "--config",
               "fly-staging.toml",
               "--expiry",
               "1h",
               "--command",
               "/bin/false",
               "--name",
               "fly_deploy orchestrator"
             ]

      assert options == []

      {"  FlyV1 fm2_permission,fm2_discharge\n", 0}
    end

    assert {:ok, "fm2_permission,fm2_discharge"} =
             Flyctl.orchestrator_token("fly-staging.toml", runner, fn _name -> nil end)
  end

  test "orchestrator_token refreshes an explicitly supplied automation token" do
    runner = fn "fly", args, [] ->
      assert args == ["auth", "token", "--quiet"]
      {"FlyV1 fm2_permission,fm2_discharge\n", 0}
    end

    env_reader = fn
      "FLY_ACCESS_TOKEN" -> "configured"
      _name -> nil
    end

    assert {:ok, "fm2_permission,fm2_discharge"} =
             Flyctl.orchestrator_token("fly.toml", runner, env_reader)
  end

  test "orchestrator_token rejects an empty successful response" do
    runner = fn "fly", _args, [] -> {"\n", 0} end

    assert {:error, :empty_token} =
             Flyctl.orchestrator_token("fly.toml", runner, fn _name -> nil end)
  end

  test "orchestrator_token returns the flyctl exit status without exposing its output" do
    runner = fn "fly", _args, [] ->
      {"an error that could contain sensitive output", 7}
    end

    assert {:error, {:exit_status, 7}} =
             Flyctl.orchestrator_token("fly.toml", runner, fn _name -> nil end)
  end
end
