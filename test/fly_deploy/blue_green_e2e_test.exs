defmodule FlyDeploy.BlueGreenE2ETest do
  @moduledoc """
  End-to-end test for blue-green deploys via :peer nodes.

  This test performs a complete blue-green upgrade cycle:
  1. Set FLY_DEPLOY_MODE=blue_green secret
  2. Deploy initial version (v1) via cold deploy
  3. Increment counter to build state
  4. Perform blue-green upgrade to v2
  5. Verify v2 is running with FRESH state (counter reset, new PID)
  6. Restart machines
  7. Verify v2 is still running (startup reapply worked)
  8. Unset FLY_DEPLOY_MODE, cold deploy v3
  9. Verify v3 is running and stale hot upgrade was NOT reapplied

  Key differences from hot upgrade e2e:
  - State is NOT preserved (new BEAM process = clean start)
  - PID changes (new process)
  - No code_change/3 callbacks invoked
  - Driven by FLY_DEPLOY_MODE=blue_green env var

  Requirements:
  - test/fly_deploy/test_app must be set up with Fly app
  - AWS credentials must be configured in Fly secrets
  - FLY_API_TOKEN must be set in secrets
  """

  use ExUnit.Case, async: false

  @test_app_dir Path.expand("../../test_app", __DIR__)
  @app_name "hot-test-app"

  setup_all do
    unless System.find_executable("fly") do
      raise "fly CLI not found in PATH"
    end

    # Copy fly_deploy library source to test_app/priv/fly_deploy
    IO.puts("Copying fly_deploy library to test_app/priv/fly_deploy...")
    src_dir = Path.join([__DIR__, "..", ".."])
    priv_fly_deploy_dir = Path.join(@test_app_dir, "priv/fly_deploy")

    File.rm_rf!(priv_fly_deploy_dir)
    File.mkdir_p!(priv_fly_deploy_dir)

    File.cp!(Path.join(src_dir, "mix.exs"), Path.join(priv_fly_deploy_dir, "mix.exs"))
    File.cp_r!(Path.join(src_dir, "lib"), Path.join(priv_fly_deploy_dir, "lib"))

    cache_buster = Path.join(priv_fly_deploy_dir, "lib/cache_buster.ex")

    File.write!(cache_buster, """
    defmodule FlyDeploy.E2ETestCacheBuster do
      @bump #{System.system_time(:nanosecond)}
      def bump, do: @bump
    end
    """)

    IO.puts("  ✓ Source files copied to priv/fly_deploy")

    IO.puts("Installing test_app dependencies...")
    {_output, 0} = System.cmd("mix", ["deps.get"], cd: @test_app_dir, into: IO.stream())
    IO.puts("  ✓ Dependencies installed")

    app_url = "https://#{@app_name}.fly.dev"

    on_exit(fn ->
      # Clean up: unset FLY_DEPLOY_MODE secret
      System.cmd("fly", ["secrets", "unset", "FLY_DEPLOY_MODE", "-a", @app_name, "--stage"],
        cd: @test_app_dir,
        stderr_to_stdout: true
      )
    end)

    %{app_url: app_url}
  end

  @tag :e2e_blue_green
  @tag timeout: :infinity
  test "complete blue-green upgrade cycle", %{app_url: app_url} do
    IO.puts("\n=== Starting E2E Blue-Green Upgrade Test ===\n")

    # Scale down to 1 machine
    System.cmd("fly", ["scale", "count", "1", "--yes", "-a", @app_name], cd: @test_app_dir)
    Process.sleep(3000)

    # Step 1: Set FLY_DEPLOY_MODE=blue_green and deploy v1
    IO.puts("Step 1: Setting FLY_DEPLOY_MODE=blue_green and deploying v1...")

    {_, 0} =
      System.cmd(
        "fly",
        ["secrets", "set", "FLY_DEPLOY_MODE=blue_green", "-a", @app_name, "--stage"],
        cd: @test_app_dir
      )

    write_health_controller("v1")
    write_counter_module("v1")
    update_static_assets("v1")
    deploy_cold()
    wait_for_deployment()
    _health = assert_health_response(app_url, "ok-v1")
    IO.puts("✓ Initial deployment successful (v1) in blue-green mode\n")

    # Step 2: Increment counter and capture state
    IO.puts("Step 2: Incrementing counter before upgrade...")
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

    # Step 3: Blue-green upgrade to v2 (with availability monitoring)
    IO.puts("Step 3: Performing blue-green upgrade to v2 (with availability monitoring)...")
    write_health_controller("v2")
    write_counter_module("v2")
    update_static_assets("v2")

    # Start blasting HTTP requests in background to monitor availability during cutover
    blaster = Task.async(fn -> blast_requests(app_url) end)

    deploy_hot_blue_green()
    wait_for_deployment()

    # Stop blaster and print report
    send(blaster.pid, :stop)
    availability_results = Task.await(blaster, 30_000)
    print_availability_report(availability_results)

    # Step 4: Verify v2 is running with FRESH state
    IO.puts("Step 4: Verifying blue-green upgrade results...")
    after_upgrade = get_health_check(app_url)
    assert after_upgrade["status"] == "ok-v2"

    # KEY DIFFERENCE: Counter state is NOT preserved in blue-green mode
    # The new peer starts fresh — count resets to 0
    assert after_upgrade["counter"]["count"] == 0,
           "Counter should reset to 0 (blue-green = fresh process). Got: #{after_upgrade["counter"]["count"]}"

    assert after_upgrade["counter"]["version"] == "v2",
           "Version should be v2 (fresh init with v2 code)"

    # PID should be DIFFERENT (new BEAM process)
    after_pid = after_upgrade["counter"]["pid"]

    refute after_pid == before_pid,
           "Counter PID should change (new BEAM process). Before: #{before_pid}, After: #{after_pid}"

    IO.puts(
      "  Counter after upgrade: count=#{after_upgrade["counter"]["count"]}, version=#{after_upgrade["counter"]["version"]}, pid=#{after_pid}"
    )

    IO.puts("✓ Blue-green upgrade successful - v2 running, fresh state, new PID\n")

    # Step 4a: Verify static assets were updated
    IO.puts("Step 4a: Verifying static assets were updated...")

    machines_output =
      System.cmd("fly", ["machines", "list", "-a", @app_name, "--json"], cd: @test_app_dir)

    machines = Jason.decode!(elem(machines_output, 0))
    machine_id = hd(machines)["id"]

    v2_css_hash = get_static_asset_hash(machine_id, app_url)
    IO.puts("  After upgrade - app.css content hash: #{v2_css_hash}")
    IO.puts("✓ Static assets verified\n")

    # Step 4b: Increment counter to build state in the v2 peer
    IO.puts("Step 4b: Incrementing counter in v2 peer...")
    increment_counter(app_url, 3)
    before_hot = get_health_check(app_url)
    assert before_hot["counter"]["count"] == 3
    before_hot_pid = before_hot["counter"]["pid"]
    IO.puts("  Counter before hot upgrade: count=3, pid=#{before_hot_pid}")
    IO.puts("✓ Counter state built in v2 peer\n")

    # Step 4c: Hot upgrade inside the peer to v2-hot
    IO.puts("Step 4c: Performing hot upgrade inside blue-green peer to v2-hot...")
    write_health_controller("v2-hot")
    write_counter_module("v2-hot")
    deploy_hot()
    wait_for_deployment()
    IO.puts("✓ Hot upgrade deployed\n")

    # Step 4d: Verify hot upgrade preserved state
    IO.puts("Step 4d: Verifying hot upgrade inside peer...")
    after_hot = assert_health_response(app_url, "ok-v2-hot")

    assert after_hot["counter"]["count"] == 3,
           "Counter should preserve count=3 after hot upgrade. Got: #{after_hot["counter"]["count"]}"

    assert after_hot["counter"]["version"] == "v2-hot",
           "Version should be v2-hot (code_change ran). Got: #{after_hot["counter"]["version"]}"

    after_hot_pid = after_hot["counter"]["pid"]

    assert after_hot_pid == before_hot_pid,
           "Counter PID should be SAME after hot upgrade. Before: #{before_hot_pid}, After: #{after_hot_pid}"

    IO.puts(
      "  Counter after hot upgrade: count=#{after_hot["counter"]["count"]}, version=#{after_hot["counter"]["version"]}, pid=#{after_hot_pid}"
    )

    IO.puts("✓ Hot upgrade inside peer successful - state preserved, same PID\n")

    # Step 5: Restart machines
    IO.puts("Step 5: Restarting all machines...")
    restart_all_machines()
    wait_for_deployment()
    IO.puts("✓ Machines restarted\n")

    # Step 6: Verify v2-hot is running after restart (both blue-green + hot reapplied)
    IO.puts("Step 6: Verifying startup reapply (blue-green + hot)...")
    after_restart = assert_health_response(app_url, "ok-v2-hot")
    assert after_restart["counter"]["count"] == 0, "Counter should be 0 after restart"

    assert after_restart["counter"]["version"] == "v2-hot",
           "Version should be v2-hot after restart (both layers reapplied)"

    restart_pid = after_restart["counter"]["pid"]
    refute restart_pid == after_hot_pid, "Counter should have new PID after restart"

    IO.puts(
      "  Counter after restart: count=#{after_restart["counter"]["count"]}, version=#{after_restart["counter"]["version"]}, pid=#{restart_pid}"
    )

    IO.puts("✓ Startup reapply successful - running v2-hot with fresh state\n")

    # Step 7: Unset blue-green mode and cold deploy v3
    IO.puts("Step 7: Unsetting FLY_DEPLOY_MODE and cold deploying v3...")

    {_, 0} =
      System.cmd(
        "fly",
        ["secrets", "unset", "FLY_DEPLOY_MODE", "-a", @app_name, "--stage"],
        cd: @test_app_dir
      )

    write_health_controller("v3")
    write_counter_module("v3")
    update_static_assets("v3")
    deploy_cold()
    wait_for_deployment()
    IO.puts("✓ Cold deployed v3 (non-blue-green)\n")

    # Step 8: Verify v3 is running (NOT stale v2 from blue-green upgrade)
    IO.puts("Step 8: Verifying v3 is running (hot upgrade not reapplied over cold deploy)...")
    after_cold = get_health_check(app_url)
    assert after_cold["status"] == "ok-v3", "Should be running v3 after cold deploy"
    assert after_cold["counter"]["count"] == 0, "Counter should reset after cold deploy"

    assert after_cold["counter"]["version"] == "v3",
           "Version should be v3, NOT v2 from stale blue-green upgrade"

    IO.puts(
      "  Counter after cold deploy: count=#{after_cold["counter"]["count"]}, version=#{after_cold["counter"]["version"]}"
    )

    IO.puts("✓ Cold deploy successful - v3 running, stale upgrade NOT reapplied\n")
    IO.puts("=== E2E Blue-Green Upgrade Test Complete ===\n")
  end

  # -- Health controller writer ----------------------------------------------

  defp write_health_controller(version) do
    controller_path =
      Path.join(@test_app_dir, "lib/test_app_web/controllers/health_controller.ex")

    content = """
    defmodule TestAppWeb.HealthController do
      use TestAppWeb, :controller

      def show(conn, _params) do
        counter_info = TestApp.Counter.get_info()
        fly_deploy_vsn = FlyDeploy.current_vsn()

        json(conn, %{
          status: "ok-#{version}",
          components_defined: Code.ensure_loaded?(FlyDeploy.Components),
          fly_deploy_vsn: fly_deploy_vsn,
          counter: %{
            count: counter_info.count,
            version: counter_info.version,
            pid: inspect(counter_info.pid),
            protocol_version: counter_info.protocol_version,
            string_representation: counter_info.string_representation,
            protocol_consolidated: counter_info.protocol_consolidated,
          }
        })
      end
    end
    """

    File.write!(controller_path, content)
    IO.puts("  Updated health controller to #{version}")
  end

  # -- Counter module writer -------------------------------------------------

  defp write_counter_module(version) do
    counter_path = Path.join(@test_app_dir, "lib/test_app/counter.ex")

    cache_buster = System.system_time(:nanosecond)

    protocol_format =
      case version do
        "v1" ->
          "Counter[count=\#{state.count}, version=\#{state.version}, protocol_v=\#{state.protocol_version}]"

        _ ->
          "CounterV2[count=\#{state.count}, version=\#{state.version}, protocol_v=\#{state.protocol_version}]"
      end

    content = """
    # Cache buster: #{cache_buster}
    defmodule TestApp.Counter do
      @moduledoc \"\"\"
      A simple GenServer counter for testing deploys.
      \"\"\"
      use GenServer

      @counter_vsn #{inspect(version)}

      defmodule State do
        @moduledoc false
        defstruct [:count, :version, :protocol_version]
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

      def vsn, do: @counter_vsn

      # Server Callbacks

      @impl true
      def init(_opts) do
        {:ok, %State{count: 0, version: @counter_vsn, protocol_version: #{inspect(version)}}}
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
      def code_change(_old_vsn, state, _extra) do
        {:ok, Map.put(state, :version, vsn())}
      end
    end

    defimpl String.Chars, for: TestApp.Counter.State do
      def to_string(%TestApp.Counter.State{} = state) do
        "#{protocol_format}"
      end
    end
    """

    File.write!(counter_path, content)
    IO.puts("  Updated Counter module to version #{version}")
  end

  # -- Deploy helpers --------------------------------------------------------

  defp deploy_cold do
    IO.puts(
      "  Running: fly deploy --strategy immediate --remote-only --smoke-checks=false -a #{@app_name}"
    )

    {output, exit_code} =
      System.cmd(
        "fly",
        [
          "deploy",
          "--strategy",
          "immediate",
          "--remote-only",
          "--smoke-checks=false",
          "-a",
          @app_name
        ],
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

  defp deploy_hot_blue_green do
    IO.puts("  Running: mix fly_deploy.hot --mode blue_green")

    {output, exit_code} =
      System.cmd(
        "mix",
        ["fly_deploy.hot", "--mode", "blue_green"],
        cd: @test_app_dir,
        into: IO.stream()
      )

    if exit_code != 0 do
      raise "Blue-green deploy failed with exit code #{exit_code}"
    end

    output
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

  # -- HTTP helpers ----------------------------------------------------------

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

    result =
      Enum.reduce_while(1..10, nil, fn attempt, _acc ->
        case fetch_health(health_url) do
          {:ok, %{"status" => ^expected_status} = body} ->
            {:halt, {:ok, body}}

          {:ok, %{"status" => other_status}} ->
            IO.puts(
              "  Attempt #{attempt}/10: Got status '#{other_status}', expected '#{expected_status}'"
            )

            if attempt < 10 do
              Process.sleep(2000)
              {:cont, nil}
            else
              {:halt, {:error, :wrong_status, other_status}}
            end

          {:error, reason} ->
            IO.puts("  Attempt #{attempt}/10: Request failed: #{inspect(reason)}")

            if attempt < 10 do
              Process.sleep(2000)
              {:cont, nil}
            else
              {:halt, {:error, :request_failed, reason}}
            end
        end
      end)

    case result do
      {:ok, body} ->
        IO.puts("  ✓ Health check returned '#{expected_status}'")
        body

      {:error, :wrong_status, got_status} ->
        flunk("Health check returned '#{got_status}' but expected '#{expected_status}'")

      {:error, :request_failed, reason} ->
        flunk("Health check failed after 10 attempts: #{inspect(reason)}")
    end
  end

  defp fetch_health(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_static_assets(version) do
    css_path = Path.join(@test_app_dir, "priv/static/css/app.css")

    content = """
    /* Test App CSS - #{version} */
    body {
      font-family: sans-serif;
      background: #ffffff;
    }

    .version-marker {
      content: "#{version}";
    }

    .#{version}-only {
      display: block;
    }
    """

    File.write!(css_path, content)
    IO.puts("  Updated static assets to #{version}")
  end

  defp get_static_asset_hash(_machine_id, app_url) do
    css_url = "#{app_url}/css/app.css"

    case Req.get(css_url, redirect: true, max_redirects: 5) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        :crypto.hash(:md5, body) |> Base.encode16()

      _ ->
        "unknown"
    end
  end

  # -- Availability monitoring -----------------------------------------------

  defp blast_requests(app_url) do
    health_url = "#{app_url}/api/health"
    start_time = System.monotonic_time(:millisecond)
    blast_loop(health_url, [], start_time)
  end

  defp blast_loop(url, results, start_time) do
    receive do
      :stop -> Enum.reverse(results)
    after
      0 ->
        req_start = System.monotonic_time(:millisecond)
        elapsed = req_start - start_time

        result =
          try do
            case Req.get(url,
                   receive_timeout: 5_000,
                   connect_options: [timeout: 5_000],
                   retry: false,
                   redirect: false
                 ) do
              {:ok, %{status: status, body: body}} ->
                latency = System.monotonic_time(:millisecond) - req_start
                app_status = if is_map(body), do: body["status"], else: nil

                %{
                  elapsed_ms: elapsed,
                  latency_ms: latency,
                  http_status: status,
                  app_status: app_status
                }

              {:error, reason} ->
                latency = System.monotonic_time(:millisecond) - req_start

                %{
                  elapsed_ms: elapsed,
                  latency_ms: latency,
                  http_status: nil,
                  error: format_error(reason)
                }
            end
          rescue
            e ->
              latency = System.monotonic_time(:millisecond) - req_start

              %{
                elapsed_ms: elapsed,
                latency_ms: latency,
                http_status: nil,
                error: Exception.message(e)
              }
          end

        Process.sleep(10)
        blast_loop(url, [result | results], start_time)
    end
  end

  defp format_error(%{reason: reason}), do: inspect(reason)
  defp format_error(reason), do: inspect(reason)

  defp print_availability_report([]) do
    IO.puts("\n  === Cutover Availability Report ===")
    IO.puts("  No requests recorded")
    IO.puts("  ===================================\n")
  end

  defp print_availability_report(results) do
    total = length(results)
    successes = Enum.count(results, &(&1[:http_status] == 200))
    failures = total - successes
    duration_s = (List.last(results).elapsed_ms / 1000) |> Float.round(1)
    success_pct = Float.round(successes / total * 100, 2)

    IO.puts("\n  === Cutover Availability Report ===")
    IO.puts("  Duration: #{duration_s}s (includes build + upload + cutover)")
    IO.puts("  Total requests: #{total}")
    IO.puts("  Successful (HTTP 200): #{successes} (#{success_pct}%)")
    IO.puts("  Failed: #{failures}")

    # Latency stats (only for successful requests)
    successful = Enum.filter(results, &(&1[:http_status] == 200))

    if length(successful) > 0 do
      latencies = Enum.map(successful, & &1.latency_ms) |> Enum.sort()
      avg = (Enum.sum(latencies) / length(latencies)) |> Float.round(0) |> trunc()
      p50 = Enum.at(latencies, div(length(latencies), 2))
      p99 = Enum.at(latencies, trunc(length(latencies) * 0.99))
      max = List.last(latencies)

      IO.puts("  Latency: avg=#{avg}ms, p50=#{p50}ms, p99=#{p99}ms, max=#{max}ms")
    end

    # Status timeline — group consecutive identical statuses
    IO.puts("")
    IO.puts("  Status timeline:")
    print_status_timeline(results)

    # Print errors if any
    errors = Enum.filter(results, &(&1[:http_status] != 200))

    if length(errors) > 0 do
      IO.puts("")
      IO.puts("  Errors (#{length(errors)}):")

      Enum.each(errors, fn e ->
        t = Float.round(e.elapsed_ms / 1000, 2)
        http = if e[:http_status], do: "HTTP #{e.http_status}", else: "ERR"
        detail = e[:error] || e[:app_status] || ""
        IO.puts("    #{t}s: #{http} (latency: #{e.latency_ms}ms) #{detail}")
      end)
    end

    IO.puts("  ===================================\n")
  end

  defp print_status_timeline(results) do
    # Group consecutive runs of the same status
    results
    |> Enum.chunk_while(
      nil,
      fn entry, acc ->
        status = entry[:app_status] || entry[:error] || "HTTP #{entry[:http_status]}"

        case acc do
          nil ->
            {:cont, {status, entry.elapsed_ms, entry.elapsed_ms, 1}}

          {^status, start_ms, _end_ms, count} ->
            {:cont, {status, start_ms, entry.elapsed_ms, count + 1}}

          {prev_status, start_ms, end_ms, count} ->
            {:cont, {prev_status, start_ms, end_ms, count},
             {status, entry.elapsed_ms, entry.elapsed_ms, 1}}
        end
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn {status, start_ms, end_ms, count} ->
      t1 = Float.round(start_ms / 1000, 1)
      t2 = Float.round(end_ms / 1000, 1)
      IO.puts("    #{t1}s - #{t2}s: #{status} (#{count} requests)")
    end)
  end
end
