defmodule FlyDeploy.FlyConfig do
  @moduledoc """
  Parses fly.toml configuration files.

  Extracts:
  - App name from `app = "name"`
  - Environment variables from `[env]` section
  - Primary region from `primary_region = "xxx"`

  ## Example

      iex> FlyDeploy.FlyConfig.parse("fly.toml")
      %{
        app_name: "my-app",
        env: %{"PORT" => "8080", "MY_VAR" => "value"},
        primary_region: "iad"
      }
  """

  @doc """
  Parses a fly.toml file and extracts configuration.

  Returns a map with:
  - `:app_name` - The Fly.io app name
  - `:env` - Map of environment variables from [env] section
  - `:primary_region` - Primary region if specified

  ## Options

  - `:required_env` - List of env var names that must be present (raises if missing)
  """
  def parse(path, opts \\ []) do
    unless File.exists?(path) do
      raise "Fly config file not found: #{path}"
    end

    content = File.read!(path)

    config = %{
      app_name: extract_app_name(content),
      env: extract_env_vars(content),
      primary_region: extract_primary_region(content)
    }

    # Validate required env vars if specified
    if required_env = opts[:required_env] do
      validate_required_env!(config.env, required_env, path)
    end

    config
  end

  defp extract_app_name(content) do
    case Regex.run(~r/^app\s*=\s*["']([^"']+)["']/m, content) do
      [_, app_name] -> app_name
      nil -> nil
    end
  end

  defp extract_primary_region(content) do
    case Regex.run(~r/^primary_region\s*=\s*["']([^"']+)["']/m, content) do
      [_, region] -> region
      nil -> nil
    end
  end

  defp extract_env_vars(content) do
    # Find the [env] section
    case Regex.run(~r/\[env\](.*?)(?:\[|\z)/sm, content) do
      [_, env_section] ->
        parse_env_section(env_section)

      nil ->
        %{}
    end
  end

  defp parse_env_section(section) do
    # Parse lines like: KEY = "value" or KEY = 'value'
    Regex.scan(~r/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*["']([^"']*)["']/m, section)
    |> Enum.into(%{}, fn [_, key, value] -> {key, value} end)
  end

  defp validate_required_env!(env, required, path) do
    missing = Enum.filter(required, fn key -> !Map.has_key?(env, key) end)

    unless Enum.empty?(missing) do
      raise """
      Missing required environment variables in #{path}:
        #{Enum.join(missing, ", ")}

      Add them to the [env] section:

      [env]
        #{Enum.map_join(missing, "\n  ", fn k -> ~s(#{k} = "value") end)}
      """
    end
  end
end
