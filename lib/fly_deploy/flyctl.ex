defmodule FlyDeploy.Flyctl do
  @moduledoc false

  @type command_runner ::
          (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec machine_regions(String.t(), command_runner()) ::
          {:ok, %{String.t() => String.t()}} | {:error, {:exit_status, non_neg_integer()}}
  def machine_regions(fly_config, command_runner \\ &System.cmd/3) do
    args = ["machine", "list", "--config", fly_config, "--json"]

    case command_runner.("fly", args, []) do
      {output, 0} ->
        {:ok, serving_machine_regions(Jason.decode!(output))}

      {_output, status} ->
        {:error, {:exit_status, status}}
    end
  end

  def serving_machine_regions(machines) when is_list(machines) do
    machines
    |> Enum.filter(&(&1["state"] == "started" && !(&1["config"]["services"] in [nil, []])))
    |> Map.new(&{Map.fetch!(&1, "id"), Map.fetch!(&1, "region")})
  end
end
