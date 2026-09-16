defmodule FlyDeploy.Flyctl do
  @moduledoc false

  @orchestrator_token_command "/bin/false"
  @orchestrator_token_expiry "1h"
  @orchestrator_token_name "fly_deploy orchestrator"

  @type command_runner ::
          (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec machine_exec_token(String.t(), command_runner()) ::
          {:ok, String.t()} | {:error, :empty_token | {:exit_status, non_neg_integer()}}
  def machine_exec_token(fly_config, command_runner \\ &System.cmd/3) do
    args = [
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

  defp normalize_token(output) do
    output
    |> String.trim()
    |> String.replace(~r/^(?:FlyV1|Bearer)\s+/i, "")
  end
end
