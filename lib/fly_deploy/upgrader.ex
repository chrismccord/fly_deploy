defmodule FlyDeploy.Upgrader do
  @moduledoc """
  Downloads and applies hot code upgrades on individual machines.

  This module handles the actual upgrade process:
  1. Download tarball from S3
  2. Extract and copy .beam files
  3. Suspend processes, load new code, upgrade processes, resume
  """

  require Logger

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

  @doc """
  Normal hot upgrade on a running system.

  Uses suspend/resume for safe process upgrades.

  ## Options

    * `:suspend_timeout` - Timeout in ms for suspending each process (default: 10_000)
  """
  def hot_upgrade(tarball_url, app, opts \\ []) do
    do_hot_upgrade(tarball_url, app, opts)
  rescue
    e ->
      Logger.error("""
      [#{inspect(__MODULE__)}] Hot upgrade failed!
        App: #{inspect(app)}
        Tarball: #{tarball_url}
        Error: #{Exception.message(e)}
        Stacktrace:
      #{Exception.format_stacktrace(__STACKTRACE__)}
      """)

      {:error, Exception.message(e)}
  end

  defp do_hot_upgrade(tarball_url, app, opts) do
    IO.puts("Downloading tarball from #{tarball_url}...")
    {:ok, _} = Application.ensure_all_started(:req)

    # Use a unique temp dir per invocation to avoid races between the parent
    # node's RPC-triggered upgrade and the peer's Poller-triggered upgrade —
    # both are separate OS processes sharing the same /tmp/ filesystem.
    tmp_dir = System.tmp_dir!()
    uid = :erlang.unique_integer([:positive])
    tmp_file_path = Path.join(tmp_dir, "fly_deploy_upgrade_#{uid}.tar.gz")
    upgrade_dir = Path.join(tmp_dir, "fly_deploy_hot_#{uid}")

    response =
      Req.get!(tarball_url,
        into: File.stream!(tmp_file_path, [:write, :binary]),
        raw: true,
        receive_timeout: 120_000,
        connect_options: [timeout: 30_000],
        retry: :transient,
        max_retries: 2,
        # Force strong consistency on Tigris to avoid reading stale/incomplete tarballs
        headers: [{"x-tigris-consistent", "true"}],
        aws_sigv4: [
          access_key_id: aws_access_key_id(),
          secret_access_key: aws_secret_access_key(),
          service: "s3",
          region: aws_region()
        ]
      )

    Logger.info("[#{inspect(__MODULE__)}] Download response: #{response.status}")

    # check downloaded tarball
    download_size = File.stat!(tmp_file_path).size
    IO.puts("  Downloaded: #{download_size} bytes")

    IO.puts("Extracting...")
    File.mkdir_p!(upgrade_dir)
    :ok = :erl_tar.extract(~c"#{tmp_file_path}", [:compressed, {:cwd, ~c"#{upgrade_dir}"}])

    # Copy marker file to /app to prove upgrade was applied on this machine
    marker_src = Path.join(upgrade_dir, "fly_deploy_marker.json")
    marker_dest = "/app/fly_deploy_marker.json"
    File.cp!(marker_src, marker_dest)
    Logger.info("[#{inspect(__MODULE__)}] Copied upgrade marker to #{marker_dest}")

    # copy beam files to loaded paths (only if MD5 differs)
    # Only check app-specific beam files to avoid unnecessary MD5 comparisons on dependencies
    IO.puts("Copying beam files to currently loaded paths...")
    all_beam_files = Path.wildcard(Path.join([upgrade_dir, "lib", "**", "ebin", "*.beam"]))

    # Filter to only the OTP app's beam files
    app_version_dir = Path.basename(Application.app_dir(app))

    beam_files =
      Enum.filter(all_beam_files, fn path ->
        String.contains?(path, "/#{app_version_dir}/ebin/")
      end)

    IO.puts(
      "  Found #{length(beam_files)} app beam files to check (#{length(all_beam_files)} total)"
    )

    # Get the app's ebin directory for new modules
    app_ebin_dir = Path.join(Application.app_dir(app), "ebin")

    {copied_count, new_modules} =
      Enum.reduce(beam_files, {0, []}, fn tarball_beam_path, {count, new_mods} ->
        beam_filename = Path.basename(tarball_beam_path)
        module_name = beam_filename |> String.replace_suffix(".beam", "") |> String.to_atom()

        case :code.which(module_name) do
          path when is_list(path) and path != [] ->
            # Existing module - copy to the loaded path
            loaded_path = List.to_string(path)

            # Guard against empty or invalid paths (can happen with load_binary edge cases)
            if loaded_path != "" and File.exists?(Path.dirname(loaded_path)) do
              # Compare MD5s to avoid unnecessary copies
              if beam_file_changed?(tarball_beam_path, module_name) do
                File.cp!(tarball_beam_path, loaded_path)
                {count + 1, new_mods}
              else
                {count, new_mods}
              end
            else
              # Path is invalid - treat as new module
              dest_path = Path.join(app_ebin_dir, beam_filename)
              File.cp!(tarball_beam_path, dest_path)

              Logger.info(
                "[#{inspect(__MODULE__)}] Copied module with invalid path: #{module_name} -> #{dest_path}"
              )

              {count + 1, [{module_name, dest_path} | new_mods]}
            end

          _ ->
            # new module - copy to app's ebin directory and track for explicit loading
            # In embedded mode (OTP releases), modules are NOT auto-loaded on demand
            dest_path = Path.join(app_ebin_dir, beam_filename)
            File.cp!(tarball_beam_path, dest_path)

            Logger.info(
              "[#{inspect(__MODULE__)}] Copied new module: #{module_name} -> #{dest_path}"
            )

            {count + 1, [{module_name, dest_path} | new_mods]}
        end
      end)

    # Explicitly load new modules - required in embedded mode (OTP releases)
    # where modules are NOT auto-loaded on demand
    if length(new_modules) > 0 do
      IO.puts("  Loading #{length(new_modules)} new modules (embedded mode)...")

      Enum.each(new_modules, fn {module_name, beam_path} ->
        beam_binary = File.read!(beam_path)

        case :code.load_binary(module_name, ~c"#{beam_path}", beam_binary) do
          {:module, ^module_name} ->
            Logger.info("[#{inspect(__MODULE__)}] Loaded new module: #{module_name}")

          {:error, reason} ->
            Logger.error(
              "[#{inspect(__MODULE__)}] Failed to load #{module_name}: #{inspect(reason)}"
            )
        end
      end)
    end

    IO.puts(
      "  ✓ Copied #{copied_count} beam files (#{length(new_modules)} new, #{copied_count - length(new_modules)} changed)"
    )

    # copy consolidated protocol beams
    IO.puts("Copying consolidated protocols...")

    consolidated_files =
      Path.wildcard(Path.join([upgrade_dir, "releases", "*", "consolidated", "*.beam"]))

    consolidated_copied_count =
      Enum.reduce(consolidated_files, 0, fn tarball_beam_path, acc ->
        # Extract the release version and beam filename
        # Path format: <upgrade_dir>/releases/0.1.0/consolidated/Elixir.Jason.Encoder.beam
        [_, version, _, beam_filename] =
          tarball_beam_path
          |> String.replace_prefix(upgrade_dir <> "/", "")
          |> Path.split()

        # target path on the running system
        releases_dir = Path.join(to_string(:code.root_dir()), "releases")
        target_path = Path.join([releases_dir, version, "consolidated", beam_filename])

        # ensure the consolidated directory exists
        target_dir = Path.dirname(target_path)
        File.mkdir_p!(target_dir)
        File.cp!(tarball_beam_path, target_path)
        acc + 1
      end)

    IO.puts("  ✓ Copied #{consolidated_copied_count} consolidated protocol beams")

    # copy static assets (priv/static)
    IO.puts("Copying static assets...")
    static_copied_count = copy_static_assets(upgrade_dir, app)
    IO.puts("  ✓ Copied #{static_copied_count} static files")

    # reset Phoenix static cache if static files were copied
    if static_copied_count > 0 do
      reset_static_cache(app)
    end

    IO.puts("Performing safe hot upgrade...")

    # perform the 4-phase upgrade (NIF modules are filtered out inside)
    result = safe_upgrade_application(app, opts)

    IO.puts("  Modules reloaded: #{result.modules_reloaded}")

    IO.puts(
      "  Processes upgraded: #{result.processes_succeeded} succeeded, #{result.processes_failed} failed, #{result.processes_skipped} skipped"
    )

    IO.puts("✅ Hot reload complete!")

    # Clean up temp files now that upgrade is complete
    File.rm_rf(upgrade_dir)
    File.rm(tmp_file_path)

    {:ok,
     %{
       modules_reloaded: result.modules_reloaded,
       module_names: result.module_names,
       processes_succeeded: result.processes_succeeded,
       process_names: result.process_names,
       processes_failed: result.processes_failed,
       suspend_duration_ms: result.suspend_duration_ms
     }}
  end

  @doc """
  Replay a hot upgrade on application startup.

  This is called when a machine restarts and needs to reapply a hot upgrade
  that was previously deployed. Unlike hot_upgrade/2, this:
  1. Pre-loads all changed modules AFTER copying beam files
  2. Doesn't need to suspend/resume processes (they don't exist yet)
  """
  def replay_upgrade_startup(tarball_url, app) do
    do_replay_upgrade_startup(tarball_url, app)
  rescue
    e ->
      Logger.error("""
      [#{inspect(__MODULE__)}] Startup hot upgrade replay failed!
        App: #{inspect(app)}
        Tarball: #{tarball_url}
        Error: #{Exception.message(e)}
        Stacktrace:
      #{Exception.format_stacktrace(__STACKTRACE__)}
      """)

      reraise e, __STACKTRACE__
  end

  defp do_replay_upgrade_startup(tarball_url, app) do
    IO.puts("Replaying hot upgrade from #{tarball_url} on startup...")
    {:ok, _} = Application.ensure_all_started(:req)

    tmp_dir = System.tmp_dir!()
    uid = :erlang.unique_integer([:positive])
    tmp_file_path = Path.join(tmp_dir, "fly_deploy_upgrade_#{uid}.tar.gz")
    upgrade_dir = Path.join(tmp_dir, "fly_deploy_hot_#{uid}")

    # download tarball
    response =
      Req.get!(tarball_url,
        into: File.stream!(tmp_file_path, [:write, :binary]),
        raw: true,
        receive_timeout: 120_000,
        connect_options: [timeout: 30_000],
        retry: :transient,
        max_retries: 2,
        # Force strong consistency on Tigris to avoid reading stale/incomplete tarballs
        headers: [{"x-tigris-consistent", "true"}],
        aws_sigv4: [
          access_key_id: aws_access_key_id(),
          secret_access_key: aws_secret_access_key(),
          service: "s3",
          region: aws_region()
        ]
      )

    Logger.info("[#{inspect(__MODULE__)}] Download response: #{response.status}")
    download_size = File.stat!(tmp_file_path).size
    IO.puts("  Downloaded: #{download_size} bytes")

    # extract tarball
    IO.puts("Extracting...")
    File.mkdir_p!(upgrade_dir)
    :ok = :erl_tar.extract(~c"#{tmp_file_path}", [:compressed, {:cwd, ~c"#{upgrade_dir}"}])

    # Copy marker file to /app to prove upgrade was applied on this machine
    marker_src = Path.join(upgrade_dir, "fly_deploy_marker.json")
    marker_dest = "/app/fly_deploy_marker.json"
    File.cp!(marker_src, marker_dest)
    Logger.info("[#{inspect(__MODULE__)}] Copied upgrade marker to #{marker_dest}")

    # copy beam files to loaded paths (only if MD5 differs)
    # Only check app-specific beam files to avoid unnecessary MD5 comparisons on dependencies
    IO.puts("Copying beam files to currently loaded paths...")
    all_beam_files = Path.wildcard(Path.join([upgrade_dir, "lib", "**", "ebin", "*.beam"]))

    # filter to only the OTP app's beam files
    app_version_dir = Path.basename(Application.app_dir(app))

    beam_files =
      Enum.filter(all_beam_files, fn path ->
        String.contains?(path, "/#{app_version_dir}/ebin/")
      end)

    IO.puts(
      "  Found #{length(beam_files)} app beam files to check (#{length(all_beam_files)} total)"
    )

    # Get the app's ebin directory for new modules
    app_ebin_dir = Path.join(Application.app_dir(app), "ebin")

    {copied_count, new_modules} =
      Enum.reduce(beam_files, {0, []}, fn tarball_beam_path, {count, new_mods} ->
        beam_filename = Path.basename(tarball_beam_path)
        module_name = beam_filename |> String.replace_suffix(".beam", "") |> String.to_atom()

        case :code.which(module_name) do
          path when is_list(path) and path != [] ->
            loaded_path = List.to_string(path)

            # Guard against empty or invalid paths (can happen with load_binary edge cases)
            if loaded_path != "" and File.exists?(Path.dirname(loaded_path)) do
              # Compare MD5s to avoid unnecessary copies
              if beam_file_changed?(tarball_beam_path, module_name) do
                File.cp!(tarball_beam_path, loaded_path)
                {count + 1, new_mods}
              else
                {count, new_mods}
              end
            else
              # Path is invalid - treat as new module
              dest_path = Path.join(app_ebin_dir, beam_filename)
              File.cp!(tarball_beam_path, dest_path)

              Logger.info(
                "[#{inspect(__MODULE__)}] Copied module with invalid path: #{module_name} -> #{dest_path}"
              )

              {count + 1, [{module_name, dest_path} | new_mods]}
            end

          _ ->
            # new module - copy to app's ebin directory and track for explicit loading
            dest_path = Path.join(app_ebin_dir, beam_filename)
            File.cp!(tarball_beam_path, dest_path)

            Logger.info(
              "[#{inspect(__MODULE__)}] Copied new module: #{module_name} -> #{dest_path}"
            )

            {count + 1, [{module_name, dest_path} | new_mods]}
        end
      end)

    # Explicitly load new modules - required in embedded mode (OTP releases)
    if length(new_modules) > 0 do
      IO.puts("  Loading #{length(new_modules)} new modules (embedded mode)...")

      Enum.each(new_modules, fn {module_name, beam_path} ->
        beam_binary = File.read!(beam_path)

        case :code.load_binary(module_name, ~c"#{beam_path}", beam_binary) do
          {:module, ^module_name} ->
            Logger.info("[#{inspect(__MODULE__)}] Loaded new module: #{module_name}")

          {:error, reason} ->
            Logger.error(
              "[#{inspect(__MODULE__)}] Failed to load #{module_name}: #{inspect(reason)}"
            )
        end
      end)
    end

    IO.puts(
      "  ✓ Copied #{copied_count} beam files (#{length(new_modules)} new, #{copied_count - length(new_modules)} changed)"
    )

    # copy consolidated protocol beams
    IO.puts("Copying consolidated protocol beams...")

    consolidated_files =
      Path.wildcard(Path.join([upgrade_dir, "releases", "*", "consolidated", "*.beam"]))

    consolidated_copied_count =
      Enum.reduce(consolidated_files, 0, fn tarball_beam_path, acc ->
        # extract the release version and beam filename
        [_, version, _, beam_filename] =
          tarball_beam_path
          |> String.replace_prefix(upgrade_dir <> "/", "")
          |> Path.split()

        # target path on the running system
        releases_dir = Path.join(to_string(:code.root_dir()), "releases")
        target_path = Path.join([releases_dir, version, "consolidated", beam_filename])

        # ensure the consolidated directory exists
        target_dir = Path.dirname(target_path)
        File.mkdir_p!(target_dir)
        File.cp!(tarball_beam_path, target_path)
        acc + 1
      end)

    IO.puts("  ✓ Copied #{consolidated_copied_count} consolidated protocol beams")

    # copy static assets (priv/static)
    IO.puts("Copying static assets...")
    static_copied_count = copy_static_assets(upgrade_dir, app)
    IO.puts("  ✓ Copied #{static_copied_count} static files")

    # reset Phoenix static cache if static files were copied
    # Note: On startup, the endpoint may not be fully started yet,
    # so we wrap in try/rescue - the fresh boot will load the new manifest anyway
    if static_copied_count > 0 do
      try do
        reset_static_cache(app)
      rescue
        e ->
          Logger.warning(
            "[#{inspect(__MODULE__)}] Could not reset static cache (endpoint may not be started yet): #{Exception.message(e)}"
          )
      end
    end

    # Load modified modules using load_binary for embedded mode compatibility
    # Filter out NIF modules — purging them triggers NIF re-init which can fail
    # in blue-green peers where .so files may not be at the expected path
    IO.puts("Loading modified modules...")
    all_modified = :code.modified_modules()
    {nif_modules, modified_modules} = Enum.split_with(all_modified, &has_nif?/1)

    if nif_modules != [] do
      Logger.info(
        "[#{inspect(__MODULE__)}] Skipping #{length(nif_modules)} NIF modules at startup: #{inspect(nif_modules)}"
      )
    end

    Enum.each(modified_modules, fn module ->
      :code.purge(module)

      case :code.which(module) do
        path when is_list(path) ->
          beam_path = List.to_string(path)
          beam_binary = File.read!(beam_path)
          :code.load_binary(module, path, beam_binary)
          Logger.info("[#{inspect(__MODULE__)}] Reloaded module: #{module}")

        _ ->
          Logger.warning("[#{inspect(__MODULE__)}] Could not find path for module: #{module}")
      end
    end)

    IO.puts(
      "  ✓ Loaded #{length(modified_modules)} modified modules: #{inspect(modified_modules)}"
    )

    IO.puts("✅ Startup hot upgrade replay complete!")

    # Clean up temp files
    File.rm_rf(upgrade_dir)
    File.rm(tmp_file_path)
  end

  # Safely upgrades all application processes with new code.
  #
  # Returns a map with upgrade statistics:
  # - `modules_reloaded` - Number of modules that were reloaded
  # - `processes_succeeded` - Number of processes successfully upgraded
  # - `processes_failed` - Number of processes that failed to upgrade
  # - `processes_skipped` - Number of processes skipped (not GenServer/proc_lib)
  defp safe_upgrade_application(app, opts) do
    Logger.info("[#{inspect(__MODULE__)}] Starting safe upgrade for #{app}")
    suspend_timeout = Keyword.get(opts, :suspend_timeout, 3_000)

    # detect changed modules, filtering out NIF-bearing modules
    # Purging a NIF module triggers NIF re-initialization which tries to load the .so
    # file from priv_dir. In blue-green peers, this path points to the extracted tarball
    # directory where the .so may not exist. NIF code changes require a cold deploy anyway.
    all_changed = :code.modified_modules()
    {nif_modules, changed_modules} = Enum.split_with(all_changed, &has_nif?/1)

    if nif_modules != [] do
      Logger.info(
        "[#{inspect(__MODULE__)}] Skipping #{length(nif_modules)} NIF modules (require cold deploy): #{inspect(nif_modules)}"
      )
    end

    Logger.info("[#{inspect(__MODULE__)}] Changed modules: #{inspect(changed_modules)}")

    # find all processes that need upgrading BEFORE loading new code
    processes = find_processes_to_upgrade(changed_modules)
    Logger.info("[#{inspect(__MODULE__)}] Found #{length(processes)} processes to upgrade")

    # phase 1: Suspend all processes in parallel
    # Sequential suspension with 10s timeouts can take forever if processes are unresponsive
    suspend_start = System.monotonic_time(:millisecond)

    Logger.info(
      "[#{inspect(__MODULE__)}] Phase 1: Suspending #{length(processes)} processes in parallel..."
    )

    suspended_processes =
      processes
      |> Task.async_stream(
        fn {pid, module} ->
          try do
            :sys.suspend(pid, suspend_timeout)
            Logger.info("[#{inspect(__MODULE__)}] Suspended process #{inspect(pid)} (#{module})")
            {:ok, pid, module}
          catch
            :exit, reason ->
              log_stuck_process(pid, module, :suspend, reason)
              {:error, pid, module}
          end
        end,
        max_concurrency: 100,
        timeout: suspend_timeout + 1000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> {:error, nil, :task_timeout}
      end)

    successfully_suspended =
      suspended_processes
      |> Enum.filter(fn {status, _, _} -> status == :ok end)

    failed_count = length(suspended_processes) - length(successfully_suspended)

    Logger.info(
      "[#{inspect(__MODULE__)}] Suspended #{length(successfully_suspended)} processes successfully, #{failed_count} failed/skipped"
    )

    # Wrap phases 2-3 in try/after to guarantee processes are resumed even if something fails
    # Leaving processes suspended is catastrophic - their message queues pile up forever
    upgrade_results =
      try do
        # phase 2: Reload ALL changed modules (while all processes are suspended)
        Logger.info("[#{inspect(__MODULE__)}] Phase 2: Reloading all modules...")

        # reload regular changed modules
        # Use load_binary instead of load_file for reliability in embedded mode
        Enum.each(changed_modules, fn module ->
          Logger.info("[#{inspect(__MODULE__)}] Reloading module: #{module}")
          :code.purge(module)

          # Get the beam path and load via binary for embedded mode compatibility
          case :code.which(module) do
            path when is_list(path) ->
              beam_path = List.to_string(path)
              beam_binary = File.read!(beam_path)
              {:module, ^module} = :code.load_binary(module, path, beam_binary)

            _ ->
              # Fallback to load_file if path unknown (shouldn't happen for changed modules)
              {:module, ^module} = :code.load_file(module)
          end
        end)

        # reload consolidated protocols (they may not show up in :code.modified_modules)
        reload_consolidated_protocols()

        # phase 3: Upgrade all processes (call code_change on each)
        Logger.info("[#{inspect(__MODULE__)}] Phase 3: Upgrading all processes...")

        Enum.map(successfully_suspended, fn {:ok, pid, module} ->
          try do
            :sys.change_code(pid, module, :undefined, [])
            Logger.info("[#{inspect(__MODULE__)}] Upgraded process #{inspect(pid)} (#{module})")
            {:ok, pid, module}
          rescue
            e ->
              Logger.error(
                "[#{inspect(__MODULE__)}] Failed to upgrade process #{inspect(pid)} (#{module}): #{Exception.message(e)}"
              )

              {:error, pid, module}
          end
        end)
      after
        # phase 4: Resume only processes that are actually suspended, IN PARALLEL
        # Use get_status to check - suspended processes can still respond to system messages
        Logger.info(
          "[#{inspect(__MODULE__)}] Phase 4: Checking and resuming suspended processes in parallel..."
        )

        processes
        |> Task.async_stream(
          fn {pid, module} ->
            try do
              case :sys.get_status(pid, 1_000) do
                {:status, ^pid, _, [_, :suspended | _]} ->
                  :sys.resume(pid, 3_000)

                  Logger.info(
                    "[#{inspect(__MODULE__)}] Resumed process #{inspect(pid)} (#{module})"
                  )

                {:status, ^pid, _, _} ->
                  # Not suspended, nothing to do
                  :ok
              end
            catch
              :exit, {:noproc, _} ->
                :ok

              :exit, reason ->
                log_stuck_process(pid, module, :resume, reason)
            end
          end,
          max_concurrency: 100,
          timeout: 8_000,
          on_timeout: :kill_task
        )
        |> Stream.run()
      end

    suspend_end = System.monotonic_time(:millisecond)
    suspend_duration_ms = suspend_end - suspend_start

    Logger.info("[#{inspect(__MODULE__)}] Processes were suspended for #{suspend_duration_ms}ms")

    # phase 5: Trigger LiveView reloads for upgraded LiveView modules (if any)
    trigger_liveview_reloads(changed_modules)

    # calculate stats
    succeeded = Enum.count(upgrade_results, fn {status, _, _} -> status == :ok end)
    failed = Enum.count(upgrade_results, fn {status, _, _} -> status == :error end)

    # extract module names (without "Elixir." prefix for cleaner output)
    module_names = Enum.map(changed_modules, fn mod -> inspect(mod) end)

    # extract process module names (without "Elixir." prefix)
    process_names =
      upgrade_results
      |> Enum.filter(fn {status, _, _} -> status == :ok end)
      |> Enum.map(fn {:ok, _pid, module} -> inspect(module) end)
      |> Enum.uniq()

    stats = %{
      modules_reloaded: length(changed_modules),
      module_names: module_names,
      processes_succeeded: succeeded,
      process_names: process_names,
      processes_failed: failed,
      processes_skipped: length(suspended_processes) - length(successfully_suspended),
      suspend_duration_ms: suspend_duration_ms
    }

    Logger.info("[#{inspect(__MODULE__)}] Upgrade complete: #{inspect(stats)}")
    stats
  end

  defp find_processes_to_upgrade(changed_modules) do
    Process.list()
    |> Enum.map(fn pid ->
      case Process.info(pid, [:dictionary, :initial_call]) do
        [dictionary: dict, initial_call: _] ->
          # check if process has a $initial_call set by proc_lib
          case Keyword.get(dict, :"$initial_call") do
            {module, _func, _arity} ->
              if module in changed_modules do
                {pid, module}
              else
                nil
              end

            _ ->
              nil
          end

        _ ->
          nil
      end
    end)
    |> Enum.filter(& &1)
  end

  defp trigger_liveview_reloads(changed_modules) do
    # filter to only LiveView modules
    case Enum.filter(changed_modules, &liveview_module?/1) do
      [_ | _] = liveview_modules ->
        Logger.info("[#{inspect(__MODULE__)}] Phase 5: Triggering LiveView reloads...")

        Logger.info(
          "[#{inspect(__MODULE__)}] Found #{length(liveview_modules)} LiveView modules to reload"
        )

        # find all LiveView process PIDs
        liveview_pids = find_liveview_processes()

        # for each upgraded LiveView module, send reload message to all LiveView processes
        Enum.each(liveview_modules, fn module ->
          # Get the actual source file path from the module's compile info
          source_path = get_source_path(module)

          Enum.each(liveview_pids, fn pid ->
            send(pid, {:phoenix_live_reload, "fly_deploy", source_path})
          end)

          Logger.info(
            "[#{inspect(__MODULE__)}] Sent LiveView reload for #{module} to #{length(liveview_pids)} LiveView processes (#{source_path})"
          )
        end)

      [] ->
        :noop
    end
  end

  defp find_liveview_processes do
    # find all processes running Phoenix.LiveView
    # LiveView processes have a $process_label key in their dictionary
    # with format: {Phoenix.LiveView, ModuleName, "lv:phx-..."}
    Enum.filter(Process.list(), fn pid ->
      case Process.info(pid, [:dictionary]) do
        [dictionary: dict] ->
          match?({Phoenix.LiveView, _, _}, Keyword.get(dict, :"$process_label"))

        _ ->
          false
      end
    end)
  end

  # Returns true if the module has loaded NIF functions.
  # NIF modules must NOT be purged/reloaded during hot upgrades because:
  # 1. Purging unloads the NIF shared object
  # 2. Reloading triggers NIF re-initialization via on_load
  # 3. The .so file may not exist at the expected priv_dir path
  #    (especially in blue-green peers loading code from /tmp/)
  # 4. NIF code changes require a cold deploy anyway
  defp has_nif?(module) do
    try do
      case module.module_info(:nifs) do
        [] -> false
        [_ | _] -> true
      end
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  # returns true if the tarball beam file differs from the currently loaded code
  defp beam_file_changed?(tarball_beam_path, module_name) do
    case :beam_lib.md5(String.to_charlist(tarball_beam_path)) do
      {:ok, {_mod, tarball_md5}} ->
        case :code.get_object_code(module_name) do
          {^module_name, binary, _filename} ->
            case :beam_lib.md5(binary) do
              {:ok, {^module_name, loaded_md5}} -> tarball_md5 != loaded_md5
              _ -> true
            end

          _ ->
            true
        end

      _ ->
        true
    end
  end

  defp get_source_path(module) do
    case Keyword.get(module.module_info(:compile), :source) do
      path when is_list(path) -> List.to_string(path)
      path when is_binary(path) -> path
      _ -> inspect(module)
    end
  end

  defp liveview_module?(module) do
    try do
      behaviours = Keyword.get(module.module_info(:attributes), :behaviour, [])
      Phoenix.LiveView in behaviours or Phoenix.LiveComponent in behaviours
    rescue
      _ -> false
    end
  end

  defp reload_consolidated_protocols do
    # find all consolidated protocol beams in the release
    releases_dir = Path.join(to_string(:code.root_dir()), "releases")

    case Path.wildcard(Path.join([releases_dir, "*", "consolidated", "*.beam"])) do
      [] ->
        Logger.info("[#{inspect(__MODULE__)}] No consolidated protocols found")

      [_ | _] = consolidated_beams ->
        Logger.info(
          "[#{inspect(__MODULE__)}] Reloading #{length(consolidated_beams)} consolidated protocols"
        )

        Enum.each(consolidated_beams, fn beam_path ->
          # extract module name from beam filename
          module_name =
            beam_path
            |> Path.basename(".beam")
            |> String.to_atom()

          # purge and reload the consolidated protocol using load_binary for embedded mode
          Logger.info("[#{inspect(__MODULE__)}] Reloading consolidated protocol: #{module_name}")

          :code.purge(module_name)
          beam_binary = File.read!(beam_path)
          :code.load_binary(module_name, String.to_charlist(beam_path), beam_binary)
        end)
    end
  end

  defp copy_static_assets(upgrade_dir, app) do
    # Find static files in the extracted tarball
    # Path format: <upgrade_dir>/lib/<app>-<version>/priv/static/**/*
    static_files =
      Path.wildcard(Path.join([upgrade_dir, "lib", "#{app}-*", "priv", "static", "**", "*"]))
      |> Enum.filter(&File.regular?/1)

    # Use Application.app_dir to find the correct priv/static location.
    # In a blue-green peer, code is loaded from /tmp/fly_deploy_bg_<ts>/lib/
    # not /app/lib/, so we can't hardcode /app/.
    app_dir = Application.app_dir(app) |> to_string()

    # Extract the tarball's app-version dir name to strip from relative paths
    # e.g., "sprites-0.1.12" from lib/sprites-0.1.12/priv/static/...
    tarball_app_dirs =
      Path.wildcard(Path.join([upgrade_dir, "lib", "#{app}-*"]))
      |> Enum.filter(&File.dir?/1)

    tarball_app_prefix =
      case tarball_app_dirs do
        [dir | _] -> dir <> "/"
        [] -> nil
      end

    if tarball_app_prefix do
      Enum.reduce(static_files, 0, fn src_path, acc ->
        # Extract path relative to the app dir in the tarball
        # e.g., "priv/static/assets/app.css"
        rel_path = String.replace_prefix(src_path, tarball_app_prefix, "")

        # Target path under the running app's directory
        dest_path = Path.join(app_dir, rel_path)

        File.mkdir_p!(Path.dirname(dest_path))
        File.cp!(src_path, dest_path)
        acc + 1
      end)
    else
      0
    end
  end

  defp reset_static_cache(app) do
    # Get the application module (e.g., MyApp.Application)
    case Application.spec(app, :mod) do
      {app_module, _args} ->
        # Call config_change/3 to trigger Phoenix endpoint cache reset
        if function_exported?(app_module, :config_change, 3) do
          Logger.info(
            "[#{inspect(__MODULE__)}] Resetting static cache via #{app_module}.config_change/3"
          )

          app_module.config_change([], [], [])
          IO.puts("  ✓ Static cache reset")
        else
          Logger.info("[#{inspect(__MODULE__)}] No config_change/3 exported by #{app_module}")
        end

      nil ->
        Logger.info("[#{inspect(__MODULE__)}] No application module found for #{app}")
    end
  end

  # Log detailed process info when suspend/resume fails to help debug stuck processes
  defp log_stuck_process(pid, module, operation, reason) do
    process_info =
      case Process.info(pid, [:current_function, :current_stacktrace, :message_queue_len, :status]) do
        nil ->
          "process dead"

        info ->
          current_fn = Keyword.get(info, :current_function)
          stack = Keyword.get(info, :current_stacktrace, [])
          queue_len = Keyword.get(info, :message_queue_len, 0)
          status = Keyword.get(info, :status)

          stack_str =
            stack
            |> Enum.take(5)
            |> Enum.map_join("\n        ", fn {mod, fun, arity, location} ->
              file = Keyword.get(location, :file, ~c"?")
              line = Keyword.get(location, :line, 0)
              "#{mod}.#{fun}/#{arity} (#{file}:#{line})"
            end)

          "status=#{status}, queue_len=#{queue_len}, current_function=#{inspect(current_fn)}\n      stacktrace:\n        #{stack_str}"
      end

    Logger.warning(
      "[#{inspect(__MODULE__)}] Failed to #{operation} #{inspect(pid)} (#{module}): #{inspect(reason)} - #{process_info}"
    )
  end
end
