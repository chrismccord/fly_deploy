defmodule FlyDeploy.E2ETest do
  @moduledoc """
  End-to-end test for hot code upgrades.

  This test performs a complete hot upgrade cycle:
  1. Deploy initial version (v1) via cold deploy
  2. Increment counter to preserve state
  3. Perform hot upgrade to v2
  4. Verify v2 is running with preserved state and same PID
  5. Restart machines
  6. Verify v2 is still running (startup reapply worked)
  7. Cold deploy v3
  8. Verify v3 is running and stale hot upgrade was NOT reapplied

  Requirements:
  - test/fly_deploy/test_app must be set up with Fly app
  - AWS credentials must be configured in Fly secrets
  - FLY_API_TOKEN must be set in secrets
  """

  use ExUnit.Case, async: false

  @test_app_dir Path.expand("../../test_app", __DIR__)
  @app_name "hot-test-app"

  setup_all do
    # Verify we have required environment
    unless System.find_executable("fly") do
      raise "fly CLI not found in PATH"
    end

    # Copy fly_deploy library source to test_app/priv/fly_deploy
    IO.puts("Copying fly_deploy library to test_app/priv/fly_deploy...")
    src_dir = Path.join([__DIR__, "..", ".."])
    priv_fly_deploy_dir = Path.join(@test_app_dir, "priv/fly_deploy")

    # Remove old priv/fly_deploy
    File.rm_rf!(priv_fly_deploy_dir)
    File.mkdir_p!(priv_fly_deploy_dir)

    # Copy entire fly_deploy project (mix.exs, lib/, etc.)
    File.cp!(Path.join(src_dir, "mix.exs"), Path.join(priv_fly_deploy_dir, "mix.exs"))
    File.cp_r!(Path.join(src_dir, "lib"), Path.join(priv_fly_deploy_dir, "lib"))

    IO.puts("  ✓ Source files copied to priv/fly_deploy")

    # Install dependencies in test_app
    IO.puts("Installing test_app dependencies...")
    {_output, 0} = System.cmd("mix", ["deps.get"], cd: @test_app_dir, into: IO.stream())
    IO.puts("  ✓ Dependencies installed")

    # Get app URL (don't need to verify it exists first)
    app_url = "https://#{@app_name}.fly.dev"

    %{app_url: app_url}
  end

  @tag :e2e
  @tag timeout: :infinity
  test "complete hot upgrade cycle with startup reapply", %{app_url: app_url} do
    IO.puts("\n=== Starting E2E Hot Upgrade Test ===\n")

    # Scale down to 1 machine to avoid load balancing issues with in-memory counter state
    System.cmd("fly", ["scale", "count", "1", "--yes", "-a", @app_name], cd: @test_app_dir)
    Process.sleep(3000)

    # Step 1: Deploy initial version (v1)
    IO.puts("Step 1: Deploying initial version (v1)...")
    ensure_health_controller_version("v1")
    update_counter_module("v1")
    deploy_cold()
    wait_for_deployment()
    assert_health_response(app_url, "ok-v1")
    IO.puts("✓ Initial deployment successful (v1)\n")

    # Step 2: Increment counter and capture state before upgrade
    IO.puts("Step 2: Incrementing counter before hot upgrade...")
    increment_counter(app_url, 5)
    before_upgrade = get_health_check(app_url)
    assert before_upgrade["status"] == "ok-v1"
    assert before_upgrade["counter"]["count"] == 5
    assert before_upgrade["counter"]["version"] == "v1"
    before_pid = before_upgrade["counter"]["pid"]

    IO.puts(
      "  Counter before upgrade: count=#{before_upgrade["counter"]["count"]}, version=#{before_upgrade["counter"]["version"]}, pid=#{before_pid}"
    )

    IO.puts("✓ Counter state captured\n")

    # Step 2a: Verify v1 consolidated protocols exist before hot upgrade
    IO.puts("Step 2a: Verifying v1 consolidated protocols exist before hot upgrade...")

    machines_output =
      System.cmd("fly", ["machines", "list", "-a", "hot-test-app", "--json"], cd: @test_app_dir)

    machines = Jason.decode!(elem(machines_output, 0))
    machine_id = hd(machines)["id"]

    {pre_check, _} =
      System.cmd(
        "fly",
        [
          "ssh",
          "console",
          "-a",
          "hot-test-app",
          "--machine",
          machine_id,
          "-C",
          "/app/bin/test_app eval 'md5 = :crypto.hash(:md5, File.read!(\"/app/releases/0.1.0/consolidated/Elixir.String.Chars.beam\")) |> Base.encode16(); IO.puts(Jason.encode!(%{md5: md5}))'"
        ],
        cd: @test_app_dir
      )

    pre_json = pre_check |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, "{"))
    pre_md5_info = Jason.decode!(pre_json)
    v1_md5 = pre_md5_info["md5"]
    IO.puts("  Before hot upgrade - String.Chars MD5: #{v1_md5}")
    IO.puts("✓ Recorded v1 consolidated protocol MD5\n")

    # Step 3: Perform hot upgrade to v2
    IO.puts("Step 3: Performing hot upgrade to v2...")
    update_health_controller_version("v2")
    update_counter_module("v2")
    _hot_upgrade_output = deploy_hot()
    wait_for_deployment()

    # Step 3a: Verify status shows hot upgrade applied
    IO.puts("Step 3a: Checking fly_deploy.status after hot upgrade...")
    {status_output, 0} = run_status_command()
    assert String.contains?(status_output, "Hot Upgrade:")
    assert String.contains?(status_output, "v0.1.0")
    refute String.contains?(status_output, "Hot Upgrade: None")
    IO.puts("✓ Status correctly shows hot upgrade applied\n")

    # Step 4: Verify counter state persisted, PID unchanged, and version updated
    IO.puts("Step 4: Verifying counter state after hot upgrade...")
    after_upgrade = get_health_check(app_url)
    assert after_upgrade["status"] == "ok-v2"

    assert after_upgrade["counter"]["count"] == 5,
           "Counter value should persist through hot upgrade"

    assert after_upgrade["counter"]["version"] == "v2",
           "Version should update from v1 to v2 (code_change was called)"

    after_pid = after_upgrade["counter"]["pid"]
    assert after_pid == before_pid, "Counter PID should remain the same (process not restarted)"

    IO.puts(
      "  Counter after upgrade: count=#{after_upgrade["counter"]["count"]}, version=#{after_upgrade["counter"]["version"]}, pid=#{after_pid}"
    )

    IO.puts(
      "✓ Hot upgrade successful - counter state preserved, version updated to v2, PID unchanged\n"
    )

    # Step 4a: Verify consolidated protocol implementation was upgraded
    IO.puts("Step 4a: Verifying consolidated protocol (String.Chars) was upgraded...")

    # First, verify the protocol is actually consolidated (not falling back to non-consolidated)
    assert after_upgrade["counter"]["protocol_consolidated"] == true,
           "String.Chars protocol should be consolidated"

    # The string_representation uses the String.Chars protocol implementation
    # v1 format: "Counter[...]"
    # v2 format: "CounterV2[...]" (note the "V2" prefix)
    # If it shows "CounterV2[", that proves the protocol implementation was upgraded
    assert String.starts_with?(after_upgrade["counter"]["string_representation"], "CounterV2["),
           "Protocol implementation should use v2 format starting with 'CounterV2[' (got: #{after_upgrade["counter"]["string_representation"]})"

    IO.puts("  Protocol consolidated: #{after_upgrade["counter"]["protocol_consolidated"]}")
    IO.puts("  String representation: #{after_upgrade["counter"]["string_representation"]}")

    IO.puts(
      "✓ Consolidated protocol upgraded - String.Chars implementation changed from v1 to v2\n"
    )

    # Step 4b: Check if consolidated beam MD5 changed (proves it was copied)
    # V2 adds TestApp.Counter.MetricsSnapshot struct with String.Chars protocol implementation
    # This forces the consolidated protocol dispatch table to change, which changes the beam MD5
    # If consolidated protocols aren't being copied, the MD5 would stay the same
    IO.puts("Step 4b: Verifying consolidated protocol beam file was updated...")

    {post_check, _} =
      System.cmd(
        "fly",
        [
          "ssh",
          "console",
          "-a",
          "hot-test-app",
          "--machine",
          machine_id,
          "-C",
          "/app/bin/test_app eval 'md5 = :crypto.hash(:md5, File.read!(\"/app/releases/0.1.0/consolidated/Elixir.String.Chars.beam\")) |> Base.encode16(); IO.puts(Jason.encode!(%{md5: md5}))'"
        ],
        cd: @test_app_dir
      )

    post_json = post_check |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, "{"))
    post_md5_info = Jason.decode!(post_json)
    v2_md5 = post_md5_info["md5"]

    IO.puts("  After hot upgrade - String.Chars MD5: #{v2_md5}")
    IO.puts("  MD5 changed: #{v1_md5 != v2_md5}")

    assert v1_md5 != v2_md5,
           "Consolidated protocol beam MD5 must change after hot upgrade (proves it was copied). V1: #{v1_md5}, V2: #{v2_md5}"

    IO.puts(
      "✓ VERIFIED: Consolidated protocol beam file was copied (MD5 changed from v1 to v2)\n"
    )

    # Step 5: Restart machines
    IO.puts("Step 5: Restarting all machines...")
    restart_all_machines()
    wait_for_deployment()
    IO.puts("✓ Machines restarted\n")

    # Step 6: Verify v2 is still running and counter was reset (new process)
    IO.puts("Step 6: Verifying startup reapply...")
    after_restart = get_health_check(app_url)
    assert after_restart["status"] == "ok-v2"
    assert after_restart["counter"]["count"] == 0, "Counter should reset after restart"

    assert after_restart["counter"]["version"] == "v2",
           "Version should be v2 (fresh init with v2 code)"

    # Verify consolidated protocol is still active after restart
    assert after_restart["counter"]["protocol_consolidated"] == true,
           "String.Chars protocol should still be consolidated after restart"

    assert String.starts_with?(after_restart["counter"]["string_representation"], "CounterV2["),
           "Protocol implementation should still be v2 after restart"

    restart_pid = after_restart["counter"]["pid"]
    refute restart_pid == before_pid, "Counter should have new PID after restart"

    IO.puts(
      "  Counter after restart: count=#{after_restart["counter"]["count"]}, version=#{after_restart["counter"]["version"]}, pid=#{restart_pid}"
    )

    IO.puts("  Protocol consolidated: #{after_restart["counter"]["protocol_consolidated"]}")

    IO.puts(
      "✓ Startup reapply successful - still running v2 with fresh state and consolidated protocols\n"
    )

    # Step 7: Cold deploy v3 and verify hot upgrade does NOT get applied
    IO.puts("Step 7: Cold deploying v3 to verify hot upgrade is not reapplied...")
    update_health_controller_version("v3")
    update_counter_module("v3")
    deploy_cold()
    wait_for_deployment()
    IO.puts("✓ Cold deployed v3\n")

    # Step 8: Verify we're running v3 (NOT v2 from hot upgrade)
    IO.puts("Step 8: Verifying v3 is running (hot upgrade not reapplied over cold deploy)...")
    after_cold = get_health_check(app_url)
    assert after_cold["status"] == "ok-v3", "Should be running v3 after cold deploy"
    assert after_cold["counter"]["count"] == 0, "Counter should reset after cold deploy"

    assert after_cold["counter"]["version"] == "v3",
           "Version should be v3, NOT v2 from stale hot upgrade"

    IO.puts(
      "  Counter after cold deploy: count=#{after_cold["counter"]["count"]}, version=#{after_cold["counter"]["version"]}"
    )

    IO.puts("✓ Cold deploy successful - v3 running, stale hot upgrade was NOT reapplied\n")

    IO.puts("=== E2E Hot Upgrade Test Complete ===\n")
  end

  # Helper Functions

  defp ensure_health_controller_version(version) do
    controller_path =
      Path.join(@test_app_dir, "lib/test_app_web/controllers/health_controller.ex")

    content = """
    defmodule TestAppWeb.HealthController do
      use TestAppWeb, :controller

      def show(conn, _params) do
        counter_info = TestApp.Counter.get_info()

        json(conn, %{
          status: "ok-#{version}",
          counter: %{
            count: counter_info.count,
            version: counter_info.version,
            pid: inspect(counter_info.pid),
            protocol_version: counter_info.protocol_version,
            string_representation: counter_info.string_representation,
            protocol_consolidated: counter_info.protocol_consolidated
          }
        })
      end
    end
    """

    File.write!(controller_path, content)
    IO.puts("  Updated health controller to #{version}")
  end

  defp update_health_controller_version(version) do
    ensure_health_controller_version(version)
  end

  defp update_counter_module(version) do
    counter_path = Path.join(@test_app_dir, "lib/test_app/counter.ex")

    # Determine protocol version based on counter version
    protocol_version =
      case version do
        "v1" -> "v1"
        "v2" -> "v2"
        _ -> "v1"
      end

    # Change the protocol implementation format string between v1 and v2
    protocol_format =
      case version do
        "v1" ->
          "Counter[count=\#{state.count}, version=\#{state.version}, protocol_v=\#{state.protocol_version}]"

        "v2" ->
          "CounterV2[count=\#{state.count}, version=\#{state.version}, protocol_v=\#{state.protocol_version}]"

        _ ->
          "Counter[count=\#{state.count}, version=\#{state.version}, protocol_v=\#{state.protocol_version}]"
      end

    # V2 adds a new struct type to force consolidated protocol dispatch table change
    metrics_snapshot_struct =
      if version == "v2" do
        """

          # V2 ONLY: New struct to test consolidated protocol dispatch changes
          defmodule MetricsSnapshot do
            @moduledoc false
            defstruct [:count, :timestamp]
          end
        """
      else
        ""
      end

    # V2 adds get_metrics_snapshot function
    metrics_snapshot_client =
      if version == "v2" do
        """

          def get_metrics_snapshot do
            GenServer.call(__MODULE__, :get_metrics_snapshot)
          end
        """
      else
        ""
      end

    # V2 adds handle_call for get_metrics_snapshot
    metrics_snapshot_handler =
      if version == "v2" do
        """

          @impl true
          def handle_call(:get_metrics_snapshot, _from, state) do
            snapshot = %MetricsSnapshot{count: state.count, timestamp: System.system_time(:second)}
            {:reply, to_string(snapshot), state}
          end
        """
      else
        ""
      end

    # V2 adds String.Chars implementation for MetricsSnapshot
    metrics_snapshot_protocol =
      if version == "v2" do
        """

        # V2 ONLY: New protocol implementation to force consolidated dispatch table change
        defimpl String.Chars, for: TestApp.Counter.MetricsSnapshot do
          def to_string(%TestApp.Counter.MetricsSnapshot{} = snap) do
            "Metrics[count=\#{snap.count}, ts=\#{snap.timestamp}]"
          end
        end
        """
      else
        ""
      end

    content = """
    defmodule TestApp.Counter do
      @moduledoc \"\"\"
      A simple GenServer counter for testing hot code upgrades.
      \"\"\"
      use GenServer

      @counter_vsn #{inspect(version)}

      # Define a struct to test protocol implementations
      defmodule State do
        @moduledoc false
        defstruct [:count, :version, :protocol_version]
      end
    #{metrics_snapshot_struct}
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
    #{metrics_snapshot_client}
      def vsn, do: @counter_vsn

      # Server Callbacks

      @impl true
      def init(_opts) do
        {:ok, %State{count: 0, version: @counter_vsn, protocol_version: #{inspect(protocol_version)}}}
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
    #{metrics_snapshot_handler}
      @impl true
      def code_change(_old_vsn, state, _extra) do
        # Migrate state - update version to new module version to prove code_change was called
        # Preserve count but update version field to match new module version
        {:ok, Map.put(state, :version, vsn())}
      end
    end

    # Protocol implementation for testing consolidated protocol hot upgrades
    defimpl String.Chars, for: TestApp.Counter.State do
      def to_string(%TestApp.Counter.State{} = state) do
        "#{protocol_format}"
      end
    end
    #{metrics_snapshot_protocol}
    """

    File.write!(counter_path, content)
    IO.puts("  Updated Counter module to version #{version} (protocol_v=#{protocol_version})")
  end

  defp deploy_cold do
    IO.puts(
      "  Running: fly deploy --remote-only --smoke-checks=false -a #{@app_name} (inside #{@test_app_dir})"
    )

    {output, exit_code} =
      System.cmd(
        "fly",
        ["deploy", "--remote-only", "--smoke-checks=false", "-a", @app_name],
        cd: @test_app_dir,
        into: IO.stream()
      )

    if exit_code != 0 do
      raise "Cold deploy failed with exit code #{exit_code}"
    end

    output
  end

  defp deploy_hot do
    IO.puts("  Running: mix fly_deploy.hot")

    {output, exit_code} =
      System.cmd(
        "mix",
        ["fly_deploy.hot"],
        cd: @test_app_dir,
        into: IO.stream()
      )

    if exit_code != 0 do
      raise "Hot deploy failed with exit code #{exit_code}"
    end

    output
  end

  defp run_status_command do
    IO.puts("  Running: mix fly_deploy.status")

    System.cmd(
      "mix",
      ["fly_deploy.status"],
      cd: @test_app_dir,
      stderr_to_stdout: true
    )
  end

  defp restart_all_machines do
    {output, 0} =
      System.cmd("fly", ["machines", "list", "-a", @app_name, "--json"], cd: @test_app_dir)

    machines = Jason.decode!(output)

    app_machines =
      Enum.filter(machines, fn m ->
        m["state"] == "started" && m["config"]["services"] != nil && m["config"]["services"] != []
      end)

    IO.puts("  Found #{length(app_machines)} app machines to restart")

    Enum.each(app_machines, fn machine ->
      machine_id = machine["id"]
      IO.puts("  Restarting machine #{machine_id}...")

      {_output, 0} =
        System.cmd("fly", ["machine", "restart", machine_id, "-a", @app_name], cd: @test_app_dir)
    end)
  end

  defp wait_for_deployment do
    IO.puts("  Waiting for deployment to stabilize (5 seconds)...")
    Process.sleep(5000)
  end

  defp increment_counter(app_url, times) do
    counter_url = "#{app_url}/api/counter/increment"

    Enum.each(1..times, fn _ ->
      Req.post!(counter_url, retry: :transient, max_retries: 3)
    end)
  end

  defp get_health_check(app_url) do
    health_url = "#{app_url}/api/health"
    response = Req.get!(health_url)
    response.body
  end

  defp assert_health_response(app_url, expected_status) do
    health_url = "#{app_url}/api/health"
    IO.puts("  Checking #{health_url}")

    # Retry up to 10 times with 2 second delays
    result =
      Enum.reduce_while(1..10, nil, fn attempt, _acc ->
        case fetch_health(health_url) do
          {:ok, ^expected_status} ->
            {:halt, :ok}

          {:ok, other_status} ->
            IO.puts(
              "  ⚠️  Attempt #{attempt}/10: Got status '#{other_status}', expected '#{expected_status}'"
            )

            if attempt < 10 do
              Process.sleep(2000)
              {:cont, nil}
            else
              {:halt, {:error, :wrong_status, other_status}}
            end

          {:error, reason} ->
            IO.puts("  ⚠️  Attempt #{attempt}/10: Request failed: #{inspect(reason)}")

            if attempt < 10 do
              Process.sleep(2000)
              {:cont, nil}
            else
              {:halt, {:error, :request_failed, reason}}
            end
        end
      end)

    case result do
      :ok ->
        IO.puts("  ✓ Health check returned '#{expected_status}'")

      {:error, :wrong_status, got_status} ->
        flunk("Health check returned '#{got_status}' but expected '#{expected_status}'")

      {:error, :request_failed, reason} ->
        flunk("Health check failed after 10 attempts: #{inspect(reason)}")
    end
  end

  defp fetch_health(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body["status"]}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
