defmodule FlyDeploy.Orchestrator do
  @moduledoc false
  # Builds tarballs, uploads to S3, triggers upgrades across all machines

  require Logger

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
    timeout = String.to_integer(System.get_env("DEPLOY_TIMEOUT", "120000"))

    # track start time
    start_time = System.monotonic_time(:millisecond)

    # try to acquire deployment lock
    try do
      acquire_lock(app, image_ref, bucket)

      # step 1: Build tarball (includes marker file with upgrade info)
      {tarball_path, tarball_info} = build_tarball(app, image_ref, version)

      # step 2: Upload to Tigris
      url = upload_to_tigris(tarball_path, app, version, bucket)

      # step 3: Update current state with hot upgrade info
      update_current_state_with_hot_upgrade(url, app, image_ref, version, bucket)

      # step 4: Wait for machines to pick up and apply the upgrade (via polling)
      upgrade_id = upgrade_id_from_ref(image_ref)
      results = wait_for_machine_upgrades(app, upgrade_id, bucket, timeout)

      duration = System.monotonic_time(:millisecond) - start_time

      print_summary(results, tarball_info, duration)

      # step 5: Clean up old results (keep last 5)
      cleanup_old_results(app, bucket, 5)
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
      System.get_env("AWS_ENDPOINT_URL_S3", "https://t3.storage.dev")
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

  defp upgrade_id_from_ref(image_ref) do
    # Extract deployment ID from image ref like "registry.fly.io/app:deployment-01KEW7VFV2K1D4NA9GKZYMFW3R"
    case Regex.run(~r/deployment-([A-Z0-9]+)/, image_ref) do
      [_, id] -> id
      _ -> :crypto.hash(:sha256, image_ref) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    end
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
           headers: [{"x-tigris-consistent", "true"}],
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
           headers: [{"content-type", "application/json"}, {"x-tigris-consistent", "true"}],
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
           headers: [{"x-tigris-consistent", "true"}],
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

  defp build_tarball(app, source_image_ref, version) do
    mode = System.get_env("DEPLOY_MODE", "hot")
    IO.puts(ansi([:yellow], "--> Creating tarball (mode: #{mode})"))

    app_version = Application.spec(app, :vsn) |> to_string()
    tarball_path = Path.join(System.tmp_dir!(), "#{app}-#{app_version}.tar.gz")

    # create marker file with upgrade info - this proves the upgrade was applied
    marker_path = Path.join(System.tmp_dir!(), "fly_deploy_marker.json")

    marker_content =
      Jason.encode!(%{
        source_image_ref: source_image_ref,
        version: version,
        app_version: app_version,
        created_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    File.write!(marker_path, marker_content)

    {all_files, info} =
      if mode == "blue_green" do
        build_blue_green_file_list(app)
      else
        build_hot_file_list(app)
      end

    # create tar with all files plus the marker
    files_to_tar =
      Enum.map(all_files, fn path ->
        rel_path = Path.relative_to(path, "/app")
        {String.to_charlist(rel_path), String.to_charlist(path)}
      end)

    marker_entry = {~c"fly_deploy_marker.json", String.to_charlist(marker_path)}
    files_to_tar = [marker_entry | files_to_tar]

    # Use :dereference so NIF .so symlinks (e.g. crypto.so -> erts-*/lib/...)
    # are stored as real files. Without this, extracting to /tmp/ creates broken
    # symlinks because the relative path targets don't exist there.
    {:ok, tar} = :erl_tar.open(String.to_charlist(tarball_path), [:write, :compressed])

    Enum.each(files_to_tar, fn {name, source} ->
      :ok = :erl_tar.add(tar, source, name, [:dereference])
    end)

    :ok = :erl_tar.close(tar)

    tarball_size = File.stat!(tarball_path).size
    size_mb = Float.round(tarball_size / 1_048_576, 1)

    IO.puts(ansi([:green], "    ✓ Created #{info.summary} (#{size_mb} MB)"))

    {tarball_path, %{modules: info.module_count, static_files: info.static_count, size_bytes: tarball_size}}
  end

  # Blue-green: package the full release — the peer boots from scratch and needs everything
  defp build_blue_green_file_list(_app) do
    # Everything in lib/ — beams, .app files, NIFs (.so), priv dirs
    lib_files =
      Path.wildcard("/app/lib/**/*")
      |> Enum.filter(&File.regular?/1)

    # Everything in releases/ — sys.config, vm.args, boot files, consolidated protocols
    releases_files =
      Path.wildcard("/app/releases/**/*")
      |> Enum.filter(&File.regular?/1)

    all_files = lib_files ++ releases_files

    beam_count = Enum.count(all_files, &String.ends_with?(&1, ".beam"))
    static_count = Enum.count(lib_files, &String.contains?(&1, "/priv/static/"))

    info = %{
      module_count: beam_count,
      static_count: static_count,
      summary: "#{length(lib_files)} lib files + #{length(releases_files)} release files (full release for blue-green)"
    }

    {all_files, info}
  end

  # Hot: only beam files, consolidated protocols, and static assets
  defp build_hot_file_list(app) do
    beam_files = Path.wildcard("/app/lib/**/ebin/*.beam")
    app_resource_files = Path.wildcard("/app/lib/**/ebin/*.app")
    consolidated_files = Path.wildcard("/app/releases/*/consolidated/*.beam")

    static_files =
      Path.wildcard("/app/lib/#{app}-*/priv/static/**/*")
      |> Enum.filter(&File.regular?/1)

    all_files = beam_files ++ app_resource_files ++ consolidated_files ++ static_files
    static_count = length(static_files)
    static_info = if static_count > 0, do: " + #{static_count} static files", else: ""

    info = %{
      module_count: length(beam_files),
      static_count: static_count,
      summary: "#{length(beam_files)} modules + #{length(consolidated_files)} consolidated protocols#{static_info}"
    }

    {all_files, info}
  end

  defp upload_to_tigris(tarball_path, app, version, bucket) do
    IO.puts(ansi([:yellow], "--> Uploading to S3"))

    mode = System.get_env("DEPLOY_MODE", "hot")
    # Use separate S3 keys for blue-green vs hot tarballs so they don't overwrite each other.
    # On restart, PeerManager downloads the blue-green tarball (full release) and the peer's
    # Poller downloads the hot tarball (beam-only). Both must coexist in S3.
    object_key =
      if mode == "blue_green" do
        "releases/#{app}-#{version}-blue_green.tar.gz"
      else
        "releases/#{app}-#{version}.tar.gz"
      end

    content = File.read!(tarball_path)
    url = "#{s3_endpoint()}/#{bucket}/#{object_key}"

    response =
      Req.put!(url,
        receive_timeout: 60_000,
        connect_options: [timeout: 60_000],
        body: content,
        headers: [{"content-type", "application/gzip"}, {"x-tigris-consistent", "true"}],
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
             headers: [{"x-tigris-consistent", "true"}],
             aws_sigv4: aws_opts
           ) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          body

        {:ok, %{status: 404}} ->
          nil

        {:error, _reason} ->
          nil
      end

    mode = System.get_env("DEPLOY_MODE", "hot")

    upgrade_data = %{
      "version" => version,
      "source_image_ref" => source_image_ref,
      "tarball_url" => tarball_url,
      "deployed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Write to mode-specific field:
    # - hot: write hot_upgrade, preserve blue_green_upgrade
    # - blue_green: write blue_green_upgrade, clear hot_upgrade (new peer = fresh start)
    updated =
      case {mode, existing} do
        {_, nil} ->
          # no existing state - machines will initialize image_ref on boot
          if mode == "blue_green" do
            %{"blue_green_upgrade" => upgrade_data}
          else
            %{"hot_upgrade" => upgrade_data}
          end

        {"blue_green", current} ->
          current
          |> Map.put("blue_green_upgrade", upgrade_data)
          |> Map.put("hot_upgrade", nil)

        {_hot, current} ->
          Map.put(current, "hot_upgrade", upgrade_data)
      end

    # write updated state
    response =
      Req.put!(url,
        receive_timeout: 60_000,
        connect_options: [timeout: 60_000],
        json: updated,
        headers: [{"content-type", "application/json"}, {"x-tigris-consistent", "true"}],
        aws_sigv4: aws_opts
      )

    if response.status in 200..299 do
      IO.puts(ansi([:green], "    ✓ Updated"))
    else
      IO.puts(ansi([:yellow], "    ⚠ Metadata update failed (non-critical)"))
    end
  end

  defp wait_for_machine_upgrades(app, upgrade_id, bucket, timeout) do
    IO.puts(ansi([:yellow], "--> Waiting for machines to upgrade"))

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

    # Show which machines we're waiting for
    IO.puts("    Found #{length(machines)} machines:")

    Enum.each(machines, fn machine ->
      machine_id = String.slice(machine["id"], 0, 14)
      region = machine["region"]
      IO.puts("      • #{machine_id} (#{region})")
    end)

    IO.puts("")

    # Build a map of machine_id -> region for display
    machine_regions =
      machines
      |> Enum.map(fn m -> {m["id"], m["region"]} end)
      |> Map.new()

    expected_machine_ids = Map.keys(machine_regions)

    # Poll S3 for results until all machines report or timeout
    poll_for_results(app, upgrade_id, bucket, expected_machine_ids, machine_regions, timeout)
  end

  defp poll_for_results(app, upgrade_id, bucket, expected_ids, machine_regions, timeout) do
    start_time = System.monotonic_time(:millisecond)
    poll_interval = 500
    collected_results = %{}

    do_poll(
      app,
      upgrade_id,
      bucket,
      expected_ids,
      machine_regions,
      timeout,
      start_time,
      poll_interval,
      collected_results
    )
  end

  defp do_poll(
         app,
         upgrade_id,
         bucket,
         expected_ids,
         machine_regions,
         timeout,
         start_time,
         poll_interval,
         collected_results
       ) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > timeout do
      # Timeout - return what we have, mark missing as failed
      finalize_results(expected_ids, machine_regions, collected_results)
    else
      # Fetch any new results from S3
      {new_results, collected_results} =
        fetch_new_results(app, upgrade_id, bucket, expected_ids, collected_results)

      # Print any new results as they come in
      Enum.each(new_results, fn {machine_id, result} ->
        print_machine_result(machine_id, machine_regions, result)
      end)

      # Check if we have final results (completed or failed) for all machines
      all_final =
        Enum.all?(expected_ids, fn id ->
          case Map.get(collected_results, id) do
            %{"status" => status} when status in ["completed", "failed"] -> true
            _ -> false
          end
        end)

      if all_final do
        finalize_results(expected_ids, machine_regions, collected_results)
      else
        Process.sleep(poll_interval)

        do_poll(
          app,
          upgrade_id,
          bucket,
          expected_ids,
          machine_regions,
          timeout,
          start_time,
          poll_interval,
          collected_results
        )
      end
    end
  end

  defp fetch_new_results(app, upgrade_id, bucket, expected_ids, collected_results) do
    # Check each expected machine that we don't have a final result for yet
    # (pending doesn't count as final)
    incomplete_ids =
      Enum.filter(expected_ids, fn id ->
        case Map.get(collected_results, id) do
          nil -> true
          %{"status" => "pending"} -> true
          _ -> false
        end
      end)

    Enum.reduce(incomplete_ids, {%{}, collected_results}, fn machine_id,
                                                             {new_acc, collected_acc} ->
      case fetch_machine_result(app, upgrade_id, bucket, machine_id) do
        {:ok, result} ->
          prev = Map.get(collected_acc, machine_id)
          # Only count as "new" if status changed (or didn't exist before)
          is_new = is_nil(prev) || prev["status"] != result["status"]

          if is_new do
            {Map.put(new_acc, machine_id, result), Map.put(collected_acc, machine_id, result)}
          else
            {new_acc, collected_acc}
          end

        :not_found ->
          {new_acc, collected_acc}
      end
    end)
  end

  defp fetch_machine_result(app, upgrade_id, bucket, machine_id) do
    url = "#{s3_endpoint()}/#{bucket}/releases/#{app}-results/#{upgrade_id}/#{machine_id}.json"

    case Req.get(url,
           receive_timeout: 5_000,
           connect_options: [timeout: 5_000],
           headers: [{"x-tigris-consistent", "true"}],
           aws_sigv4: [
             access_key_id: aws_access_key_id(),
             secret_access_key: aws_secret_access_key(),
             service: "s3",
             region: aws_region()
           ]
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        :not_found

      _ ->
        :not_found
    end
  end

  defp print_machine_result(machine_id, machine_regions, result) do
    region = Map.get(machine_regions, machine_id, "???")
    short_id = String.slice(machine_id, 0, 14)

    case result["status"] do
      "pending" ->
        IO.puts(ansi([:yellow], "    ⏳ #{short_id} (#{region}) - upgrading..."))

      "completed" ->
        modules = result["modules_reloaded"] || 0
        processes = result["processes_succeeded"] || 0
        suspend_ms = result["suspend_duration_ms"]
        suspend_info = if suspend_ms, do: ", suspended #{suspend_ms}ms", else: ""

        IO.puts(
          ansi(
            [:green],
            "    ✓ #{short_id} (#{region}) - #{modules} modules, #{processes} processes#{suspend_info}"
          )
        )

      "failed" ->
        error = result["error"] || "Unknown error"
        IO.puts(ansi([:red], "    ✗ #{short_id} (#{region}) - FAILED"))
        IO.puts(ansi([:red], "      #{error}"))
    end
  end

  defp finalize_results(expected_ids, machine_regions, collected_results) do
    Enum.map(expected_ids, fn machine_id ->
      region = Map.get(machine_regions, machine_id, "???")

      case Map.get(collected_results, machine_id) do
        nil ->
          # Machine never reported - timeout
          IO.puts(
            ansi(
              [:red],
              "    ✗ #{String.slice(machine_id, 0, 14)} (#{region}) - TIMEOUT (no response)"
            )
          )

          %{
            machine_id: machine_id,
            region: region,
            success: false,
            error: "Timed out waiting for upgrade result"
          }

        %{"status" => "pending"} ->
          # Machine started but never finished - timeout
          IO.puts(
            ansi(
              [:red],
              "    ✗ #{String.slice(machine_id, 0, 14)} (#{region}) - TIMEOUT (stuck in pending)"
            )
          )

          %{
            machine_id: machine_id,
            region: region,
            success: false,
            error: "Timed out while upgrade was in progress"
          }

        result ->
          %{
            machine_id: machine_id,
            region: region,
            success: result["status"] == "completed",
            modules: result["modules_reloaded"] || 0,
            module_names: result["module_names"] || [],
            processes_succeeded: result["processes_succeeded"] || 0,
            process_names: result["process_names"] || [],
            processes_failed: result["processes_failed"] || 0,
            suspend_duration_ms: result["suspend_duration_ms"],
            error: result["error"]
          }
      end
    end)
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

  defp cleanup_old_results(app, bucket, keep) do
    prefix = "releases/#{app}-results/"

    case list_s3_objects(bucket, prefix) do
      {:ok, objects} ->
        # Extract unique upgrade_ids from object keys
        # Keys look like: releases/app-results/01KEW7VFV2K1D4NA9GKZYMFW3R/machine123.json
        upgrade_ids =
          objects
          |> Enum.map(fn key ->
            case String.split(key, "/") do
              [_, _, upgrade_id, _] -> upgrade_id
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()

        if length(upgrade_ids) > keep do
          # Deployment IDs are time-sortable, so keep the last N (most recent)
          ids_to_delete = Enum.drop(upgrade_ids, -keep)
          deleted_count = delete_results_for_upgrade_ids(bucket, prefix, ids_to_delete, objects)

          if deleted_count > 0 do
            IO.puts(ansi([:white], "    Cleaned up #{deleted_count} old result files"))
          end
        end

      {:error, _reason} ->
        # Silently ignore cleanup errors - not critical
        :ok
    end
  end

  defp list_s3_objects(bucket, prefix) do
    url = "#{s3_endpoint()}/#{bucket}?list-type=2&prefix=#{URI.encode(prefix)}"

    case Req.get(url,
           receive_timeout: 10_000,
           connect_options: [timeout: 10_000],
           headers: [{"x-tigris-consistent", "true"}],
           aws_sigv4: [
             access_key_id: aws_access_key_id(),
             secret_access_key: aws_secret_access_key(),
             service: "s3",
             region: aws_region()
           ]
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        # Parse XML response to extract object keys
        keys =
          Regex.scan(~r/<Key>([^<]+)<\/Key>/, body)
          |> Enum.map(fn [_, key] -> key end)

        {:ok, keys}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_results_for_upgrade_ids(bucket, prefix, upgrade_ids, all_objects) do
    # Find all objects belonging to the upgrade_ids we want to delete
    objects_to_delete =
      Enum.filter(all_objects, fn key ->
        Enum.any?(upgrade_ids, fn id -> String.contains?(key, "#{prefix}#{id}/") end)
      end)

    # Delete each object
    Enum.reduce(objects_to_delete, 0, fn key, count ->
      url = "#{s3_endpoint()}/#{bucket}/#{key}"

      case Req.delete(url,
             receive_timeout: 5_000,
             connect_options: [timeout: 5_000],
             headers: [{"x-tigris-consistent", "true"}],
             aws_sigv4: [
               access_key_id: aws_access_key_id(),
               secret_access_key: aws_secret_access_key(),
               service: "s3",
               region: aws_region()
             ]
           ) do
        {:ok, %{status: status}} when status in 200..299 -> count + 1
        _ -> count
      end
    end)
  end
end
