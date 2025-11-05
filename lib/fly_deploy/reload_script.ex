defmodule FlyDeploy.ReloadScript do
  @moduledoc false
  # Downloads and applies upgrades on individual machines

  require Logger

  @doc """
  Normal hot upgrade on a running system.

  Uses suspend/resume for safe process upgrades.
  """
  def hot_upgrade(tarball_url, app) do
    IO.puts("Downloading tarball from #{tarball_url}...")
    {:ok, _} = Application.ensure_all_started(:req)

    # use AWS SigV4 for authenticated download
    tmp_file_path = Path.join(System.tmp_dir!(), "fly_deploy_upgrade.tar.gz")

    response =
      Req.get!(tarball_url,
        into: File.stream!(tmp_file_path, [:write, :binary]),
        raw: true,
        receive_timeout: 60_000,
        connect_options: [timeout: 60_000],
        aws_sigv4: [
          access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
          secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
          service: "s3",
          region: "auto"
        ]
      )

    Logger.info("[FlyDeploy.ReloadScript] Download response: #{response.status}")

    # check downloaded tarball
    download_size = File.stat!(tmp_file_path).size
    IO.puts("  Downloaded: #{download_size} bytes")

    IO.puts("Extracting...")
    File.mkdir_p!("/tmp/upgrade")
    :erl_tar.extract(~c"#{tmp_file_path}", [:compressed, {:cwd, ~c"/tmp/upgrade"}])

    # copy beam files to loaded paths (only if MD5 differs)
    # Only check app-specific beam files to avoid unnecessary MD5 comparisons on dependencies
    IO.puts("Copying beam files to currently loaded paths...")
    all_beam_files = Path.wildcard("/tmp/upgrade/lib/**/ebin/*.beam")

    # Filter to only the OTP app's beam files
    app_version_dir = Path.basename(Application.app_dir(app))

    beam_files =
      Enum.filter(all_beam_files, fn path ->
        String.contains?(path, "/#{app_version_dir}/ebin/")
      end)

    IO.puts(
      "  Found #{length(beam_files)} app beam files to check (#{length(all_beam_files)} total)"
    )

    copied_count =
      Enum.reduce(beam_files, 0, fn tarball_beam_path, acc ->
        beam_filename = Path.basename(tarball_beam_path)
        module_name = beam_filename |> String.replace_suffix(".beam", "") |> String.to_atom()

        case :code.which(module_name) do
          path when is_list(path) ->
            loaded_path = List.to_string(path)

            # Compare MD5s to avoid unnecessary copies
            if beam_file_changed?(tarball_beam_path, module_name) do
              File.cp!(tarball_beam_path, loaded_path)
              acc + 1
            else
              acc
            end

          _ ->
            acc
        end
      end)

    IO.puts(
      "  ✓ Copied #{copied_count} changed beam files (skipped #{length(beam_files) - copied_count} unchanged)"
    )

    IO.puts("Performing safe hot upgrade...")

    # perform the 4-phase upgrade
    result = safe_upgrade_application(app)

    IO.puts("  Modules reloaded: #{result.modules_reloaded}")

    IO.puts(
      "  Processes upgraded: #{result.processes_succeeded} succeeded, #{result.processes_failed} failed, #{result.processes_skipped} skipped"
    )

    IO.puts("✅ Hot reload complete!")
  end

  @doc """
  Replay a hot upgrade on application startup.

  This is called when a machine restarts and needs to reapply a hot upgrade
  that was previously deployed. Unlike hot_upgrade/2, this:
  1. Pre-loads all changed modules AFTER copying beam files
  2. Doesn't need to suspend/resume processes (they don't exist yet)
  """
  def replay_upgrade_startup(tarball_url, app) do
    IO.puts("Replaying hot upgrade from #{tarball_url} on startup...")
    {:ok, _} = Application.ensure_all_started(:req)

    # download tarball
    response =
      Req.get!(tarball_url,
        into: File.stream!("/tmp/upgrade.tar.gz", [:write, :binary]),
        raw: true,
        receive_timeout: 60_000,
        connect_options: [timeout: 60_000],
        aws_sigv4: [
          access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
          secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
          service: "s3",
          region: "auto"
        ]
      )

    Logger.info("[FlyDeploy.ReloadScript] Download response: #{response.status}")
    download_size = File.stat!("/tmp/upgrade.tar.gz").size
    IO.puts("  Downloaded: #{download_size} bytes")

    # extract tarball
    IO.puts("Extracting...")
    File.mkdir_p!("/tmp/upgrade")
    :erl_tar.extract(~c"/tmp/upgrade.tar.gz", [:compressed, {:cwd, ~c"/tmp/upgrade"}])

    # copy beam files to loaded paths (only if MD5 differs)
    # Only check app-specific beam files to avoid unnecessary MD5 comparisons on dependencies
    IO.puts("Copying beam files to currently loaded paths...")
    all_beam_files = Path.wildcard("/tmp/upgrade/lib/**/ebin/*.beam")

    # Filter to only the OTP app's beam files
    app_version_dir = Path.basename(Application.app_dir(app))

    beam_files =
      Enum.filter(all_beam_files, fn path ->
        String.contains?(path, "/#{app_version_dir}/ebin/")
      end)

    IO.puts(
      "  Found #{length(beam_files)} app beam files to check (#{length(all_beam_files)} total)"
    )

    copied_count =
      Enum.reduce(beam_files, 0, fn tarball_beam_path, acc ->
        beam_filename = Path.basename(tarball_beam_path)
        module_name = beam_filename |> String.replace_suffix(".beam", "") |> String.to_atom()

        case :code.which(module_name) do
          path when is_list(path) ->
            loaded_path = List.to_string(path)

            # Compare MD5s to avoid unnecessary copies
            if beam_file_changed?(tarball_beam_path, module_name) do
              File.cp!(tarball_beam_path, loaded_path)
              acc + 1
            else
              acc
            end

          _ ->
            acc
        end
      end)

    IO.puts(
      "  ✓ Copied #{copied_count} changed beam files (skipped #{length(beam_files) - copied_count} unchanged)"
    )

    # use :c.lm() to load modified modules (purges old code and loads new)
    IO.puts("Loading modified modules...")
    modified_modules = :c.lm()

    IO.puts(
      "  ✓ Loaded #{length(modified_modules)} modified modules: #{inspect(modified_modules)}"
    )

    IO.puts("✅ Startup hot upgrade replay complete!")
  end

  # Safely upgrades all application processes with new code.
  #
  # Returns a map with upgrade statistics:
  # - `modules_reloaded` - Number of modules that were reloaded
  # - `processes_succeeded` - Number of processes successfully upgraded
  # - `processes_failed` - Number of processes that failed to upgrade
  # - `processes_skipped` - Number of processes skipped (not GenServer/proc_lib)
  defp safe_upgrade_application(app) do
    Logger.info("[FlyDeploy.ReloadScript] Starting safe upgrade for #{app}")

    # detect changed modules
    changed_modules = :code.modified_modules()
    Logger.info("[FlyDeploy.ReloadScript] Changed modules: #{inspect(changed_modules)}")

    # find all processes that need upgrading BEFORE loading new code
    processes = find_processes_to_upgrade(changed_modules)
    Logger.info("[FlyDeploy.ReloadScript] Found #{length(processes)} processes to upgrade")

    # phase 1: Suspend ALL processes
    suspend_start = System.monotonic_time(:millisecond)
    Logger.info("[FlyDeploy.ReloadScript] Phase 1: Suspending all processes...")

    suspended_processes =
      Enum.map(processes, fn {pid, module} ->
        try do
          :sys.suspend(pid)
          Logger.info("[FlyDeploy.ReloadScript] Suspended process #{inspect(pid)} (#{module})")
          {:ok, pid, module}
        rescue
          e ->
            Logger.error(
              "[FlyDeploy.ReloadScript] Failed to suspend process #{inspect(pid)} (#{module}): #{Exception.message(e)}"
            )

            {:error, pid, module}
        end
      end)

    successfully_suspended =
      suspended_processes
      |> Enum.filter(fn {status, _, _} -> status == :ok end)

    Logger.info(
      "[FlyDeploy.ReloadScript] Suspended #{length(successfully_suspended)} processes successfully"
    )

    # phase 2: Reload ALL changed modules (while all processes are suspended)
    Logger.info("[FlyDeploy.ReloadScript] Phase 2: Reloading all modules...")

    Enum.each(changed_modules, fn module ->
      Logger.info("[FlyDeploy.ReloadScript] Reloading module: #{module}")
      :code.purge(module)
      {:module, ^module} = :code.load_file(module)
    end)

    # phase 3: Upgrade ALL processes (call code_change on each)
    Logger.info("[FlyDeploy.ReloadScript] Phase 3: Upgrading all processes...")

    upgrade_results =
      Enum.map(successfully_suspended, fn {:ok, pid, module} ->
        try do
          :sys.change_code(pid, module, :undefined, [])
          Logger.info("[FlyDeploy.ReloadScript] Upgraded process #{inspect(pid)} (#{module})")
          {:ok, pid, module}
        rescue
          e ->
            Logger.error(
              "[FlyDeploy.ReloadScript] Failed to upgrade process #{inspect(pid)} (#{module}): #{Exception.message(e)}"
            )

            {:error, pid, module}
        end
      end)

    # phase 4: Resume ALL processes (even failed ones, to avoid leaving them suspended)
    Logger.info("[FlyDeploy.ReloadScript] Phase 4: Resuming all processes...")

    Enum.each(successfully_suspended, fn {:ok, pid, module} ->
      try do
        :sys.resume(pid)
        Logger.info("[FlyDeploy.ReloadScript] Resumed process #{inspect(pid)} (#{module})")
      rescue
        e ->
          Logger.error(
            "[FlyDeploy.ReloadScript] Failed to resume process #{inspect(pid)} (#{module}): #{Exception.message(e)}"
          )
      end
    end)

    suspend_end = System.monotonic_time(:millisecond)
    suspend_duration_ms = suspend_end - suspend_start

    Logger.info("[FlyDeploy.ReloadScript] Processes were suspended for #{suspend_duration_ms}ms")

    # phase 5: Trigger LiveView reloads for upgraded LiveView modules (if any)
    trigger_liveview_reloads(changed_modules)

    # calculate stats
    succeeded = Enum.count(upgrade_results, fn {status, _, _} -> status == :ok end)
    failed = Enum.count(upgrade_results, fn {status, _, _} -> status == :error end)

    stats = %{
      modules_reloaded: length(changed_modules),
      processes_succeeded: succeeded,
      processes_failed: failed,
      processes_skipped: length(suspended_processes) - length(successfully_suspended),
      suspend_duration_ms: suspend_duration_ms
    }

    Logger.info("[FlyDeploy.ReloadScript] Upgrade complete: #{inspect(stats)}")
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
    |> Enum.reject(&is_nil/1)
  end

  defp trigger_liveview_reloads(changed_modules) do
    # filter to only LiveView modules
    liveview_modules = Enum.filter(changed_modules, &liveview_module?/1)

    unless Enum.empty?(liveview_modules) do
      Logger.info("[FlyDeploy.ReloadScript] Phase 5: Triggering LiveView reloads...")

      Logger.info(
        "[FlyDeploy.ReloadScript] Found #{length(liveview_modules)} LiveView modules to reload"
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
          "[FlyDeploy.ReloadScript] Sent LiveView reload for #{module} to #{length(liveview_pids)} LiveView processes (#{source_path})"
        )
      end)
    end
  end

  defp find_liveview_processes do
    # find all processes running Phoenix.LiveView
    # LiveView processes have a $process_label key in their dictionary
    # with format: {Phoenix.LiveView, ModuleName, "lv:phx-..."}
    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, [:dictionary]) do
        [dictionary: dict] ->
          match?({Phoenix.LiveView, _, _}, Keyword.get(dict, :"$process_label"))

        _ ->
          false
      end
    end)
  end

  # Returns true if the tarball beam file differs from the currently loaded code
  defp beam_file_changed?(tarball_beam_path, module_name) do
    case :beam_lib.md5(String.to_charlist(tarball_beam_path)) do
      {:ok, {_mod, tarball_md5}} ->
        case :code.get_object_code(module_name) do
          {^module_name, binary, _filename} ->
            case :beam_lib.md5(binary) do
              {:ok, {^module_name, loaded_md5}} ->
                tarball_md5 != loaded_md5

              _ ->
                true
            end

          _ ->
            true
        end

      _ ->
        true
    end
  end

  defp get_source_path(module) do
    case module.module_info(:compile) |> Keyword.get(:source) do
      path when is_list(path) -> List.to_string(path)
      path when is_binary(path) -> path
      _ -> inspect(module)
    end
  end

  defp liveview_module?(module) do
    try do
      behaviours =
        module.module_info(:attributes)
        |> Keyword.get(:behaviour, [])

      Phoenix.LiveView in behaviours or Phoenix.LiveComponent in behaviours
    rescue
      _ -> false
    end
  end
end
