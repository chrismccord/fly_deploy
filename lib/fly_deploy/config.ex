defmodule FlyDeploy.Config do
  @moduledoc false
  _archdoc = """
  Configuration builder for hot code upgrades.

  Merges configuration from multiple sources with the following priority:

      CLI options > Mix config > fly.toml > Smart defaults

  ## Configuration Options

  - `:otp_app` - OTP application name (default: auto-detected from mix.exs)
  - `:binary_name` - Release binary name (default: same as otp_app)
  - `:bucket` - S3/Tigris bucket name (looked up from Mix config or BUCKET_NAME env var)
  - `:fly_config` - Path to fly.toml (default: "fly.toml")
  - `:env` - Additional environment variables to pass to orchestrator machine
  - `:max_concurrency` - Max concurrent machine upgrades (default: 20)
  - `:timeout` - Timeout for operations in ms (default: 60_000)

  ## Mix Config

  In `config/config.exs` or `config/runtime.exs`:

      config :fly_deploy,
        bucket: "my-releases",  # Optional - defaults to BUCKET_NAME env var
        aws_access_key_id: System.get_env("CUSTOM_ACCESS_KEY"),  # Optional - defaults to AWS_ACCESS_KEY_ID
        aws_secret_access_key: System.get_env("CUSTOM_SECRET_KEY"),  # Optional - defaults to AWS_SECRET_ACCESS_KEY
        aws_endpoint_url_s3: System.get_env("CUSTOM_ENDPOINT"),  # Optional - defaults to AWS_ENDPOINT_URL_S3
        aws_region: System.get_env("CUSTOM_REGION"),  # Optional - defaults to "auto"
        env: %{
          "AWS_ENDPOINT_URL_S3" => "https://fly.storage.tigris.dev",
          "AWS_REGION" => "auto"
        }

  ## Bucket Configuration

  The S3 bucket is discovered from:
  1. Mix config `:bucket` key (if explicitly set)
  2. `BUCKET_NAME` environment variable (automatically set by `fly storage create`)

  ## CLI Usage

      # Use defaults (bucket from Mix config or BUCKET_NAME env var)
      mix fly_deploy.hot

      # Override fly config path
      mix fly_deploy.hot --config fly-staging.toml

  ## fly.toml [env] Section

  Environment variables from the `[env]` section in fly.toml are automatically
  passed to the orchestrator machine:

      [env]
        AWS_ENDPOINT_URL_S3 = "https://fly.storage.tigris.dev"
        AWS_REGION = "auto"

  Additional env vars can be added via Mix config using the `:env` key.
  """

  defstruct [
    :otp_app,
    :binary_name,
    :bucket,
    :fly_config,
    :env,
    :max_concurrency,
    :timeout,
    :suspend_timeout,
    :version
  ]

  @type t :: %__MODULE__{
          otp_app: atom(),
          binary_name: String.t(),
          bucket: String.t(),
          fly_config: String.t(),
          env: %{String.t() => String.t()},
          max_concurrency: pos_integer(),
          timeout: pos_integer(),
          suspend_timeout: pos_integer(),
          version: String.t()
        }

  @doc """
  Builds configuration from CLI options, Mix config, and fly.toml.

  ## Examples

      iex> FlyDeploy.Config.build([config: "fly-staging.toml"])
      %FlyDeploy.Config{
        otp_app: :my_app,
        fly_config: "fly-staging.toml",
        ...
      }
  """
  def build(cli_opts \\ []) do
    defaults = smart_defaults()
    mix_config = get_mix_config()
    fly_config_path = cli_opts[:config] || mix_config[:fly_config] || "fly.toml"

    fly_config =
      if File.exists?(fly_config_path) do
        FlyDeploy.FlyConfig.parse(fly_config_path)
      else
        %{}
      end

    # merge: defaults < mix config < fly.toml < cli options
    merged =
      defaults
      |> Map.merge(map_from_keyword(mix_config))
      |> merge_fly_config(fly_config)
      |> apply_cli_opts(cli_opts)
      |> Map.put(:fly_config, fly_config_path)

    struct!(__MODULE__, merged)
  end

  @doc """
  Returns the version string for the current application.
  """
  def version(%__MODULE__{otp_app: app}) do
    Application.spec(app, :vsn) |> to_string()
  end

  defp smart_defaults do
    otp_app = get_otp_app()

    %{
      otp_app: otp_app,
      binary_name: Atom.to_string(otp_app),
      # Will be read from BUCKET_NAME env var on Fly machines
      bucket: nil,
      fly_config: "fly.toml",
      env: %{},
      max_concurrency: 20,
      timeout: 60_000,
      suspend_timeout: 10_000,
      version: get_app_version(otp_app)
    }
  end

  defp get_otp_app do
    Mix.Project.config()[:app] || raise "Could not detect OTP app from mix.exs"
  end

  defp get_app_version(app) do
    Mix.Project.config()[:version] || Application.spec(app, :vsn) |> to_string() || "0.0.0"
  end

  defp get_mix_config do
    Application.get_all_env(:fly_deploy)
  end

  defp map_from_keyword(keyword) do
    Enum.into(keyword, %{})
  end

  defp merge_fly_config(config, fly_config) do
    env = Map.merge(config.env || %{}, fly_config[:env] || %{})

    # Don't override bucket from fly.toml - it should stay as OTP app based default
    config
    |> Map.put(:env, env)
  end

  defp apply_cli_opts(config, cli_opts) do
    Enum.reduce(cli_opts, config, fn
      {:config, _path}, acc ->
        # Already handled above
        acc

      {:timeout, timeout}, acc ->
        Map.put(acc, :timeout, timeout)

      {:max_concurrency, n}, acc ->
        Map.put(acc, :max_concurrency, n)

      # Skip flags that aren't config
      {_key, _value}, acc ->
        acc
    end)
  end
end
