defmodule FlyDeploy do
  @moduledoc """
  Hot code upgrades in Elixir/OTP applications on [Fly.io](https://fly.io).

  This module provides the main entry points for performing hot code upgrades
  without requiring application restarts. It coordinates the entire upgrade process
  including building tarballs, distributing code, and safely upgrading running processes.

  ## Limitations vs OTP Releases

  FlyDeploy provides a simplified hot upgrade mechanism compared to OTP's `release_handler`.
  It is optimized for containerized deployments where most changes are code updates and the
  occasional need for cold deploy is an acceptable tradeoff.

  ### Not Supported

  - **Supervision tree changes** - Cannot add/remove supervised children at runtime
  - **Application.config_change/3** - Config changes are not detected, reloaded, or propagated
  - **Multi-step upgrades** - Each upgrade is standalone (no v1→v2→v3 paths)
  - **VM upgrades** - Erlang/OTP version is fixed in Docker image
  - **NIFs/Ports** - Native code requires restart

  For major config changes (supervision tree, network config), use a cold deploy
  with `fly deploy` instead of hot upgrade.

  ## Application Startup

      # Call this in Application.start/2 to automatically apply hot upgrades
      # when machines restart
      FlyDeploy.startup_reapply_current(:my_app)

  ## Orchestrating Upgrades

      # Called by mix fly_deploy.hot to coordinate upgrades across all machines
      FlyDeploy.orchestrate(app: :my_app, image_ref: "registry.fly.io/...")

  ## Individual Machine Upgrades

      # Called via RPC from orchestrator to upgrade a running machine
      FlyDeploy.hot_upgrade("https://s3.../tarball.tar.gz", :my_app)

  ## Configuration

  ### Required Environment Variables

  For Application Machines:
  - `AWS_ACCESS_KEY_ID` - Tigris/S3 access key (for downloading tarballs and metadata)
  - `AWS_SECRET_ACCESS_KEY` - Tigris/S3 secret key
  - `FLY_IMAGE_REF` - Docker image reference (auto-set by Fly, used for version tracking)

  For Orchestrator Machine:
  - `AWS_ACCESS_KEY_ID` - Tigris/S3 access key (for uploading tarballs and metadata)
  - `AWS_SECRET_ACCESS_KEY` - Tigris/S3 secret key
  - `FLY_API_TOKEN` - Fly API token (for listing machines and triggering RPC)
  - `FLY_APP_NAME` - Application name (auto-set by Fly)

  Optional:
  - `AWS_ENDPOINT_URL_S3` - S3 endpoint (defaults to `https://fly.storage.tigris.dev`)
  - `AWS_REGION` - AWS region (defaults to `auto` for Tigris)

  ### Setting Up Secrets

      # Required for all machines (set automatically if you run `fly storage create`)
      fly secrets set AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret>

      # Required for orchestrator (usually auto-available)
      fly secrets set FLY_API_TOKEN=$(fly tokens create machine-exec)

  ### Custom AWS Credentials

  If you need to use non-standard environment variable names or read credentials
  from a different source, you can configure them via Mix config:

      # config/runtime.exs
      config :fly_deploy,
        bucket: "my-bucket",
        aws_access_key_id: System.fetch_env!("CUSTOM_ACCESS_KEY"),
        aws_secret_access_key: System.fetch_env!("CUSTOM_SECRET_KEY"),
        aws_endpoint_url_s3: System.fetch_env!("CUSTOM_ENDPOINT"),
        aws_region: System.fetch_env!("CUSTOM_REGION")

  The standard environment variables (`AWS_ACCESS_KEY_ID`, etc.) are used as
  fallbacks if the Mix config values are not set.

  ## How It Works Internally

  ### S3/Tigris Bucket Structure

  The hot upgrade system stores two types of objects in S3/Tigris:

  `mix release` tarballs - `releases/<app>-<version>.tar.gz`
  - Contains all `.beam` files from `/app/lib/**/ebin/*.beam`
  - Organized with relative paths like `lib/my_app-1.2.3/ebin/Elixir.MyModule.beam`
  - Authenticated downloads using AWS SigV4

  Deployment Metadata - `releases/<app>-current.json`
  - Tracks current deployment state and pending hot upgrades
  - Format:
    ```json
    {
      "image_ref": "registry.fly.io/my-app:deployment-01K93Q...",
      "hot_upgrade": {
        "version": "1.2.3",
        "source_image_ref": "registry.fly.io/my-app:deployment-01K94R...",
        "tarball_url": "https://fly.storage.tigris.dev/bucket/releases/my_app-1.2.3.tar.gz",
        "deployed_at": "2024-01-15T10:30:00Z"
      }
    }
    ```

  Version Tracking:
  - `image_ref` - The base Docker image that machines initialize with (set on first boot)
  - `source_image_ref` - The image the hot upgrade was built from
  - When a new cold deploy happens, machines detect the mismatch and reset state

  ### Hot Upgrade Process (Running System)

  When `hot_upgrade/2` is called on a running machine:

  1. Download Tarball - Fetches tarball from S3 using AWS SigV4 auth
  2. Extract & Copy - Extracts tarball and copies `.beam` files to currently loaded paths
     - Uses `:code.which(module)` to find where each module is loaded from
     - Overwrites old beam files with new versions on disk
  3. Detect Changes - Uses `:code.modified_modules()` to find modules that changed
  4. Suspend Processes - Calls `:sys.suspend(pid)` on all processes using changed modules
  5. Load New Code - Purges old module versions and loads new ones from disk
  6. Migrate State - For each process, calls `:sys.change_code(pid, module, old_vsn, extra)`
     - This triggers the process's `code_change/3` callback
     - Allows state schema migrations
  7. Resume Processes - Calls `:sys.resume(pid)` on all processes

  Total suspension time is typically < 1 second.

  ### Startup Reapply Process (Machine Restart)

  When `startup_reapply_current/1` is called during app boot:

  1. Check Image Ref - Reads `FLY_IMAGE_REF` to identify which image this machine booted from
  2. Fetch Metadata - Downloads `releases/<app>-current.json` from S3
  3. Compare Refs - Compares machine's image ref with metadata's `image_ref`
     - Match - Same generation, check for hot upgrade and apply if present
     - Mismatch - New cold deploy happened, reset state and skip upgrade
  4. Download Tarball - If hot upgrade exists, downloads from `tarball_url`
  5. Copy Beams - Extracts and copies beam files to loaded paths (same as hot upgrade)
  6. Load Modules - Uses `:c.lm()` to detect and load all modified modules
     - No suspend/resume needed (processes haven't started yet)
     - Simply loads new code before supervision tree starts

  This ensures machines that restart after crashes, scaling, or deploys remain consistent
  with the hot-upgraded code running on other machines.

  ## Usage Example

      # In your Application.start/2
      def start(_type, _args) do
        # Check for and apply any pending hot upgrades
        :ok = FlyDeploy.startup_reapply_current(:my_app)

        # Start your supervision tree
        children = [...]
        Supervisor.start_link(children, strategy: :one_for_one)
      end

  """

  require Logger

  @doc """
  Reapplies the current hot upgrade on application startup.

  Detects new cold deploys and resets state automatically.
  This should be called early in `Application.start/2`, after HTTP clients
  are available but before starting the main supervision tree. It checks S3
  for pending hot upgrades matching the current Docker image and reapplies
  them if found.

  Returns:
  - `:ok` - Successfully applied hot upgrade, or no upgrade needed (ie new cold deploy)
  - `{:error, reason}` - Check failed, app continues with current code

  ## Example

      def start(_type, _args) do
        :ok = FlyDeploy.startup_reapply_current(:my_app)
        # ... start supervision tree
      end

  """
  def startup_reapply_current(app) do
    my_image_ref = System.get_env("FLY_IMAGE_REF")

    if is_nil(my_image_ref) do
      Logger.info("[FlyDeploy] No FLY_IMAGE_REF found (dev environment?), skipping")
      :ok
    else
      Logger.info("[FlyDeploy] Machine starting with image: #{my_image_ref}")

      case fetch_current_state(app) do
        {:ok, current} ->
          handle_current_state(app, my_image_ref, current)

        {:error, :not_found} ->
          Logger.info("[FlyDeploy] First boot, initializing current state")
          initialize_current_state(app, my_image_ref)
          :noop

        {:error, reason} ->
          Logger.warning("[FlyDeploy] Failed to fetch current state: #{inspect(reason)}")
          {:error, reason}
      end
    end
  rescue
    e ->
      Logger.error(
        "[FlyDeploy] Unexpected error during startup check: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:error, e}
  end

  @doc """
  Orchestrates a hot upgrade across all machines in the application.

  This is typically called by `mix fly_deploy.hot` on a temporary orchestrator machine.
  It builds a tarball of all `.beam` files, uploads to S3, updates deployment
  metadata, and triggers upgrades on all running machines via RPC.

  ## Options

  - `:app` - The OTP application name (required)
  - `:image_ref` - The Docker image reference for this deployment (required)

  Bucket is discovered from Application config or `BUCKET_NAME` environment variable.

  ## Example

      # Usually called by mix fly_deploy.hot
      FlyDeploy.orchestrate(
        app: :my_app,
        image_ref: "registry.fly.io/my_app:deployment-01K93Q..."
      )

  ## Process

  1. Build tarball from `/app/lib/**/ebin/*.beam`
  2. Upload to S3 at `releases/<app>-<version>.tar.gz`
  3. Update metadata at `releases/<app>-current.json`
  4. Get list of running machines from Fly API
  5. Trigger `hot_upgrade/2` on each machine via RPC
  6. Wait for all machines to complete
  """
  def orchestrate(opts) do
    FlyDeploy.Orchestrator.run(opts)
  end

  @doc """
  Performs a hot upgrade on a running machine.

  Downloads a tarball from S3, extracts and copies beam files to disk,
  then safely upgrades all running processes.

  This is typically invoked via RPC from the orchestrator machine.

  ## Parameters

  - `tarball_url` - S3 URL of the tarball containing new beam files
  - `app` - OTP application name
  - `opts` - Options (optional)
    - `:suspend_timeout` - Timeout in ms for suspending each process (default: 10_000)

  ## Process

  1. Download tarball from S3 (with AWS SigV4 auth)
  2. Extract and copy beam files to loaded paths
  3. Suspend all processes using changed modules
  4. Load new code
  5. Call `code_change/3` on each process
  6. Resume all processes

  ## Safety

  - Processes are suspended during upgrade (typically < 1 second)
  - State is preserved via `code_change/3` callbacks
  - Errors are caught and logged without crashing
  """
  def hot_upgrade(tarball_url, app, opts \\ []) do
    FlyDeploy.ReloadScript.hot_upgrade(tarball_url, app, opts)
  end

  @doc """
  Gets current hot upgrade information for this machine.

  Returns a map with the current deployment state, including whether a hot
  upgrade has been applied and details about the upgrade.

  This is typically called via RPC from `mix fly_deploy.status`.

  ## Parameters

  - `app` - The OTP application name (atom)

  ## Returns

  - `%{hot_upgrade_applied: false}` - No hot upgrade applied (running base image)
  - `%{hot_upgrade_applied: true, version: "...", source_image_ref: "...", deployed_at: "..."}` - Hot upgrade applied

  ## Example

      # Via RPC
      FlyDeploy.get_current_hot_upgrade_info(:my_app)
      #=> %{
      #     hot_upgrade_applied: true,
      #     version: "0.1.1",
      #     source_image_ref: "registry.fly.io/my-app:deployment-01K94R...",
      #     deployed_at: "2024-01-15T10:30:00Z",
      #     current_image_ref: "registry.fly.io/my-app:deployment-01K93Q..."
      #   }
  """
  def get_current_hot_upgrade_info(app) do
    my_image_ref = System.get_env("FLY_IMAGE_REF")

    case fetch_current_state(app) do
      {:ok, current} ->
        # Get the image_ref from S3 state (the base image for this deployment generation)
        base_image_ref = Map.get(current, "image_ref")

        case Map.get(current, "hot_upgrade") do
          nil ->
            %{
              hot_upgrade_applied: false,
              current_image_ref: my_image_ref || "unknown",
              base_image_ref: base_image_ref
            }

          upgrade ->
            %{
              hot_upgrade_applied: true,
              version: upgrade["version"],
              source_image_ref: upgrade["source_image_ref"],
              deployed_at: upgrade["deployed_at"],
              current_image_ref: my_image_ref || "unknown",
              base_image_ref: base_image_ref
            }
        end

      {:error, _reason} ->
        %{
          hot_upgrade_applied: false,
          current_image_ref: my_image_ref || "unknown",
          base_image_ref: nil
        }
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

  defp handle_current_state(app, my_image_ref, current) do
    current_image_ref = Map.get(current, "image_ref")

    if current_image_ref == my_image_ref do
      case Map.get(current, "hot_upgrade") do
        nil ->
          Logger.info("[FlyDeploy] No hot upgrade available for this generation")
          :ok

        upgrade ->
          Logger.info("[FlyDeploy] Applying hot upgrade v#{upgrade["version"]}")
          apply_hot_upgrade(upgrade["tarball_url"], app)
      end
    else
      Logger.info(
        "[FlyDeploy] New cold deploy detected (was: #{current_image_ref}, now: #{my_image_ref}), resetting state"
      )

      initialize_current_state(app, my_image_ref)
      :ok
    end
  end

  defp fetch_current_state(app) do
    # Look up bucket from Application env (set via Mix config) or BUCKET_NAME env var
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

  defp initialize_current_state(app, image_ref) do
    state = %{
      "image_ref" => image_ref,
      "set_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "hot_upgrade" => nil
    }

    write_current_state(app, state)
  end

  defp write_current_state(app, state) do
    # Look up bucket from Application env (set via Mix config) or BUCKET_NAME env var
    bucket = Application.get_env(:fly_deploy, :bucket) || System.get_env("BUCKET_NAME")

    if is_nil(bucket) do
      raise "No bucket configured. Set bucket in Mix config or ensure BUCKET_NAME env var is set via `fly storage create`"
    end

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
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("[FlyDeploy] Failed to write state (status #{status})")
        {:error, {:write_failed, status}}

      {:error, reason} ->
        Logger.warning("[FlyDeploy] Failed to write state: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp apply_hot_upgrade(tarball_url, app) do
    Logger.info("[FlyDeploy] Downloading and applying #{tarball_url}...")

    # Use the startup-specific replay function which uses :c.lm()
    FlyDeploy.ReloadScript.replay_upgrade_startup(tarball_url, app)
    Logger.info("[FlyDeploy] ✅ Hot upgrade applied successfully")
    :ok
  rescue
    e ->
      Logger.error(
        "[FlyDeploy] Failed to apply startup hot upgrade: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:error, e}
  end
end
