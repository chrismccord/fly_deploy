defmodule Mix.Tasks.FlyDeploy.Status do
  @moduledoc """
  Shows deployment status for all machines.

  ## Usage

      mix fly_deploy.status
      mix fly_deploy.status --config fly-staging.toml

  ## What it shows

  For each machine:
  - Machine ID and region
  - Current image deployment ID
  - Hot upgrade status (if any applied)
  - Version comparison

  ## Output Example

      ==> Deployment Status

      Machine: 6e82954f711e87 (iad)
        Image: deployment-01K95HV55T5DX0HMS85SABZPRX
        Hot Upgrade: v0.1.1 (from deployment-01K95ABC123)
        Status: ✓ Up to date

      Machine: 28715e9a4e01d8 (sjc)
        Image: deployment-01K95HV55T5DX0HMS85SABZPRX
        Hot Upgrade: None
        Status: ✓ Running base image

  """

  use Mix.Task
  require Logger

  @shortdoc "Show deployment status for all machines"

  @impl Mix.Task
  def run(args) do
    {opts, _remaining, _invalid} =
      OptionParser.parse(args,
        strict: [
          config: :string
        ]
      )

    # Start required applications
    {:ok, _} = Application.ensure_all_started(:req)

    # Get fly config path
    fly_config = opts[:config] || "fly.toml"

    # Get app name from fly.toml
    app_name = get_app_name(fly_config)

    IO.puts("")
    IO.puts(IO.ANSI.format([:cyan, :bright, "==> Deployment Status for #{app_name}"]))
    IO.puts("")

    # Get all machines
    machines = list_machines(app_name)

    if Enum.empty?(machines) do
      IO.puts(IO.ANSI.format([:yellow, "No machines found"]))
      IO.puts("")
    else

    # Filter to only app machines (not orchestrator machines)
    # Include both started and stopped machines (app machines may have autostop)
    app_machines =
      Enum.filter(machines, fn m ->
        m["state"] in ["started", "stopped"] && m["config"]["services"] != nil &&
          m["config"]["services"] != []
      end)

      if Enum.empty?(app_machines) do
        IO.puts(IO.ANSI.format([:yellow, "No app machines found"]))
        IO.puts("")
      else
        IO.puts("Found #{length(app_machines)} app machines:")
        IO.puts("")

        # Get status for each machine
        Enum.each(app_machines, fn machine ->
          show_machine_status(machine, app_name)
        end)

        IO.puts("")
      end
    end
  end

  defp get_app_name(fly_config) do
    case File.read(fly_config) do
      {:ok, content} ->
        # Parse app name from fly.toml
        case Regex.run(~r/^app\s*=\s*["']([^"']+)["']/m, content) do
          [_, app_name] -> app_name
          nil -> Mix.raise("Could not parse app name from #{fly_config}")
        end

      {:error, reason} ->
        Mix.raise("Could not read #{fly_config}: #{inspect(reason)}")
    end
  end

  defp list_machines(app_name) do
    {output, 0} =
      System.cmd("fly", ["machines", "list", "-a", app_name, "--json"], stderr_to_stdout: true)

    Jason.decode!(output)
  end

  defp show_machine_status(machine, app_name) do
    machine_id = String.slice(machine["id"], 0, 14)
    region = machine["region"]
    state = machine["state"]
    image_ref = machine["config"]["image"]

    # Extract deployment ID from image
    deployment_id =
      case Regex.run(~r/:deployment-([A-Z0-9]+)/, image_ref) do
        [_, id] -> "deployment-#{id}"
        _ -> "unknown"
      end

    state_color = if state == "started", do: :green, else: :yellow

    IO.puts(
      IO.ANSI.format([
        :bright,
        "Machine: #{machine_id} (#{region}) ",
        state_color,
        "[#{state}]"
      ])
    )

    IO.puts("  Image: #{deployment_id}")

    # Only try to get hot upgrade info if machine is started
    # (can't RPC into stopped machines)
    if state == "started" do
      case get_hot_upgrade_info(app_name) do
      {:ok, info} ->
        if info.hot_upgrade_applied do
          IO.puts(
            IO.ANSI.format([
              :green,
              "  Hot Upgrade: v#{info.version} (from #{info.source_deployment_id})"
            ])
          )

          IO.puts("  Applied: #{info.deployed_at}")

          # Check if hot upgrade is stale by comparing machine's current image with S3 state's base image_ref
          # If they match, hot upgrade is still valid. If not, a new cold deploy happened.
          cond do
            is_nil(info.base_image_ref) ->
              IO.puts(
                IO.ANSI.format([
                  :yellow,
                  "  Status: ⚠ Cannot determine if stale (no base image ref in state)"
                ])
              )

            image_ref == info.base_image_ref ->
              IO.puts(IO.ANSI.format([:green, "  Status: ✓ Hot upgrade is current"]))

            true ->
              IO.puts(
                IO.ANSI.format([
                  :red,
                  "  Status: ✗ Hot upgrade is STALE (new cold deploy detected)"
                ])
              )
          end
        else
          IO.puts(IO.ANSI.format([:faint, "  Hot Upgrade: None"]))
          IO.puts(IO.ANSI.format([:green, "  Status: ✓ Running base image"]))
        end

        {:error, reason} ->
          IO.puts(IO.ANSI.format([:red, "  Hot Upgrade: Error - #{reason}"]))
          IO.puts(IO.ANSI.format([:yellow, "  Status: ⚠ Could not check hot upgrade status"]))
      end
    else
      # Machine is stopped, can't check hot upgrade status
      IO.puts(IO.ANSI.format([:faint, "  Hot Upgrade: Unknown (machine stopped)"]))
      IO.puts(IO.ANSI.format([:faint, "  Status: Machine not running"]))
    end

    IO.puts("")
  end

  defp get_hot_upgrade_info(app_name) do
    # Use fly ssh console to RPC into the machine and get hot upgrade status
    # Pass the OTP app name to the RPC call and encode as JSON
    otp_app = get_otp_app_name()
    rpc_command = "result = FlyDeploy.get_current_hot_upgrade_info(:#{otp_app}); IO.puts(JSON.encode!(result))"

    case System.cmd(
           "fly",
           [
             "ssh",
             "console",
             "-a",
             app_name,
             "-s",
             "-C",
             "/app/bin/#{get_binary_name()} rpc \"#{rpc_command}\""
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        # Parse the JSON output
        parse_rpc_output(output)

      {output, _} ->
        {:error, "RPC failed: #{String.trim(output)}"}
    end
  end

  defp get_otp_app_name do
    Mix.Project.config()[:app]
  end

  defp get_binary_name do
    # Get the OTP app name from Mix project config
    # This is the binary name used in /app/bin/<binary>
    get_otp_app_name() |> to_string()
  end

  defp parse_rpc_output(output) do
    # The output is JSON string like:
    # {"hot_upgrade_applied":true,"version":"0.1.0","source_image_ref":"...","deployed_at":"..."}
    # Extract the JSON from the output (ignore connection messages)

    case Regex.run(~r/(\{.*\})/s, output) do
      [_, json_str] ->
        case JSON.decode(json_str) do
          {:ok, data} ->
            # Extract deployment ID from source_image_ref if present
            source_deployment_id =
              case data["source_image_ref"] do
                nil ->
                  nil

                ref ->
                  case Regex.run(~r/deployment-([A-Z0-9]+)/, ref) do
                    [_, id] -> "deployment-#{id}"
                    _ -> "unknown"
                  end
              end

            {:ok,
             %{
               hot_upgrade_applied: data["hot_upgrade_applied"] || false,
               version: data["version"],
               source_deployment_id: source_deployment_id,
               source_image_ref: data["source_image_ref"],
               deployed_at: data["deployed_at"],
               base_image_ref: data["base_image_ref"]
             }}

          {:error, reason} ->
            {:error, "Failed to decode JSON: #{inspect(reason)}"}
        end

      nil ->
        {:error, "No JSON found in output"}
    end
  rescue
    e ->
      {:error, "Failed to parse RPC output: #{Exception.message(e)}"}
  end
end
