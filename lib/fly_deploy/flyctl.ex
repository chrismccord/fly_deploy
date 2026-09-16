defmodule FlyDeploy.Flyctl do
  @moduledoc false

  @orchestrator_token_command "/bin/false"
  @orchestrator_token_expiry "1h"
  @orchestrator_token_name "fly_deploy orchestrator"
  @token_env_vars ["FLY_API_TOKEN", "FLY_ACCESS_TOKEN"]

  @type command_runner ::
          (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})
  @type env_reader :: (String.t() -> String.t() | nil)

  @spec orchestrator_token(String.t(), command_runner(), env_reader()) ::
          {:ok, String.t()} | {:error, :empty_token | {:exit_status, non_neg_integer()}}
  def orchestrator_token(
        fly_config,
        command_runner \\ &System.cmd/3,
        env_reader \\ &System.get_env/1
      ) do
    args =
      if externally_supplied_token?(env_reader) do
        ["auth", "token", "--quiet"]
      else
        machine_exec_token_args(fly_config)
      end

    case command_runner.("fly", args, []) do
      {output, 0} ->
        case normalize_token(output) do
          "" -> {:error, :empty_token}
          token -> {:ok, token}
        end

      {_output, status} ->
        {:error, {:exit_status, status}}
    end
  end

  defp externally_supplied_token?(env_reader) do
    Enum.any?(@token_env_vars, fn name -> env_reader.(name) not in [nil, ""] end)
  end

  defp machine_exec_token_args(fly_config) do
    [
      "tokens",
      "create",
      "machine-exec",
      "--config",
      fly_config,
      "--expiry",
      @orchestrator_token_expiry,
      # Without a command caveat, machine-exec tokens allow every command. The
      # orchestrator only needs the token's read access to list app machines.
      "--command",
      @orchestrator_token_command,
      "--name",
      @orchestrator_token_name
    ]
  end

  defp normalize_token(output) do
    output
    |> String.trim()
    |> String.replace(~r/^(?:FlyV1|Bearer)\s+/i, "")
  end
end
