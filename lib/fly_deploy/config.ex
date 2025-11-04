defmodule FlyDeploy.Config do
  @moduledoc false
  _archdoc = """
  Configuration builder for hot code upgrades.

  Merges configuration from multiple sources with the following priority:

      CLI options > Mix config > fly.toml > Smart defaults

  ## Configuration Options

  - `:otp_app` - OTP application name (default: auto-detected from mix.exs)
  - `:binary_name` - Release binary name (default: same as otp_app)
  - `:bucket` - S3/Tigris bucket name (default: app-name or "releases")
  - `:fly_config` - Path to fly.toml (default: "fly.toml")
  - `:env` - Additional environment variables to pass to orchestrator machine
  - `:max_concurrency` - Max concurrent machine upgrades (default: 20)
  - `:timeout` - Timeout for operations in ms (default: 60_000)

  ## Mix Config

  In `config/config.exs`:

      config :fly_deploy,
        otp_app: :my_app,
        bucket: "my-releases",
        env: %{
          "AWS_ENDPOINT_URL_S3" => "https://fly.storage.tigris.dev",
          "AWS_REGION" => "auto"
        }

  ## CLI Usage

      # Use defaults
      mix fly_deploy.hot

      # Override fly config path
      mix fly_deploy.hot --config fly-staging.toml

      # Override specific settings
      mix fly_deploy.hot --bucket my-bucket

  ## fly.toml [env] Section

  Environment variables from the `[env]` section in fly.toml are automatically
  passed to the orchestrator machine:

      [env]
        AWS_ENDPOINT_URL_S3 = "https://fly.storage.tigris.dev"
        AWS_REGION = "auto"
        AWS_BUCKET = "my-app-staging"

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
      bucket: "releases",
      fly_config: "fly.toml",
      env: %{},
      max_concurrency: 20,
      timeout: 60_000,
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

    # use bucket name from fly.toml app name if available
    bucket =
      if fly_config[:app_name] do
        fly_config.app_name
      else
        config.bucket
      end

    config
    |> Map.put(:env, env)
    |> Map.put(:bucket, bucket)
  end

  defp apply_cli_opts(config, cli_opts) do
    Enum.reduce(cli_opts, config, fn
      {:config, _path}, acc ->
        # Already handled above
        acc

      {:bucket, bucket}, acc ->
        Map.put(acc, :bucket, bucket)

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
