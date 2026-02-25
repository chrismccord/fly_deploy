defmodule FlyDeploy.BlueGreen.PeerManager do
  @moduledoc """
  Manages the lifecycle of peer BEAM nodes for blue-green deploys.

  The PeerManager runs on the parent node and is responsible for:
  - Starting the initial peer with the current code
  - On upgrade: starting a new peer with new code, warming it up, cutting over
  - Stopping the old peer after cutover

  ## Peer Startup

  Each peer is a separate BEAM process started via `:peer.start/1`.
  The parent transfers application env, marks the peer with `__role__: :peer`,
  and boots the user's OTP app. The Gate blocks the Endpoint until cutover.

  ## Cutover

  1. New peer warms up (everything before Gate is running)
  2. Old peer's Endpoint is stopped (port freed)
  3. New peer's Gate is opened (Endpoint starts, binds port)
  4. Old peer is stopped
  """

  use GenServer
  require Logger

  defstruct [
    :otp_app,
    :endpoint,
    :active_peer,
    :active_node,
    :upgrading_peer,
    :upgrading_node
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers a blue-green upgrade with new code paths.

  Called by the Poller when it detects a new release in S3.
  Downloads the tarball, extracts it, and starts a new peer with the new code.
  """
  def upgrade(tarball_url) do
    GenServer.call(__MODULE__, {:upgrade, tarball_url}, :infinity)
  end

  @impl true
  def init(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    endpoint = Keyword.get(opts, :endpoint)

    state = %__MODULE__{
      otp_app: otp_app,
      endpoint: endpoint || detect_endpoint(otp_app)
    }

    # Check for a pending upgrade to reapply on startup.
    # If a blue-green upgrade was applied before this restart, the tarball URL
    # is in S3. Download it and boot the initial peer with new code directly,
    # instead of starting with old code and waiting for the Poller to re-upgrade.
    {code_paths, peer_opts} = resolve_startup_code(otp_app)
    {peer_pid, peer_node} = start_peer(otp_app, code_paths, peer_opts)

    # Wait for the Gate to register before opening it.
    # start_peer uses erpc.cast (non-blocking), so the peer's supervision tree
    # is still booting. If we send :open before Gate exists, the message is lost.
    case wait_for_gate(peer_node) do
      :ok ->
        FlyDeploy.BlueGreen.Gate.open(peer_node)
        Logger.info("[BlueGreen.PeerManager] Initial peer started: #{peer_node}")
        {:ok, %{state | active_peer: peer_pid, active_node: peer_node}}

      {:error, reason} ->
        Logger.error("[BlueGreen.PeerManager] Initial peer gate timeout: #{inspect(reason)}")
        {:stop, {:gate_timeout, reason}}
    end
  end

  @impl true
  def handle_call({:upgrade, tarball_url}, _from, state) do
    case do_upgrade(tarball_url, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # -- Upgrade flow ----------------------------------------------------------

  defp do_upgrade(tarball_url, state) do
    Logger.info("[BlueGreen.PeerManager] Starting blue-green upgrade...")

    case download_and_extract(tarball_url, state.otp_app) do
      {:ok, new_paths, release_dir} ->
        case start_new_peer(state.otp_app, new_paths, release_dir) do
          {:ok, peer_pid, peer_node} ->
            case wait_for_gate(peer_node) do
              :ok ->
                :ok = cutover(state, peer_node)

                # Stop old peer
                stop_peer(state.active_peer, state.active_node)

                Logger.info("[BlueGreen.PeerManager] Upgrade complete. Active peer: #{peer_node}")
                {:ok, %{state | active_peer: peer_pid, active_node: peer_node}}

              {:error, reason} ->
                Logger.error("[BlueGreen.PeerManager] Gate timeout: #{inspect(reason)}")
                diagnose_peer(peer_node)
                stop_peer(peer_pid, peer_node)
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("[BlueGreen.PeerManager] Peer start failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("[BlueGreen.PeerManager] Download failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp download_and_extract(tarball_url, otp_app) do
    Logger.info("[BlueGreen.PeerManager] Downloading tarball...")
    {:ok, _} = Application.ensure_all_started(:req)

    timestamp = System.system_time(:second)
    tmp_dir = Path.join(System.tmp_dir!(), "fly_deploy_bg_#{timestamp}")
    tmp_file = Path.join(System.tmp_dir!(), "fly_deploy_bg_#{timestamp}.tar.gz")

    try do
      response =
        Req.get!(tarball_url,
          into: File.stream!(tmp_file, [:write, :binary]),
          raw: true,
          receive_timeout: 120_000,
          connect_options: [timeout: 30_000],
          retry: :transient,
          max_retries: 2,
          headers: [{"x-tigris-consistent", "true"}],
          aws_sigv4: [
            access_key_id: aws_access_key_id(),
            secret_access_key: aws_secret_access_key(),
            service: "s3",
            region: aws_region()
          ]
        )

      if response.status != 200 do
        {:error, {:download_failed, response.status}}
      else
        File.mkdir_p!(tmp_dir)
        :ok = :erl_tar.extract(~c"#{tmp_file}", [:compressed, {:cwd, ~c"#{tmp_dir}"}])

        # Copy marker file
        marker_src = Path.join(tmp_dir, "fly_deploy_marker.json")
        marker_dest = "/app/fly_deploy_marker.json"

        if File.exists?(marker_src) do
          File.cp!(marker_src, marker_dest)
        end

        # Build code paths from extracted tarball
        new_ebin_paths = Path.wildcard(Path.join([tmp_dir, "lib", "*", "ebin"]))

        # Check if this is a full release tarball (blue-green) or just beams (hot)
        # A full release tarball has a releases/ directory
        release_dir = find_extracted_release_dir(tmp_dir)

        if release_dir do
          # Full release tarball — peer uses 100% new code, no base paths needed
          Logger.info(
            "[BlueGreen.PeerManager] Full release extracted: #{length(new_ebin_paths)} ebin dirs, release dir: #{release_dir}"
          )

          # Copy static assets to /app so the running app can serve them
          copy_static_assets(tmp_dir, otp_app)

          {:ok, new_ebin_paths, release_dir}
        else
          # Beam-only tarball (fallback) — merge with current code paths
          new_app_dirs = Enum.map(new_ebin_paths, &Path.dirname/1) |> MapSet.new()

          base_paths =
            current_code_paths()
            |> Enum.reject(fn path ->
              app_dir = Path.dirname(path)
              app_name = app_dir |> Path.basename() |> String.replace(~r/-[\d.]+$/, "")

              Enum.any?(new_app_dirs, fn new_dir ->
                new_name = new_dir |> Path.basename() |> String.replace(~r/-[\d.]+$/, "")
                new_name == app_name
              end)
            end)

          all_paths = base_paths ++ new_ebin_paths

          copy_consolidated_protocols(tmp_dir)
          copy_static_assets(tmp_dir, otp_app)

          Logger.info(
            "[BlueGreen.PeerManager] Extracted #{length(new_ebin_paths)} new ebin dirs, #{length(base_paths)} base paths"
          )

          {:ok, all_paths, nil}
        end
      end
    rescue
      e ->
        {:error, {:extract_failed, Exception.message(e)}}
    after
      File.rm(tmp_file)
    end
  end

  defp find_extracted_release_dir(tmp_dir) do
    case Path.wildcard(Path.join([tmp_dir, "releases", "*", "sys.config"])) do
      [sys_config | _] -> Path.dirname(sys_config)
      [] -> nil
    end
  end

  defp copy_consolidated_protocols(extract_dir) do
    consolidated_files = Path.wildcard(Path.join([extract_dir, "releases", "*", "consolidated", "*.beam"]))

    Enum.each(consolidated_files, fn src_path ->
      [_, version, _, beam_filename] =
        src_path
        |> String.replace_prefix(extract_dir <> "/", "")
        |> Path.split()

      target_path = Path.join(["/app/releases", version, "consolidated", beam_filename])
      File.mkdir_p!(Path.dirname(target_path))
      File.cp!(src_path, target_path)
    end)
  end

  defp copy_static_assets(extract_dir, app) do
    static_files =
      Path.wildcard(Path.join([extract_dir, "lib", "#{app}-*", "priv", "static", "**", "*"]))
      |> Enum.filter(&File.regular?/1)

    Enum.each(static_files, fn src_path ->
      rel_path = String.replace_prefix(src_path, extract_dir <> "/", "")
      dest_path = Path.join("/app", rel_path)
      File.mkdir_p!(Path.dirname(dest_path))
      File.cp!(src_path, dest_path)
    end)
  end

  defp start_new_peer(otp_app, code_paths, release_dir) do
    try do
      opts = if release_dir, do: [release_dir: release_dir], else: []
      {peer_pid, peer_node} = start_peer(otp_app, code_paths, opts)
      {:ok, peer_pid, peer_node}
    rescue
      e -> {:error, {:peer_start_failed, Exception.message(e)}}
    end
  end

  # -- Peer lifecycle --------------------------------------------------------

  defp start_peer(otp_app, code_paths, opts) do
    cookie = Node.get_cookie()
    name = :"#{otp_app}_#{System.unique_integer([:positive])}"

    code_path_args =
      Enum.flat_map(code_paths, fn p -> [~c"-pa", String.to_charlist(p)] end)

    args = [~c"-setcookie", ~c"#{cookie}"] ++ code_path_args

    # Use explicit erl with -boot start_clean to bypass the release boot script.
    # Without exec, :peer inherits the parent's full command line which includes
    # the release boot script. That script auto-starts all apps (before we can
    # mark the peer with __role__) AND computes node names from FLY_IMAGE_REF
    # which produces invalid names with multiple @ signs.
    #
    # We DO pass -config (sys.config) and -args_file (vm.args) so the peer
    # gets the release's full configuration. On upgrade, these come from the
    # NEW release extracted from the tarball — the parent's config is stale.
    erl = find_erl()
    release_dir = Keyword.get(opts, :release_dir)
    exec_args = build_exec_args(release_dir)

    # On Fly, the OS hostname (machine ID) can't be resolved to an IPv6 address.
    # Without explicit host, :peer passes `-name foo` which defaults to the
    # unresolvable hostname, and distribution fails to start.
    peer_opts = %{
      name: name,
      longnames: true,
      exec: {erl, exec_args},
      args: args
    }

    peer_opts =
      case System.get_env("FLY_PRIVATE_IP") do
        nil -> peer_opts
        ip -> Map.put(peer_opts, :host, String.to_charlist(ip))
      end

    {:ok, pid, node} = :peer.start(peer_opts)

    # Boot Elixir runtime
    {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:elixir])
    {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:logger])

    # Mark as peer so Gate and start_link detect it
    :erpc.call(node, Application, :put_env, [:fly_deploy, :__role__, :peer])

    # Start the user's OTP app — this boots the supervision tree.
    # Gate will block before the Endpoint starts.
    # Use cast so we don't block here (Gate blocks in init).
    # Wrap in error-catching code so failures aren't silently lost.
    :erpc.cast(node, fn ->
      try do
        case :application.ensure_all_started(otp_app) do
          {:ok, _started} ->
            :ok

          {:error, {failed_app, reason}} ->
            Logger.warning(
              "[BlueGreen.Peer] Failed to start #{failed_app}: #{inspect(reason)}"
            )
        end
      rescue
        e ->
          Logger.warning(
            "[BlueGreen.Peer] App start crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
          )
      end
    end)

    {pid, node}
  end

  defp build_exec_args(release_dir) do
    boot = find_start_clean_boot(release_dir)
    root = :code.root_dir() |> to_string()

    args = [
      ~c"-boot", boot,
      # The boot file references $RELEASE_LIB for application paths — expand it
      ~c"-boot_var", ~c"RELEASE_LIB", String.to_charlist(Path.join(root, "lib"))
      # Note: -proto_dist inet6_tcp is inherited from ERL_AFLAGS (set by env.sh)
    ]

    # Find the release version directory for sys.config and vm.args
    vsn_dir = release_dir || find_current_release_dir()

    if vsn_dir do
      args
      |> maybe_add_config(vsn_dir)
      |> maybe_add_vm_args(vsn_dir)
    else
      args
    end
  end

  defp maybe_add_config(args, vsn_dir) do
    sys_config = Path.join(vsn_dir, "sys.config")

    if File.exists?(sys_config) do
      # -config expects path without .config extension
      sys = String.replace_trailing(sys_config, ".config", "") |> String.to_charlist()
      args ++ [~c"-config", sys]
    else
      args
    end
  end

  defp maybe_add_vm_args(args, vsn_dir) do
    vm_args = Path.join(vsn_dir, "vm.args")

    if File.exists?(vm_args) do
      args ++ [~c"-args_file", String.to_charlist(vm_args)]
    else
      args
    end
  end

  defp find_current_release_dir do
    root = :code.root_dir() |> to_string()

    case Path.wildcard(Path.join([root, "releases", "*", "sys.config"])) do
      [sys_config | _] -> Path.dirname(sys_config)
      [] -> nil
    end
  end

  defp stop_peer(peer_pid, peer_node) do
    Logger.info("[BlueGreen.PeerManager] Stopping peer #{peer_node}")

    try do
      :peer.stop(peer_pid)
    catch
      :exit, _ -> :ok
    end
  end

  # -- Gate management -------------------------------------------------------

  defp wait_for_gate(node, timeout \\ 30_000) do
    Logger.info("[BlueGreen.PeerManager] Waiting for Gate to register on #{node}...")
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_gate(node, deadline)
  end

  defp do_wait_for_gate(node, deadline) do
    case :erpc.call(node, Process, :whereis, [FlyDeploy.BlueGreen.Gate]) do
      pid when is_pid(pid) ->
        Logger.info("[BlueGreen.PeerManager] Gate registered on #{node}")
        :ok

      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :gate_timeout}
        else
          Process.sleep(100)
          do_wait_for_gate(node, deadline)
        end
    end
  end

  # -- Diagnostics -----------------------------------------------------------

  defp diagnose_peer(node) do
    Logger.warning("[BlueGreen.PeerManager] Diagnosing peer #{node}...")

    try do
      started =
        :erpc.call(node, :application, :which_applications, [], 5_000)
        |> Enum.map(fn {app, _desc, _vsn} -> app end)

      Logger.warning("[BlueGreen.PeerManager] Started apps: #{inspect(started)}")

      loaded =
        :erpc.call(node, :application, :loaded_applications, [], 5_000)
        |> Enum.map(fn {app, _desc, _vsn} -> app end)

      not_started = loaded -- started
      Logger.warning("[BlueGreen.PeerManager] Loaded but NOT started: #{inspect(not_started)}")

      registered = :erpc.call(node, Process, :registered, [], 5_000)
      Logger.warning("[BlueGreen.PeerManager] Registered processes: #{inspect(registered)}")
    catch
      kind, reason ->
        Logger.warning(
          "[BlueGreen.PeerManager] Diagnostics failed: #{inspect(kind)}: #{inspect(reason)}"
        )
    end
  end

  # -- Cutover ---------------------------------------------------------------

  defp cutover(state, new_node) do
    old_node = state.active_node
    endpoint = state.endpoint

    Logger.info("[BlueGreen.PeerManager] Cutover: #{old_node} -> #{new_node}")

    # 1. Stop old peer's Endpoint (frees port 4000)
    if endpoint do
      Logger.info("[BlueGreen.PeerManager] Stopping endpoint #{endpoint} on #{old_node}")

      try do
        :erpc.call(old_node, GenServer, :stop, [endpoint])
      catch
        :exit, _ -> :ok
      end
    end

    # 2. Open new peer's Gate (Endpoint starts, binds port)
    Logger.info("[BlueGreen.PeerManager] Opening gate on #{new_node}")
    FlyDeploy.BlueGreen.Gate.open(new_node)

    :ok
  end

  # -- Startup reapply -------------------------------------------------------

  defp resolve_startup_code(otp_app) do
    my_image_ref = System.get_env("FLY_IMAGE_REF")

    if is_nil(my_image_ref) do
      # Dev/test — no S3, just use current code
      {current_code_paths(), []}
    else
      case fetch_pending_upgrade(otp_app, my_image_ref) do
        {:ok, tarball_url} ->
          Logger.info("[BlueGreen.PeerManager] Found pending upgrade, reapplying on startup...")

          case download_and_extract(tarball_url, otp_app) do
            {:ok, paths, release_dir} ->
              opts = if release_dir, do: [release_dir: release_dir], else: []
              Logger.info("[BlueGreen.PeerManager] Startup reapply: using #{length(paths)} code paths")
              {paths, opts}

            {:error, reason} ->
              Logger.warning("[BlueGreen.PeerManager] Startup reapply failed (#{inspect(reason)}), using current code")
              {current_code_paths(), []}
          end

        :none ->
          Logger.info("[BlueGreen.PeerManager] No pending upgrade, using current code")
          {current_code_paths(), []}
      end
    end
  end

  defp fetch_pending_upgrade(otp_app, my_image_ref) do
    {:ok, _} = Application.ensure_all_started(:req)

    bucket = Application.get_env(:fly_deploy, :bucket) || System.get_env("BUCKET_NAME")

    if is_nil(bucket) do
      :none
    else
      url = "#{s3_endpoint()}/#{bucket}/releases/#{otp_app}-current.json"

      case Req.get(url,
             receive_timeout: 10_000,
             connect_options: [timeout: 10_000],
             headers: [{"x-tigris-consistent", "true"}],
             aws_sigv4: [
               access_key_id: aws_access_key_id(),
               secret_access_key: aws_secret_access_key(),
               service: "s3",
               region: aws_region()
             ]
           ) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          base_image_ref = Map.get(body, "image_ref")

          if base_image_ref == my_image_ref do
            case Map.get(body, "hot_upgrade") do
              %{"tarball_url" => tarball_url} when is_binary(tarball_url) ->
                {:ok, tarball_url}

              _ ->
                :none
            end
          else
            # Different image generation — a cold deploy happened, no reapply needed
            :none
          end

        _ ->
          :none
      end
    end
  rescue
    e ->
      Logger.warning("[BlueGreen.PeerManager] Error checking for pending upgrade: #{Exception.message(e)}")
      :none
  end

  # -- Code paths ------------------------------------------------------------

  defp current_code_paths do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&String.contains?(&1, "/ebin"))
  end

  # -- AWS/S3 helpers --------------------------------------------------------

  defp s3_endpoint do
    Application.get_env(:fly_deploy, :aws_endpoint_url_s3) ||
      System.get_env("AWS_ENDPOINT_URL_S3", "https://t3.storage.dev")
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

  # -- Erlang executable -----------------------------------------------------

  defp find_erl do
    # Always construct from ERTS info — erl is bundled inside the release
    # at erts-<version>/bin/erl and may not be in PATH.
    erts_vsn = :erlang.system_info(:version) |> to_string()
    root = :code.root_dir() |> to_string()
    Path.join([root, "erts-#{erts_vsn}", "bin", "erl"]) |> String.to_charlist()
  end

  defp find_start_clean_boot(nil) do
    # Find from current release
    root = :code.root_dir() |> to_string()

    case Path.wildcard(Path.join([root, "releases", "*", "start_clean.boot"])) do
      [path | _] ->
        path |> String.replace_trailing(".boot", "") |> String.to_charlist()

      [] ->
        # Not in a release — use the default name and let erl find it
        ~c"start_clean"
    end
  end

  defp find_start_clean_boot(release_dir) do
    # Use start_clean from a specific release directory (e.g. extracted tarball)
    path = Path.join(release_dir, "start_clean.boot")

    if File.exists?(path) do
      path |> String.replace_trailing(".boot", "") |> String.to_charlist()
    else
      find_start_clean_boot(nil)
    end
  end

  # -- Endpoint detection ----------------------------------------------------

  defp detect_endpoint(otp_app) do
    # Convention: MyApp -> MyAppWeb.Endpoint
    app_name = otp_app |> Atom.to_string() |> Macro.camelize()
    endpoint_module = Module.concat([:"#{app_name}Web", :Endpoint])

    if Code.ensure_loaded?(endpoint_module) do
      endpoint_module
    else
      Logger.warning(
        "[BlueGreen.PeerManager] Could not detect endpoint for #{otp_app}. " <>
          "Pass endpoint: MyAppWeb.Endpoint in opts."
      )

      nil
    end
  end
end
