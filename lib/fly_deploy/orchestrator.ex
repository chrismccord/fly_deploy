defmodule FlyDeploy.Orchestrator do
  @moduledoc false
  # Builds tarballs, uploads to S3, triggers upgrades across all machines

  def run(opts \\ []) do
    IO.puts(ansi([:cyan, :bright], "==> Orchestrator starting"))

    # ensure required apps are started for HTTP requests
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:finch)

    # get required args from opts (passed from Mix task via eval command)
    app = Keyword.fetch!(opts, :app)
    image_ref = Keyword.fetch!(opts, :image_ref)

    # Look up bucket from Application env (set via Mix config) or BUCKET_NAME env var
    bucket = Application.get_env(:fly_deploy, :bucket) || System.get_env("BUCKET_NAME")

    if is_nil(bucket) do
      IO.puts(ansi([:red], "✗ No bucket configured!"))
      IO.puts("")

      IO.puts(
        "Set bucket in Mix config or ensure BUCKET_NAME env var is set via `fly storage create`"
      )

      System.halt(1)
    end

    # get config values from environment variables (passed from Mix task)
    version = System.get_env("DEPLOY_VERSION")
    max_concurrency = String.to_integer(System.get_env("DEPLOY_MAX_CONCURRENCY", "20"))
    timeout = String.to_integer(System.get_env("DEPLOY_TIMEOUT", "60000"))

    # track start time
    start_time = System.monotonic_time(:millisecond)

    # try to acquire deployment lock
    try do
      acquire_lock(app, image_ref, bucket)

      # step 1: Build tarball
      {tarball_path, tarball_info} = build_tarball(app)

      # step 2: Upload to Tigris
      url = upload_to_tigris(tarball_path, app, version, bucket)

      # step 3: Update current state with hot upgrade info
      update_current_state_with_hot_upgrade(url, app, image_ref, version, bucket)

      # step 4: Trigger reload on all machines
      results = trigger_machine_reloads(url, app, max_concurrency, timeout)

      duration = System.monotonic_time(:millisecond) - start_time

      print_summary(results, tarball_info, duration)
    after
      # always release the lock, even if deployment fails
      release_lock(app, bucket)
    end
  end

  defp ansi(codes, text) do
    IO.ANSI.format([codes, text, :reset])
  end

  defp s3_endpoint do
    Application.get_env(:fly_deploy, :aws_endpoint_url_s3) ||
      System.get_env("AWS_ENDPOINT_URL_S3", "https://fly.storage.tigris.dev")
  end

  defp aws_access_key_id do
    Application.get_env(:fly_deploy, :aws_access_key_id) ||
      System.fetch_env!("AWS_ACCESS_KEY_ID")
  end

  defp aws_secret_access_key do
    Application.get_env(:fly_deploy, :aws_secret_access_key) ||
      System.fetch_env!("AWS_SECRET_ACCESS_KEY")
  end

  defp aws_region do
    Application.get_env(:fly_deploy, :aws_region) ||
      System.get_env("AWS_REGION", "auto")
  end

  defp acquire_lock(app, deployment_id, bucket) do
    IO.puts(ansi([:yellow], "--> Acquiring deployment lock"))

    object_key = "releases/#{app}-deploy.lock"
    url = "#{s3_endpoint()}/#{bucket}/#{object_key}"

    aws_opts = [
      access_key_id: aws_access_key_id(),
      secret_access_key: aws_secret_access_key(),
      service: "s3",
      region: aws_region()
    ]

    force = System.get_env("DEPLOY_FORCE") == "true"
    locked_by = System.get_env("DEPLOY_LOCKED_BY", "unknown")
    lock_timeout = String.to_integer(System.get_env("DEPLOY_LOCK_TIMEOUT", "300"))

    # check if lock exists
    case Req.get(url,
           receive_timeout: 10_000,
           connect_options: [timeout: 10_000],
           aws_sigv4: aws_opts
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        # lock exists - check if expired or forced
        handle_existing_lock(body, force, lock_timeout, url, aws_opts, locked_by, deployment_id)

      {:ok, %{status: 404}} ->
        # no lock exists - create it
        create_lock(url, aws_opts, locked_by, deployment_id, lock_timeout)

      {:ok, %{status: 403}} ->
        # bucket likely doesn't exist or permission issue
        IO.puts(ansi([:red], "    ✗ Access denied checking lock (bucket may not exist)"))
        System.halt(1)

      {:error, reason} ->
        IO.puts(ansi([:red], "    ✗ Failed to check lock status: #{inspect(reason)}"))
        System.halt(1)
    end
  end

  defp handle_existing_lock(
         lock_data,
         force,
         lock_timeout,
         url,
         aws_opts,
         locked_by,
         deployment_id
       ) do
    locked_at = parse_timestamp(lock_data["locked_at"])
    age_seconds = DateTime.diff(DateTime.utc_now(), locked_at, :second)
    expired = age_seconds > lock_timeout

    cond do
      force ->
        IO.puts(ansi([:yellow], "    ⚠ Lock exists but --force specified, overriding"))
        IO.puts(ansi([:white], "      Previous lock: #{lock_data["locked_by"]}"))
        create_lock(url, aws_opts, locked_by, deployment_id, lock_timeout)

      expired ->
        IO.puts(
          ansi(
            [:yellow],
            "    ⚠ Found expired lock (#{age_seconds}s old, locked by #{lock_data["locked_by"]})"
          )
        )

        create_lock(url, aws_opts, locked_by, deployment_id, lock_timeout)

      true ->
        # lock is valid and not forced
        time_remaining = lock_timeout - age_seconds
        minutes = div(time_remaining, 60)

        IO.puts(ansi([:red], "    ✗ Deployment already in progress!"))
        IO.puts("")
        IO.puts(ansi([:white], "      Locked by: #{lock_data["locked_by"]}"))

        IO.puts(
          ansi([:white], "      Started at: #{format_timestamp(lock_data["locked_at"])} UTC")
        )

        IO.puts(ansi([:white], "      Time remaining: ~#{minutes} minutes"))
        IO.puts("")
        IO.puts(ansi([:white], "      Use --force to override (not recommended)"))
        IO.puts("")
        System.halt(1)
    end
  end

  defp create_lock(url, aws_opts, locked_by, deployment_id, lock_timeout) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, lock_timeout, :second)

    lock_content = %{
      "locked_by" => locked_by,
      "locked_at" => DateTime.to_iso8601(now),
      "deployment_id" => deployment_id,
      "expires_at" => DateTime.to_iso8601(expires_at)
    }

    case Req.put(url,
           receive_timeout: 10_000,
           connect_options: [timeout: 10_000],
           json: lock_content,
           headers: [{"content-type", "application/json"}],
           aws_sigv4: aws_opts
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        IO.puts(ansi([:green], "    ✓ Lock acquired"))

      {:ok, %{status: status}} ->
        IO.puts(ansi([:red], "    ✗ Failed to acquire lock (HTTP #{status})"))
        System.halt(1)

      {:error, reason} ->
        IO.puts(ansi([:red], "    ✗ Failed to acquire lock: #{inspect(reason)}"))
        System.halt(1)
    end
  end

  defp release_lock(app, bucket) do
    IO.puts(ansi([:yellow], "--> Releasing deployment lock"))

    object_key = "releases/#{app}-deploy.lock"
    url = "#{s3_endpoint()}/#{bucket}/#{object_key}"

    aws_opts = [
      access_key_id: aws_access_key_id(),
      secret_access_key: aws_secret_access_key(),
      service: "s3",
      region: aws_region()
    ]

    case Req.delete(url,
           receive_timeout: 10_000,
           connect_options: [timeout: 10_000],
           aws_sigv4: aws_opts
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        IO.puts(ansi([:green], "    ✓ Lock released"))

      {:ok, %{status: 404}} ->
        # lock already gone, that's fine
        IO.puts(ansi([:white], "    ✓ Lock already released"))

      {:ok, %{status: status}} ->
        IO.puts(ansi([:yellow], "    ⚠ Failed to release lock (HTTP #{status})"))

      {:error, reason} ->
        IO.puts(ansi([:yellow], "    ⚠ Failed to release lock: #{inspect(reason)}"))
    end
  end

  defp parse_timestamp(iso8601_string) do
    case DateTime.from_iso8601(iso8601_string) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp format_timestamp(iso8601_string) do
    case DateTime.from_iso8601(iso8601_string) do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> iso8601_string
    end
  end

  defp build_tarball(app) do
    IO.puts(ansi([:yellow], "--> Creating tarball"))

    version = Application.spec(app, :vsn) |> to_string()
    tarball_path = Path.join(System.tmp_dir!(), "#{app}-#{version}.tar.gz")

    # find all beam files (both lib and consolidated protocols)
    beam_files = Path.wildcard("/app/lib/**/ebin/*.beam")
    consolidated_files = Path.wildcard("/app/releases/*/consolidated/*.beam")

    all_files = beam_files ++ consolidated_files

    # create tar
    files_to_tar =
      Enum.map(all_files, fn path ->
        rel_path = Path.relative_to(path, "/app")
        {String.to_charlist(rel_path), String.to_charlist(path)}
      end)

    :ok = :erl_tar.create(String.to_charlist(tarball_path), files_to_tar, [:compressed])

    # check tarball size
    tarball_size = File.stat!(tarball_path).size
    size_mb = Float.round(tarball_size / 1_048_576, 1)

    IO.puts(
      ansi(
        [:green],
        "    ✓ Created #{length(beam_files)} modules + #{length(consolidated_files)} consolidated protocols (#{size_mb} MB)"
      )
    )

    {tarball_path, %{modules: length(all_files), size_bytes: tarball_size}}
  end

  defp upload_to_tigris(tarball_path, app, version, bucket) do
    IO.puts(ansi([:yellow], "--> Uploading to S3"))

    object_key = "releases/#{app}-#{version}.tar.gz"

    content = File.read!(tarball_path)
    url = "#{s3_endpoint()}/#{bucket}/#{object_key}"

    response =
      Req.put!(url,
        receive_timeout: 60_000,
        connect_options: [timeout: 60_000],
        body: content,
        headers: [{"content-type", "application/gzip"}],
        aws_sigv4: [
          access_key_id: aws_access_key_id(),
          secret_access_key: aws_secret_access_key(),
          service: "s3",
          region: aws_region()
        ]
      )

    if response.status in 200..299 do
      IO.puts(ansi([:green], "    ✓ Uploaded"))
      url
    else
      IO.puts(ansi([:red], "    ✗ Upload failed (status #{response.status})"))
      System.halt(1)
    end
  end

  defp update_current_state_with_hot_upgrade(tarball_url, app, source_image_ref, version, bucket) do
    IO.puts(ansi([:yellow], "--> Updating deployment metadata"))

    object_key = "releases/#{app}-current.json"
    url = "#{s3_endpoint()}/#{bucket}/#{object_key}"

    aws_opts = [
      access_key_id: aws_access_key_id(),
      secret_access_key: aws_secret_access_key(),
      service: "s3",
      region: aws_region()
    ]

    # read existing current state (if it exists)
    existing =
      case Req.get(url,
             receive_timeout: 10_000,
             connect_options: [timeout: 10_000],
             aws_sigv4: aws_opts
           ) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          body

        {:ok, %{status: 404}} ->
          nil

        {:error, _reason} ->
          nil
      end

    # merge hot upgrade info while preserving image_ref if it exists
    updated =
      case existing do
        nil ->
          # no existing state - machines will initialize image_ref on boot
          %{
            "hot_upgrade" => %{
              "version" => version,
              "source_image_ref" => source_image_ref,
              "tarball_url" => tarball_url,
              "deployed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }

        current ->
          # preserve existing image_ref, update hot_upgrade section
          Map.put(current, "hot_upgrade", %{
            "version" => version,
            "source_image_ref" => source_image_ref,
            "tarball_url" => tarball_url,
            "deployed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })
      end

    # write updated state
    response =
      Req.put!(url,
        receive_timeout: 60_000,
        connect_options: [timeout: 60_000],
        json: updated,
        headers: [{"content-type", "application/json"}],
        aws_sigv4: aws_opts
      )

    if response.status in 200..299 do
      IO.puts(ansi([:green], "    ✓ Updated"))
    else
      IO.puts(ansi([:yellow], "    ⚠ Metadata update failed (non-critical)"))
    end
  end

  defp trigger_machine_reloads(tarball_url, app, max_concurrency, timeout) do
    IO.puts(ansi([:yellow], "--> Upgrading machines"))

    # get machines from Fly API
    api_token = System.fetch_env!("FLY_API_TOKEN")
    app_name = System.fetch_env!("FLY_APP_NAME")

    machines_response =
      Req.get!("https://api.machines.dev/v1/apps/#{app_name}/machines",
        receive_timeout: 30_000,
        connect_options: [timeout: 30_000],
        headers: [
          {"authorization", "Bearer #{api_token}"},
          {"content-type", "application/json"}
        ]
      )

    machines =
      machines_response.body
      |> Enum.filter(&(&1["state"] == "started" && !(&1["config"]["services"] in [nil, []])))

    # Show which machines we're upgrading
    IO.puts("    Found #{length(machines)} machines:")

    Enum.each(machines, fn machine ->
      machine_id = String.slice(machine["id"], 0, 14)
      region = machine["region"]
      IO.puts("      • #{machine_id} (#{region})")
    end)

    IO.puts("")

    # reload each machine
    results =
      Task.async_stream(
        machines,
        fn machine ->
          reload_machine(machine["id"], machine["region"], tarball_url, app)
        end,
        timeout: timeout,
        max_concurrency: max_concurrency
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # filter to only app modules for successful results
    Enum.map(results, fn result ->
      if result.success do
        Map.update!(result, :module_names, fn modules -> filter_app_modules(modules, app) end)
      else
        result
      end
    end)
  end

  defp filter_app_modules(modules, app) do
    # get the app directory (e.g., /app/lib/test_app-0.1.0)
    app_dir = to_string(Application.app_dir(app))

    Enum.filter(modules, fn module_name ->
      # convert module name string back to atom to check code path
      module = String.to_existing_atom("Elixir.#{module_name}")

      case :code.which(module) do
        # module is loaded, check if it's in the app directory
        path when is_list(path) -> String.starts_with?(to_string(path), app_dir)
        # module not loaded or preloaded
        _ -> false
      end
    end)
  end

  defp reload_machine(machine_id, region, tarball_url, app) do
    app_name = System.fetch_env!("FLY_APP_NAME")
    api_token = System.fetch_env!("FLY_API_TOKEN")

    # use Fly Machines API to execute the reload script
    url = "https://api.machines.dev/v1/apps/#{app_name}/machines/#{machine_id}/exec"
    binary_name = Atom.to_string(app)

    # call the FlyDeploy.hot_upgrade function directly via RPC
    command =
      "/app/bin/#{binary_name} rpc \"FlyDeploy.hot_upgrade(\\\"#{tarball_url}\\\", :#{app})\""

    result =
      Req.post(url,
        receive_timeout: :timer.seconds(60),
        connect_options: [timeout: :timer.seconds(60)],
        headers: [
          {"authorization", "Bearer #{api_token}"},
          {"content-type", "application/json"}
        ],
        json: %{
          cmd: command,
          timeout: 30
        }
      )

    case result do
      {:ok, response} when response.status == 200 ->
        parse_machine_result(machine_id, region, response.body)

      {:ok, response} ->
        body_info = format_response_body(response.body)

        %{
          machine_id: machine_id,
          region: region,
          success: false,
          error: "HTTP #{response.status}: #{body_info}"
        }

      {:error, reason} ->
        %{
          machine_id: machine_id,
          region: region,
          success: false,
          error: "Request failed: #{inspect(reason)}"
        }
    end
  end

  defp format_response_body(body) when is_map(body) do
    # Try to extract useful error info from response
    cond do
      body["error"] -> body["error"]
      body["message"] -> body["message"]
      true -> inspect(body) |> String.slice(0, 200)
    end
  end

  defp format_response_body(body) when is_binary(body) do
    String.slice(body, 0, 200)
  end

  defp format_response_body(body) do
    inspect(body) |> String.slice(0, 200)
  end

  defp parse_machine_result(machine_id, region, body) do
    stdout = body["stdout"] || ""
    stderr = body["stderr"] || ""
    exit_code = body["exit_code"]

    # Parse JSON result from output
    # Look for __FLY_DEPLOY_RESULT__<json>__FLY_DEPLOY_RESULT__
    result =
      case Regex.run(~r/__FLY_DEPLOY_RESULT__(.+)__FLY_DEPLOY_RESULT__/s, stdout) do
        [_, json_str] ->
          case JSON.decode(json_str) do
            {:ok, data} ->
              success = data["success"] && exit_code == 0

              result = %{
                machine_id: machine_id,
                region: region,
                success: success,
                modules: data["modules_reloaded"],
                module_names: data["module_names"] || [],
                processes_succeeded: data["processes_succeeded"],
                process_names: data["process_names"] || [],
                processes_failed: data["processes_failed"],
                suspend_duration_ms: data["suspend_duration_ms"]
              }

              # Add error info if failed
              if success do
                result
              else
                error_parts = []

                error_parts =
                  if exit_code && exit_code != 0 do
                    error_parts ++ ["exit_code=#{exit_code}"]
                  else
                    error_parts
                  end

                error_parts =
                  if data["error"] do
                    error_parts ++ [data["error"]]
                  else
                    error_parts
                  end

                error_parts =
                  if stderr != "" do
                    error_parts ++ ["stderr: #{String.slice(stderr, 0, 300)}"]
                  else
                    error_parts
                  end

                error_msg =
                  if error_parts == [] do
                    "Upgrade reported failure"
                  else
                    Enum.join(error_parts, ", ")
                  end

                Map.put(result, :error, error_msg)
              end

            {:error, reason} ->
              %{
                machine_id: machine_id,
                region: region,
                success: false,
                error: "Failed to decode JSON: #{inspect(reason)}, exit_code=#{exit_code}"
              }
          end

        nil ->
          # Build detailed error with available info
          error_parts = ["No JSON result marker found"]

          error_parts =
            if exit_code && exit_code != 0 do
              error_parts ++ ["exit_code=#{exit_code}"]
            else
              error_parts
            end

          error_parts =
            if stderr != "" do
              truncated_stderr = String.slice(stderr, 0, 300)
              error_parts ++ ["stderr: #{truncated_stderr}"]
            else
              error_parts
            end

          error_parts =
            if stdout != "" do
              truncated_stdout = String.slice(stdout, 0, 300)
              error_parts ++ ["stdout: #{truncated_stdout}"]
            else
              error_parts ++ ["stdout: (empty)"]
            end

          %{
            machine_id: machine_id,
            region: region,
            success: false,
            error: Enum.join(error_parts, ", ")
          }
      end

    # print status for this machine
    if result.success do
      suspend_info =
        if result.suspend_duration_ms,
          do: ", suspended #{result.suspend_duration_ms}ms",
          else: ""

      IO.puts(
        ansi(
          [:green],
          "    ✓ #{String.slice(machine_id, 0, 14)} (#{region}) - #{result.modules} modules, #{result.processes_succeeded} processes#{suspend_info}"
        )
      )
    else
      error_msg = Map.get(result, :error, "Unknown error")
      IO.puts(ansi([:red], "    ✗ #{String.slice(machine_id, 0, 14)} (#{region}) - FAILED"))
      IO.puts(ansi([:red], "      #{error_msg}"))
    end

    result
  end

  defp print_summary(results, _tarball_info, duration) do
    IO.puts("")
    IO.puts(ansi([:cyan, :bright], "==> Hot Upgrade Summary"))

    total = length(results)
    succeeded = Enum.count(results, & &1.success)
    failed = total - succeeded

    if failed == 0 do
      IO.puts(ansi([:green], "    ✓ All #{total} machines upgraded successfully"))
    else
      IO.puts(ansi([:yellow], "    ⚠ #{succeeded}/#{total} machines succeeded, #{failed} failed"))
    end

    # show aggregate stats from successful machines
    if succeeded > 0 do
      successful_results = Enum.filter(results, & &1.success)

      # collect unique module and process names across all machines
      all_module_names =
        successful_results
        |> Enum.flat_map(& &1.module_names)
        |> Enum.uniq()
        |> Enum.sort()

      all_process_names =
        successful_results
        |> Enum.flat_map(& &1.process_names)
        |> Enum.uniq()
        |> Enum.sort()

      display_names("Modules upgraded", all_module_names, 10)
      display_names("Processes upgraded", all_process_names, 10)
    end

    duration_sec = Float.round(duration / 1000, 1)
    IO.puts(ansi([:white], "    Duration: #{duration_sec}s"))
    IO.puts("")
  end

  defp display_names(label, names, limit) do
    count = length(names)

    if count == 0 do
      IO.puts(ansi([:white], "    #{label}: 0"))
    else
      display_names = Enum.take(names, limit)
      names_str = Enum.join(display_names, ", ")

      if count > limit do
        IO.puts(ansi([:white], "    #{label}: #{count} (#{names_str}, +#{count - limit} more)"))
      else
        IO.puts(ansi([:white], "    #{label}: #{count} (#{names_str})"))
      end
    end
  end
end
