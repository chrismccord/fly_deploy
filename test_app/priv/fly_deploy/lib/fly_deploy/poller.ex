defmodule FlyDeploy.Poller do
  @moduledoc """
  Polls S3 for hot upgrades and applies them automatically.

  This GenServer periodically checks S3 for new hot upgrades and applies them
  when detected. It compares the S3 state's `source_image_ref` with the local
  marker file to determine if an upgrade is needed.

  ## Usage

  Add to your application's supervision tree:

      def start(_type, _args) do
        children = [
          {FlyDeploy, otp_app: :my_app},
          # ... rest of your children
        ]

        Supervisor.start_link(children, strategy: :one_for_one)
      end

  ## Options

  - `:otp_app` - The OTP application name (required)
  - `:poll_interval` - How often to poll S3 in ms (default: 1000)
  - `:suspend_timeout` - Timeout for suspending processes during upgrade in ms (default: 10_000)

  ## Important

  Place `{FlyDeploy, otp_app: :my_app}` at the TOP of your children list.
  The poller blocks during `init/1` to apply any pending hot upgrades before
  the rest of the supervision tree starts.

  ## Efficiency

  Uses ETag/If-None-Match headers to minimize bandwidth. When no upgrade is
  available, S3 returns a 304 Not Modified response.

  ## Version Tracking

  The poller maintains a "fingerprint" of the current code version in
  `:persistent_term`. Access it via `FlyDeploy.current_vsn/0`.
  """

  use GenServer
  require Logger

  @default_poll_interval 1_000
  @persistent_term_key {FlyDeploy, :current_vsn}

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current poller state for debugging.
  """
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Returns the current code version fingerprint.

  The fingerprint is a map containing:
  - `:base_image_ref` - The base Docker image (FLY_IMAGE_REF)
  - `:hot_ref` - The hot upgrade source image ref (nil if no hot upgrade)
  - `:version` - The hot upgrade version (nil if no hot upgrade)
  - `:fingerprint` - A short hash combining base + hot refs

  Returns `nil` if not yet initialized.
  """
  def current_vsn do
    :persistent_term.get(@persistent_term_key, nil)
  end

  @doc false
  def set_current_vsn(base_image_ref, hot_ref, version) do
    fingerprint = compute_fingerprint(base_image_ref, hot_ref)

    vsn = %{
      base_image_ref: base_image_ref,
      hot_ref: hot_ref,
      version: version,
      fingerprint: fingerprint
    }

    :persistent_term.put(@persistent_term_key, vsn)
    vsn
  end

  defp compute_fingerprint(base_image_ref, hot_ref) do
    input = "#{base_image_ref}:#{hot_ref || "base"}"
    :crypto.hash(:sha256, input) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  @impl true
  def init(opts) do
    app = Keyword.fetch!(opts, :otp_app)
    interval = Keyword.get(opts, :poll_interval, @default_poll_interval)
    suspend_timeout = Keyword.get(opts, :suspend_timeout, 10_000)

    # BLOCKING: Apply any pending hot upgrade before supervision tree continues
    # This ensures new code is loaded before other processes start
    startup_apply_current(app)

    # Initialize current_vsn from environment and local marker
    init_current_vsn()

    state = %{
      app: app,
      interval: interval,
      suspend_timeout: suspend_timeout,
      etag: nil,
      last_check: nil,
      last_upgrade: nil,
      upgrade_count: 0,
      check_error_logged: false
    }

    Logger.info("[FlyDeploy.Poller] Started with #{interval}ms poll interval for #{app}")
    schedule_poll(interval)

    {:ok, state}
  end

  defp startup_apply_current(app) do
    my_image_ref = System.get_env("FLY_IMAGE_REF")

    if is_nil(my_image_ref) do
      Logger.info("[FlyDeploy] No FLY_IMAGE_REF found (dev environment?), skipping startup apply")
    else
      Logger.info("[FlyDeploy] Machine starting with image: #{my_image_ref}")

      case fetch_current_state(app) do
        {:ok, current} ->
          handle_startup_state(app, my_image_ref, current)

        {:error, :not_found} ->
          Logger.info("[FlyDeploy] First boot, initializing current state")
          initialize_current_state(app, my_image_ref)

        {:error, reason} ->
          Logger.warning("[FlyDeploy] Failed to fetch current state: #{inspect(reason)}")
      end
    end
  rescue
    e ->
      Logger.error(
        "[FlyDeploy] Unexpected error during startup apply: #{Exception.format(:error, e, __STACKTRACE__)}"
      )
  end

  defp handle_startup_state(app, my_image_ref, current) do
    current_image_ref = Map.get(current, "image_ref")

    if current_image_ref == my_image_ref do
      case Map.get(current, "hot_upgrade") do
        nil ->
          Logger.info("[FlyDeploy] No hot upgrade available for this generation")

        upgrade ->
          Logger.info("[FlyDeploy] Applying hot upgrade v#{upgrade["version"]} on startup...")
          # Use replay_upgrade_startup which uses :c.lm() (no suspend needed at startup)
          FlyDeploy.Upgrader.replay_upgrade_startup(upgrade["tarball_url"], app)
          Logger.info("[FlyDeploy] Startup hot upgrade applied successfully")
      end
    else
      Logger.info(
        "[FlyDeploy] New cold deploy detected (was: #{current_image_ref}, now: #{my_image_ref}), resetting state"
      )

      initialize_current_state(app, my_image_ref)
    end
  end

  defp initialize_current_state(app, image_ref) do
    state = %{
      "image_ref" => image_ref,
      "set_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "hot_upgrade" => nil
    }

    write_current_state(app, state)
  end

  defp write_current_state(app, state) do
    bucket = Application.get_env(:fly_deploy, :bucket) || System.get_env("BUCKET_NAME")

    if is_nil(bucket) do
      Logger.warning("[FlyDeploy] No bucket configured, skipping state write")
    else
      url = "#{s3_endpoint()}/#{bucket}/releases/#{app}-current.json"

      case Req.put(url,
             receive_timeout: 10_000,
             connect_options: [timeout: 10_000],
             json: state,
             headers: [{"content-type", "application/json"}],
             aws_sigv4: [
               access_key_id: aws_access_key_id(),
               secret_access_key: aws_secret_access_key(),
               service: "s3",
               region: aws_region()
             ]
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          Logger.debug("[FlyDeploy] Current state written successfully")

        {:ok, %{status: status}} ->
          Logger.warning("[FlyDeploy] Failed to write state (status #{status})")

        {:error, reason} ->
          Logger.warning("[FlyDeploy] Failed to write state: #{inspect(reason)}")
      end
    end
  end

  defp fetch_current_state(app) do
    bucket = Application.get_env(:fly_deploy, :bucket) || System.get_env("BUCKET_NAME")

    if is_nil(bucket) do
      {:error, :no_bucket_configured}
    else
      url = "#{s3_endpoint()}/#{bucket}/releases/#{app}-current.json"

      case Req.get(url,
             receive_timeout: 10_000,
             connect_options: [timeout: 10_000],
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
          {:error, :not_found}

        {:ok, %{status: status}} ->
          {:error, {:gateway, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp init_current_vsn do
    base_image_ref = System.get_env("FLY_IMAGE_REF")
    local_marker = read_local_marker()

    {hot_ref, version} =
      if local_marker do
        {local_marker["source_image_ref"], local_marker["version"]}
      else
        {nil, nil}
      end

    set_current_vsn(base_image_ref, hot_ref, version)
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = check_for_upgrade(state)
    schedule_poll(new_state.interval)
    {:noreply, new_state}
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp check_for_upgrade(state) do
    case fetch_current_state_with_etag(state.app, state.etag) do
      {:not_modified, etag} ->
        %{state | etag: etag, last_check: DateTime.utc_now(), check_error_logged: false}

      {:ok, current, etag} ->
        state = %{state | etag: etag, last_check: DateTime.utc_now(), check_error_logged: false}
        maybe_apply_upgrade(state, current)

      {:error, reason} ->
        # Only log the warning once to avoid spamming logs
        if not state.check_error_logged do
          Logger.warning("[FlyDeploy.Poller] Failed to check for upgrade: #{inspect(reason)}")
        end

        %{state | last_check: DateTime.utc_now(), check_error_logged: true}
    end
  end

  defp maybe_apply_upgrade(state, current) do
    local_marker = read_local_marker()
    my_image_ref = System.get_env("FLY_IMAGE_REF")
    base_image_ref = Map.get(current, "image_ref")

    # Only apply upgrades if we're on the same base image generation
    if my_image_ref != base_image_ref do
      Logger.debug(
        "[FlyDeploy.Poller] Skipping - different image generation (my: #{my_image_ref}, base: #{base_image_ref})"
      )

      state
    else
      case Map.get(current, "hot_upgrade") do
        nil ->
          state

        upgrade ->
          s3_source_ref = upgrade["source_image_ref"]
          local_source_ref = local_marker && local_marker["source_image_ref"]

          if s3_source_ref != local_source_ref do
            Logger.info(
              "[FlyDeploy.Poller] New upgrade detected: #{upgrade["version"]} from #{s3_source_ref}"
            )

            apply_upgrade(state, upgrade)
          else
            state
          end
      end
    end
  end

  defp apply_upgrade(state, upgrade) do
    # Define these first so they're available in rescue block
    start_time = System.monotonic_time(:millisecond)
    source_image_ref = upgrade["source_image_ref"]
    upgrade_id = upgrade_id_from_ref(source_image_ref)

    tarball_url = upgrade["tarball_url"]
    version = upgrade["version"]

    Logger.info("[FlyDeploy.Poller] Applying hot upgrade v#{version}...")

    # Write pending status immediately so orchestrator knows we're working on it
    write_pending_status(state.app, upgrade_id)

    try do
      case FlyDeploy.hot_upgrade(tarball_url, state.app, suspend_timeout: state.suspend_timeout) do
        {:ok, result} ->
          duration = System.monotonic_time(:millisecond) - start_time
          Logger.info("[FlyDeploy.Poller] Hot upgrade v#{version} applied successfully")

          # Update persistent_term with new version
          base_image_ref = System.get_env("FLY_IMAGE_REF")
          set_current_vsn(base_image_ref, source_image_ref, version)

          # Write result to S3 for orchestrator to pick up
          write_upgrade_result(state.app, upgrade_id, result, duration)

          %{
            state
            | last_upgrade: DateTime.utc_now(),
              upgrade_count: state.upgrade_count + 1
          }

        :ok ->
          # Legacy return value (no result map)
          duration = System.monotonic_time(:millisecond) - start_time
          Logger.info("[FlyDeploy.Poller] Hot upgrade v#{version} applied successfully")

          base_image_ref = System.get_env("FLY_IMAGE_REF")
          set_current_vsn(base_image_ref, source_image_ref, version)

          # Write basic result
          write_upgrade_result(state.app, upgrade_id, %{}, duration)

          %{
            state
            | last_upgrade: DateTime.utc_now(),
              upgrade_count: state.upgrade_count + 1
          }

        {:error, reason} ->
          duration = System.monotonic_time(:millisecond) - start_time
          Logger.error("[FlyDeploy.Poller] Hot upgrade failed: #{inspect(reason)}")

          # Write failure result to S3
          write_upgrade_result(state.app, upgrade_id, %{error: inspect(reason)}, duration)

          # Clear etag so next poll will re-fetch and retry the upgrade
          %{state | etag: nil}
      end
    rescue
      e ->
        duration = System.monotonic_time(:millisecond) - start_time
        error_msg = Exception.format(:error, e, __STACKTRACE__)

        Logger.error("[FlyDeploy.Poller] Hot upgrade crashed: #{error_msg}")

        # Write failure result to S3 so orchestrator knows what happened
        write_upgrade_result(state.app, upgrade_id, %{error: error_msg}, duration)

        # Clear etag so next poll will re-fetch and retry the upgrade
        %{state | etag: nil}
    end
  end

  defp upgrade_id_from_ref(source_image_ref) do
    # Extract deployment ID from image ref like "registry.fly.io/app:deployment-01KEW7VFV2K1D4NA9GKZYMFW3R"
    case Regex.run(~r/deployment-([A-Z0-9]+)/, source_image_ref) do
      [_, id] ->
        id

      _ ->
        :crypto.hash(:sha256, source_image_ref)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)
    end
  end

  defp write_pending_status(app, upgrade_id) do
    bucket = Application.get_env(:fly_deploy, :bucket) || System.get_env("BUCKET_NAME")
    machine_id = System.get_env("FLY_MACHINE_ID", "unknown")
    region = System.get_env("FLY_REGION", "unknown")

    if bucket do
      pending_data = %{
        "machine_id" => machine_id,
        "region" => region,
        "status" => "pending",
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      url = "#{s3_endpoint()}/#{bucket}/releases/#{app}-results/#{upgrade_id}/#{machine_id}.json"

      # Must complete before we proceed to avoid out-of-order writes
      case Req.put(url,
             retry: :transient,
             receive_timeout: 5_000,
             connect_options: [timeout: 5_000],
             json: pending_data,
             headers: [{"content-type", "application/json"}],
             aws_sigv4: [
               access_key_id: aws_access_key_id(),
               secret_access_key: aws_secret_access_key(),
               service: "s3",
               region: aws_region()
             ]
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          Logger.debug("[FlyDeploy.Poller] Wrote pending status to S3")

        {:ok, %{status: status}} ->
          Logger.warning("[FlyDeploy.Poller] Failed to write pending status (HTTP #{status})")

        {:error, reason} ->
          Logger.warning("[FlyDeploy.Poller] Failed to write pending status: #{inspect(reason)}")
      end
    end
  end

  defp write_upgrade_result(app, upgrade_id, result, duration_ms) do
    bucket = Application.get_env(:fly_deploy, :bucket) || System.get_env("BUCKET_NAME")
    machine_id = System.get_env("FLY_MACHINE_ID", "unknown")
    region = System.get_env("FLY_REGION", "unknown")

    success = !Map.has_key?(result, :error)

    if bucket do
      result_data = %{
        "machine_id" => machine_id,
        "region" => region,
        "status" => if(success, do: "completed", else: "failed"),
        "success" => success,
        "error" => Map.get(result, :error),
        "modules_reloaded" => Map.get(result, :modules_reloaded, 0),
        "module_names" => Map.get(result, :module_names, []),
        "processes_succeeded" => Map.get(result, :processes_succeeded, 0),
        "process_names" => Map.get(result, :process_names, []),
        "processes_failed" => Map.get(result, :processes_failed, 0),
        "suspend_duration_ms" => Map.get(result, :suspend_duration_ms),
        "total_duration_ms" => duration_ms,
        "applied_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      url = "#{s3_endpoint()}/#{bucket}/releases/#{app}-results/#{upgrade_id}/#{machine_id}.json"

      case Req.put(url,
             retry: :transient,
             receive_timeout: 10_000,
             connect_options: [timeout: 10_000],
             json: result_data,
             headers: [{"content-type", "application/json"}],
             aws_sigv4: [
               access_key_id: aws_access_key_id(),
               secret_access_key: aws_secret_access_key(),
               service: "s3",
               region: aws_region()
             ]
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          Logger.debug("[FlyDeploy.Poller] Wrote upgrade result to S3")

        {:ok, %{status: status}} ->
          Logger.warning("[FlyDeploy.Poller] Failed to write result to S3 (HTTP #{status})")

        {:error, reason} ->
          Logger.warning("[FlyDeploy.Poller] Failed to write result to S3: #{inspect(reason)}")
      end
    end
  end

  defp fetch_current_state_with_etag(app, etag) do
    bucket = Application.get_env(:fly_deploy, :bucket) || System.get_env("BUCKET_NAME")

    if is_nil(bucket) do
      {:error, :no_bucket_configured}
    else
      url = "#{s3_endpoint()}/#{bucket}/releases/#{app}-current.json"

      headers =
        if etag do
          [{"if-none-match", etag}]
        else
          []
        end

      case Req.get(url,
             receive_timeout: 10_000,
             connect_options: [timeout: 10_000],
             headers: headers,
             aws_sigv4: [
               access_key_id: aws_access_key_id(),
               secret_access_key: aws_secret_access_key(),
               service: "s3",
               region: aws_region()
             ]
           ) do
        {:ok, %{status: 304}} ->
          {:not_modified, etag}

        {:ok, %{status: 200, body: body, headers: resp_headers}} when is_map(body) ->
          new_etag = get_etag(resp_headers)
          {:ok, body, new_etag}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: status}} ->
          {:error, {:gateway, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get_etag(headers) do
    Enum.find_value(headers, fn
      {"etag", value} -> value
      _ -> nil
    end)
  end

  defp read_local_marker do
    marker_path = "/app/fly_deploy_marker.json"

    case File.read(marker_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, marker} -> marker
          {:error, _} -> nil
        end

      {:error, _} ->
        nil
    end
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
end
