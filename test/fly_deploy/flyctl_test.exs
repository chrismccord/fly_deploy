defmodule FlyDeploy.FlyctlTest do
  use ExUnit.Case, async: true

  alias FlyDeploy.Flyctl

  test "machine_exec_token gets an app-scoped, short-lived token from flyctl" do
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
             Flyctl.machine_exec_token("fly-staging.toml", runner)
  end

  test "machine_exec_token rejects an empty successful response" do
    runner = fn "fly", _args, [] -> {"\n", 0} end

    assert {:error, :empty_token} = Flyctl.machine_exec_token("fly.toml", runner)
  end

  test "machine_exec_token returns the flyctl exit status without exposing its output" do
    runner = fn "fly", _args, [] ->
      {"an error that could contain sensitive output", 7}
    end

    assert {:error, {:exit_status, 7}} = Flyctl.machine_exec_token("fly.toml", runner)
  end
end
