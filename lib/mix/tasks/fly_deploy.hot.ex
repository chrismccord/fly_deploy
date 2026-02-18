defmodule Mix.Tasks.FlyDeploy.Hot do
  @moduledoc """
  Performs a hot code upgrade without restarting the application.

  ## Quick Start

      # Zero configuration - everything auto-detected from fly.toml
      mix fly_deploy.hot

      # Use staging config
      mix fly_deploy.hot --config fly-staging.toml

      # Pass Docker build arguments
      mix fly_deploy.hot --build-arg ELIXIR_VERSION=1.18.2 --build-arg OTP_VERSION=27.1.2

      # Preview without executing
      mix fly_deploy.hot --dry-run

  ## Configuration

  Configuration is merged from multiple sources with priority:

      CLI options > Mix config > fly.toml > Auto-detected defaults

  ### fly.toml (or --config custom fly toml file)

  The `[env]` section is automatically read and passed to orchestrator machines:

      [env]
        AWS_ENDPOINT_URL_S3 = "https://t3.storage.dev"
        AWS_REGION = "auto"
        AWS_BUCKET = "my-app-staging"

  ### Mix Config

  In `config/config.exs`:

      config :fly_deploy,
        bucket: "my-releases",
        max_concurrency: 10,
        env: %{
          "CUSTOM_VAR" => "value"
        }

  ## CLI Options

    * `--config` - Path to fly.toml file (default: "fly.toml")
    * `--skip-build` - Skip building and use existing image (requires --image)
    * `--image` - Use specific pre-built image
    * `--build-arg` - Pass build-time variables to Docker (can be used multiple times)
    * `--dry-run` - Show what would be done without executing
    * `--force` - Override deployment lock (use with caution)
    * `--lock-timeout` - Lock expiry timeout in seconds (default: 300)
    * `--buildkit` - Use buildkit based Fly builder

  ## Required Setup

    * Fly CLI must be authenticated: `fly auth login`
    * App secrets must include `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for Tigris/S3
    * App secrets must include `FLY_API_TOKEN` (used by orchestrator machine)

  ## How It Works

  1. **Build Phase**: Builds Docker image with `fly deploy --build-only`
  2. **Orchestrator Phase**: Spawns temporary machine with new image
  3. **Tarball Phase**: Orchestrator creates tarball of all .beam files
  4. **Upload Phase**: Uploads tarball to Tigris/S3
  5. **Reload Phase**: Each app machine downloads and extracts tarball
  6. **Upgrade Phase**: Processes are upgraded using :sys.change_code/4

  The orchestrator machine automatically has access to app secrets and
  environment variables from the `[env]` section of your fly.toml.

  ## Safety

  - Processes are suspended before code loading (prevents race conditions)
  - Only proc_lib processes are upgraded (filters out Tasks)
  - Machines can be upgraded concurrently or sequentially
  - Each process upgrade is isolated with error handling
  - Rollback support (coming soon)
  """

  use Mix.Task
  require Logger

  @shortdoc "Hot code upgrade without restarting"

  @max_orchestrator_launch_retries 5

  @impl Mix.Task
  def run(args) do
    {opts, _remaining, _invalid} =
      OptionParser.parse(args,
        strict: [
          config: :string,
          skip_build: :boolean,
          dry_run: :boolean,
          image: :string,
          build_arg: :keep,
          max_concurrency: :integer,
          timeout: :integer,
          force: :boolean,
          lock_timeout: :integer,
          buildkit: :boolean,
        ]
      )

    # Start required applications
    {:ok, _} = Application.ensure_all_started(:req)

    # Build configuration from CLI opts, Mix config, and fly.toml
    config = FlyDeploy.Config.build(opts)

    if opts[:dry_run] do
      Mix.shell().info("🔍 DRY RUN MODE - No changes will be made")
      print_config(config)
    end

    # Get the user identity from fly CLI (will be passed to orchestrator)
    locked_by = get_fly_user()

    perform_hot_deployment(config, opts, locked_by)
  end

  defp print_config(config) do
    Mix.shell().info("")
    Mix.shell().info("Configuration:")
    Mix.shell().info("  OTP App: #{config.otp_app}")
    Mix.shell().info("  Binary: #{config.binary_name}")
    Mix.shell().info("  Bucket: #{config.bucket}")
    Mix.shell().info("  Fly Config: #{config.fly_config}")
    Mix.shell().info("  Version: #{config.version}")

    if map_size(config.env) > 0 do
      Mix.shell().info("  Environment Variables:")

      Enum.each(config.env, fn {key, value} ->
        Mix.shell().info("    #{key} = #{value}")
      end)
    end

    Mix.shell().info("")
  end

  defp get_fly_user do
    case System.cmd("fly", ["auth", "whoami"], stderr_to_stdout: true) do
      {output, 0} ->
        # Output format: "email@example.com\n" or "personal\n"
        String.trim(output)

      _ ->
        # Fallback if fly CLI not authenticated
        System.get_env("USER", "unknown")
    end
  end

  defp perform_hot_deployment(config, opts, locked_by) do
    IO.puts("")

    IO.puts(
      IO.ANSI.format([
        :cyan,
        :bright,
        "==> Starting hot deployment for #{config.otp_app} v#{config.version}"
      ])
    )

    IO.puts("")

    # Phase 1: Build image with fly deploy --build-only
    image_ref =
      if opts[:skip_build] do
        Mix.shell().info(IO.ANSI.format([:yellow, "Skipping build (using provided image)"]))
        opts[:image] || Mix.raise("Must provide --image when using --skip-build")
      else
        build_image(config, opts)
      end

    # Phase 2: Spin up temporary orchestrator machine
    # This machine has access to secrets and can build tarball + upload to Tigris
    if opts[:dry_run] do
      Mix.shell().info("  [DRY RUN] Would spin up orchestrator and execute upgrade")
    else
      execute_orchestrated_upgrade(config, image_ref, opts, locked_by)
    end

    IO.puts("")
    IO.puts(IO.ANSI.format([:green, :bright, "==> Hot deployment complete!"]))
    IO.puts("")
  end

  defp build_image(config, opts) do
    IO.puts(IO.ANSI.format([:yellow, "--> Building Docker image"]))

    # Build args list for fly deploy
    base_args = ["deploy", "--build-only", "--push", "--remote-only", "-c", config.fly_config]

    # Add --build-arg flags if provided
    build_args = Keyword.get_values(opts, :build_arg)
    build_arg_flags = Enum.flat_map(build_args, fn arg -> ["--build-arg", arg] end)

    all_args = base_args ++ build_arg_flags ++ if(opts[:buildkit], do: ["--buildkit"], else: [])

    # Run fly deploy --build-only to create the image
    # Use Port to stream output in real-time while capturing it
    port =
      Port.open(
        {:spawn_executable, System.find_executable("fly")},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: all_args
        ]
      )

    {output, exit_code} = receive_port_output(port, "", nil)

    if exit_code != 0 do
      Mix.raise("fly deploy --build-only failed")
    end

    # Extract image reference from output
    # Looking for: "image: registry.fly.io/my-app:deployment-XXXXX"
    # The output line looks like: "image: registry.fly.io/app:deployment-XXX"
    # We want just the image reference without the @sha256 part
    image_ref =
      case Regex.run(~r/^image: (registry\.fly\.io\/[^\s@]+)/m, output) do
        [_, image] ->
          String.trim(image)

        nil ->
          Mix.raise("Could not extract image reference from fly deploy output")
      end

    deployment_id = extract_deployment_id(image_ref)
    IO.puts(IO.ANSI.format([:green, "    ✓ Built #{deployment_id}"]))

    image_ref
  end

  defp receive_port_output(port, acc, exit_code) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        receive_port_output(port, acc <> data, exit_code)

      {^port, {:exit_status, status}} ->
        # Continue receiving any remaining data after exit
        receive_remaining_output(port, acc, status)
    after
      300_000 ->
        Mix.raise("Build timeout after 5 minutes")
    end
  end

  defp receive_remaining_output(port, acc, exit_code) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        receive_remaining_output(port, acc <> data, exit_code)
    after
      100 ->
        # Port may already be closed, so use try/catch
        try do
          Port.close(port)
        catch
          :error, :badarg -> :ok
        end

        {acc, exit_code}
    end
  end

  defp extract_deployment_id(image_ref) do
    case Regex.run(~r/:deployment-([A-Z0-9]+)/, image_ref) do
      [_, id] -> "deployment-#{id}"
      _ -> "image"
    end
  end

  defp execute_orchestrated_upgrade(config, image_ref, opts, locked_by) do
    IO.puts(IO.ANSI.format([:yellow, "--> Launching orchestrator"]))

    # Build env var flags from config.env (these come from fly.toml [env] and Mix config)
    env_flags =
      Enum.flat_map(config.env, fn {key, value} ->
        ["-e", "#{key}=#{value}"]
      end)

    # Add lock-related env vars
    # Pass config values as environment variables
    config_env_flags =
      [
        ["-e", "DEPLOY_LOCKED_BY=#{locked_by}"],
        ["-e", "DEPLOY_VERSION=#{config.version}"],
        ["-e", "DEPLOY_MAX_CONCURRENCY=#{config.max_concurrency}"],
        ["-e", "DEPLOY_TIMEOUT=#{config.timeout}"],
        ["-e", "DEPLOY_SUSPEND_TIMEOUT=#{config.suspend_timeout}"]
      ] ++
        if opts[:force] do
          [["-e", "DEPLOY_FORCE=true"]]
        else
          []
        end ++
        if opts[:lock_timeout] do
          [["-e", "DEPLOY_LOCK_TIMEOUT=#{opts[:lock_timeout]}"]]
        else
          []
        end

    config_env_flags = List.flatten(config_env_flags)

    # Build eval command with config values
    # Pass the OTP app and image_ref so we can track deployment metadata
    eval_command =
      "/app/bin/#{config.binary_name} eval 'FlyDeploy.orchestrate(app: :#{config.otp_app}, image_ref: \"#{image_ref}\")'"

    # Spawn orchestrator machine with the new image
    # The fly CLI automatically:
    # - Reads app name from fly.toml via -c flag
    # - Passes app secrets (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, etc)
    # - We add [env] vars from fly.toml via -e flags above
    args =
      [
        "machine",
        "run",
        image_ref,
        "--entrypoint",
        "sleep",
        "inf",
        "-c",
        config.fly_config,
        # Give orchestrator enough memory for large tarballs (default is 256MB)
        "--vm-memory",
        "1024"
      ] ++
        env_flags ++
        config_env_flags ++
        [
          "--rm",
          "--shell",
          "--command",
          eval_command
        ]

    # Run with retry logic for registry propagation issues
    run_orchestrator_with_retry(args, @max_orchestrator_launch_retries)
  end

  defp run_orchestrator_with_retry(args, retries_left) do
    {_output, exit_code} =
      System.cmd(
        "fly",
        args,
        into: IO.stream(),
        stderr_to_stdout: true
      )

    cond do
      exit_code == 0 ->
        :ok

      retries_left > 0 ->
        IO.puts(IO.ANSI.format([:yellow, "    ⚠ Orchestrator failed, retrying..."]))

        Process.sleep(3000)
        run_orchestrator_with_retry(args, retries_left - 1)

      true ->
        Mix.raise("Orchestrator machine failed (exit #{exit_code})")
    end
  end
end
