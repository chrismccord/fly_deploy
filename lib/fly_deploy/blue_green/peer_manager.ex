defmodule FlyDeploy.BlueGreen.PeerManager do
  @moduledoc """
  Manages the lifecycle of peer BEAM nodes for blue-green deploys.

  ## Architecture Overview

  Blue-green mode runs two BEAM layers on a single Fly machine: a **parent**
  node that never serves traffic, and a **peer** node (a child BEAM process
  started via OTP's `:peer` module) that runs the user's full application and
  binds the HTTP port. On upgrade, a *new* peer boots with new code (its
  Endpoint binds via SO_REUSEPORT alongside the old), the old peer's Endpoint
  is stopped, and the old peer is terminated.

  ```
  ┌─ Fly Machine (single VM instance) ──────────────────────────────────────┐
  │                                                                         │
  │  Parent BEAM (long-lived, never serves traffic)                         │
  │  ├─ BlueGreen.Supervisor                                                │
  │  │   ├─ PeerManager          ← this module                             │
  │  │   │   • starts/stops peer BEAM processes via :peer                   │
  │  │   │   • handles cutover (stop old Endpoint)                          │
  │  │   │   • on startup, checks S3 for pending blue-green reapply        │
  │  │   │                                                                  │
  │  │   └─ Poller (mode: :blue_green)                                      │
  │  │       • polls S3 "blue_green_upgrade" field                          │
  │  │       • on change → calls PeerManager.upgrade(tarball_url)           │
  │  │                                                                      │
  │  └─ (no Endpoint, no Repo, no app processes)                            │
  │                                                                         │
  │  Peer BEAM (child process, serves all traffic)                          │
  │  ├─ User's full supervision tree                                        │
  │  │   ├─ FlyDeploy Poller (mode: :hot)    ← polls "hot_upgrade" field   │
  │  │   │   • applies hot code upgrades in-place inside the peer           │
  │  │   │   • on startup, checks S3 for pending hot upgrade reapply        │
  │  │   ├─ Repo, PubSub, Counter, ...                                     │
  │  │   └─ Endpoint                         ← binds port via reuseport    │
  │  │                                                                      │
  │  └─ Code loaded from /tmp/fly_deploy_bg_<ts>/ (not /app/)              │
  │                                                                         │
  └─────────────────────────────────────────────────────────────────────────┘
  ```

  ## How Peers Are Started

  Each peer is a separate OS process started via `:peer.start/1`. The parent:

  1. Finds the bundled `erl` binary from the ERTS directory
  2. Builds exec args: `-boot start_clean` (bypasses the release boot script),
     `-config` (sys.config from the release or extracted tarball),
     `-args_file` (vm.args)
  3. Passes `-pa` flags for all code paths (ebin directories)
  4. Calls `:peer.start(%{name: ..., exec: {erl, args}, ...})`
  5. Boots Elixir + Logger via `:erpc.call`
  6. Marks the peer with `Application.put_env(:fly_deploy, :__role__, :peer)`
  7. Injects SO_REUSEPORT config so the Endpoint can bind alongside an existing peer
  8. Calls `ensure_all_started(otp_app)` (blocking — returns when fully started)

  Why `-boot start_clean`? Without it, `:peer` inherits the parent's release
  boot script which auto-starts all apps before we can mark `__role__: :peer`,
  and computes node names from FLY_IMAGE_REF causing invalid names.

  ## Blue-Green Upgrade Flow

  When the parent's Poller detects a new `"blue_green_upgrade"` in S3:

  ```
  Poller ──→ PeerManager.upgrade(tarball_url)
               │
               ├─ 1. Download tarball from S3
               ├─ 2. Extract to /tmp/fly_deploy_bg_<ts>/
               ├─ 3. Build code paths from extracted ebin dirs
               ├─ 4. Start new peer with new code paths
               │      └─ Peer fully boots (Endpoint binds via reuseport)
               ├─ 5. Stop old peer's Endpoint
               └─ 6. Stop old peer entirely
  ```

  Key properties:
  - **Zero downtime**: Both old and new Endpoints serve simultaneously via
    SO_REUSEPORT during the brief overlap, then old Endpoint stops.
  - **Clean state**: The new peer starts fresh — no `code_change/3`, no state
    migration. This is the key difference from hot upgrades.
  - **New PID**: Every process gets a new PID (new BEAM process).

  ## Hot Upgrades Inside Peers

  The peer runs its own `FlyDeploy.Poller` with `mode: :hot` (started as
  `{FlyDeploy, otp_app: :my_app}` in the user's supervision tree). This
  Poller polls the `"hot_upgrade"` field in S3, completely independent of
  the parent's Poller which watches `"blue_green_upgrade"`.

  When a hot upgrade is detected inside the peer:

  ```
  Peer's Poller ──→ FlyDeploy.hot_upgrade(tarball_url, app)
                      │
                      ├─ Download tarball from S3
                      ├─ Copy .beam files to where :code.which() says
                      │   they're loaded (/tmp/fly_deploy_bg_<ts>/lib/...)
                      ├─ Detect changed modules via :code.modified_modules()
                      ├─ Phase 1: Suspend ALL processes using changed modules
                      ├─ Phase 2: Purge + load ALL new code
                      ├─ Phase 3: :sys.change_code on ALL processes
                      └─ Phase 4: Resume ALL processes
  ```

  This works because the Upgrader uses `:code.which(module)` to find where
  each module is currently loaded from, then copies new beams to that same
  path. Whether the peer loaded code from `/app/lib/` or
  `/tmp/fly_deploy_bg_<ts>/lib/`, the hot upgrade lands in the right place.

  ## S3 State: Separate Fields

  The deployment metadata in S3 (`releases/<app>-current.json`) has two
  independent fields so blue-green and hot upgrades coexist:

  ```json
  {
    "image_ref": "registry.fly.io/app:deployment-ABC",
    "blue_green_upgrade": {
      "tarball_url": "https://s3/.../app-0.2.0.tar.gz",
      "source_image_ref": "registry.fly.io/app:deployment-DEF",
      ...
    },
    "hot_upgrade": {
      "tarball_url": "https://s3/.../app-0.2.1.tar.gz",
      "source_image_ref": "registry.fly.io/app:deployment-GHI",
      ...
    }
  }
  ```

  Rules:
  - `mix fly_deploy.hot` (default mode) → writes `"hot_upgrade"`, preserves
    `"blue_green_upgrade"`
  - `mix fly_deploy.hot --mode blue_green` → writes `"blue_green_upgrade"`,
    clears `"hot_upgrade"` (new peer = fresh start, old hot patches subsumed)
  - `fly deploy` (cold deploy) → machines detect image_ref mismatch and
    reset both fields to nil

  ## Restart Reapply Flow

  When a Fly machine restarts (crash, scaling, `fly machine restart`), both
  layers are reapplied from S3:

  ```
  Machine restarts
    │
    ├─ Parent boots
    │   └─ BlueGreen.Supervisor starts
    │       ├─ PeerManager.init
    │       │   ├─ resolve_startup_code(otp_app)
    │       │   │   └─ Reads S3 "blue_green_upgrade" field
    │       │   │       → Downloads tarball → extracts to /tmp/bg_<ts>/
    │       │   ├─ start_peer(otp_app, new_code_paths)
    │       │   │   └─ Peer boots with /tmp/bg_<ts>/ code (v2)
    │       │   │       ├─ {FlyDeploy, otp_app: :app} starts Poller (mode: :hot)
    │       │   │       │   └─ startup_apply_current reads S3 "hot_upgrade"
    │       │   │       │       → Downloads v2-hot tarball
    │       │   │       │       → Copies beams to /tmp/bg_<ts>/ paths
    │       │   │       │       → Loads via :c.lm() (no suspend at startup)
    │       │   │       │       → Peer now running v2-hot code
    │       │   │       ├─ Counter, Repo, PubSub, ...
    │       │   │       └─ Endpoint (binds port via reuseport)
    │       │
    │       └─ Poller (mode: :blue_green)
    │           └─ Polls for future blue-green upgrades
    │
    └─ Result: machine serves v2-hot traffic (blue-green base + hot overlay)
  ```

  ## Cutover Details

  With SO_REUSEPORT, both old and new Endpoints bind the same port
  simultaneously. The new peer's Endpoint starts during `start_peer`
  (blocking `erpc.call`). Once it's up, we just stop the old Endpoint.
  There is zero gap — both peers serve traffic during the overlap.

  ## Why the Parent Never Serves Traffic

  The parent node's only job is process management:
  - Start/stop peer BEAM processes
  - Poll S3 for blue-green upgrades
  - Coordinate cutover

  It has no Repo, no Endpoint, no business logic processes. This means:
  - Parent crashes don't affect traffic (peer keeps running independently)
  - Parent restarts cleanly without port conflicts
  - Upgrade logic is isolated from application logic

  ## Tarball Types

  PeerManager handles two tarball formats:

  - **Full release** (blue-green mode): Contains `lib/` + `releases/`
    (sys.config, vm.args, boot files, consolidated protocols). The peer uses
    100% new code paths — no mixing with the parent's code.

  - **Beam-only** (hot mode, fallback): Contains just `.beam` files and
    consolidated protocols. Merged with the parent's existing code paths
    (new ebin dirs replace matching app dirs).

  Full release tarballs are detected by the presence of a `releases/`
  directory with a `sys.config` file.
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

  @doc """
  Returns the active peer's node name.

  Useful for remsh-ing into the peer from the parent:

      /app/bin/myapp rpc 'IO.puts(FlyDeploy.BlueGreen.PeerManager.peer_node())'
      RELEASE_NODE=<output> /app/bin/myapp remote
  """
  def peer_node do
    GenServer.call(__MODULE__, :peer_node)
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
    peer_opts = Keyword.put(peer_opts, :endpoint, state.endpoint)
    {peer_pid, peer_node} = start_peer(otp_app, code_paths, peer_opts)

    Logger.info("[BlueGreen.PeerManager] Initial peer started: #{peer_node}")
    {:ok, %{state | active_peer: peer_pid, active_node: peer_node}}
  end

  @impl true
  def handle_call(:peer_node, _from, state) do
    {:reply, state.active_node, state}
  end

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
        case start_new_peer(state.otp_app, new_paths, release_dir, state.endpoint) do
          {:ok, peer_pid, peer_node} ->
            # New peer is fully started with Endpoint bound via reuseport.
            # Gracefully shut down the old peer (drains connections, cleans up).
            graceful_stop_peer(state.active_peer, state.active_node)

            Logger.info("[BlueGreen.PeerManager] Upgrade complete. Active peer: #{peer_node}")
            {:ok, %{state | active_peer: peer_pid, active_node: peer_node}}

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

          # Ensure NIF .so files are present — they may be missing from the tarball
          # if they were symlinks in the Docker image or excluded during build.
          # Falls back to copying from the parent's release at /app/lib/.
          ensure_nif_files(tmp_dir)

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

          ensure_nif_files(tmp_dir)
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

  # Ensures NIF shared object files (.so) are present in the extracted tarball.
  #
  # NIF files can be missing from the tarball for several reasons:
  # - Symlinks in the Docker image that break during tar/extract round-trip
  # - OTP apps whose priv directories weren't included in the tarball
  # - Multi-stage Docker builds where symlink targets don't exist in the runner image
  #
  # For any app directory in the extracted tarball that's missing .so files present
  # in the parent's release at /app/lib/, we copy them over. This handles:
  # - OTP NIFs (crypto, asn1, etc.)
  # - Dependency NIFs (explorer, rustler-based deps, etc.)
  # - User application NIFs
  defp ensure_nif_files(extracted_dir) do
    parent_lib = Path.join(:code.root_dir() |> to_string(), "lib")
    extracted_lib = Path.join(extracted_dir, "lib")

    for app_dir <- Path.wildcard(Path.join(extracted_lib, "*")),
        File.dir?(app_dir) do
      app_basename = Path.basename(app_dir)
      parent_app = Path.join(parent_lib, app_basename)

      if File.dir?(parent_app) do
        # Find all shared object files in the parent's priv tree
        parent_nifs =
          Path.wildcard(Path.join([parent_app, "priv", "**", "*.{so,so.*,dylib}"]))
          |> Enum.filter(&File.regular?/1)

        for nif_file <- parent_nifs do
          rel = Path.relative_to(nif_file, parent_app)
          dest = Path.join(app_dir, rel)

          unless File.exists?(dest) do
            File.mkdir_p!(Path.dirname(dest))
            File.cp!(nif_file, dest)

            Logger.info("[BlueGreen.PeerManager] Copied missing NIF: #{app_basename}/#{rel}")
          end
        end
      end
    end
  end

  defp copy_consolidated_protocols(extract_dir) do
    consolidated_files =
      Path.wildcard(Path.join([extract_dir, "releases", "*", "consolidated", "*.beam"]))

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

  defp start_new_peer(otp_app, code_paths, release_dir, endpoint) do
    try do
      opts = if release_dir, do: [release_dir: release_dir], else: []
      opts = if endpoint, do: Keyword.put(opts, :endpoint, endpoint), else: opts
      {peer_pid, peer_node} = start_peer(otp_app, code_paths, opts)
      {:ok, peer_pid, peer_node}
    rescue
      e -> {:error, {:peer_start_failed, Exception.message(e)}}
    end
  end

  # -- Peer lifecycle --------------------------------------------------------

  defp start_peer(otp_app, code_paths, opts) do
    cookie = Node.get_cookie()
    suffix = System.get_env("FLY_MACHINE_ID") || "#{System.unique_integer([:positive])}"
    name = :"#{otp_app}_peer_#{suffix}"

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

    # Load release config manually.
    # With -boot start_clean, the kernel can't process config providers from
    # sys.config because they reference Elixir modules (Config.Provider.Elixir)
    # that aren't loaded yet. This means compile-time config (from config.exs)
    # and runtime config (from runtime.exs) are both missing. Load them now
    # that Elixir is available.
    vsn_dir = release_dir || find_current_release_dir()

    if vsn_dir do
      load_release_config(node, vsn_dir)
    end

    # Mark as peer so FlyDeploy.BlueGreen.start_link detects it
    :erpc.call(node, Application, :put_env, [:fly_deploy, :__role__, :peer])

    # Inject SO_REUSEPORT so both old and new peers can bind the same port
    # simultaneously during cutover, eliminating the brief gap where neither
    # peer is listening.
    endpoint = Keyword.get(opts, :endpoint)

    if endpoint do
      inject_reuseport(node, otp_app, endpoint)
    end

    # Start the user's OTP app — blocks until fully started (including Endpoint).
    # With reuseport, the new Endpoint can bind the port even while an old peer
    # is still serving. No Gate needed.
    try do
      case :erpc.call(node, :application, :ensure_all_started, [otp_app], 120_000) do
        {:ok, _started} ->
          Logger.info("[BlueGreen.PeerManager] Peer #{node} fully started")

        {:error, {failed_app, reason}} ->
          raise "Failed to start #{failed_app}: #{inspect(reason)}"
      end
    rescue
      e ->
        Logger.error("[BlueGreen.PeerManager] Peer #{node} boot failed: #{Exception.message(e)}")

        stop_peer(pid, node)
        reraise e, __STACKTRACE__
    end

    {pid, node}
  end

  defp build_exec_args(release_dir) do
    boot = find_start_clean_boot(release_dir)
    root = :code.root_dir() |> to_string()

    args = [
      ~c"-boot",
      boot,
      # The boot file references $RELEASE_LIB for application paths — expand it
      ~c"-boot_var",
      ~c"RELEASE_LIB",
      String.to_charlist(Path.join(root, "lib"))
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
      # Strip config_providers from sys.config before passing to the peer.
      # With -config, the kernel processes config_providers (OTP 21+), which
      # calls Config.Provider.Elixir and triggers validate_compile_env. This
      # produces errors when runtime.exs overrides compile-time values (e.g.,
      # api_host differs between prod and staging). We handle config loading
      # manually in load_release_config instead.
      peer_config = strip_config_providers(sys_config)
      sys = String.replace_trailing(peer_config, ".config", "") |> String.to_charlist()
      args ++ [~c"-config", sys]
    else
      args
    end
  end

  # Writes a copy of sys.config with config_providers entries removed.
  # This gives the kernel all static app config at boot (logger, kernel, etc.)
  # without triggering Elixir's config provider machinery.
  defp strip_config_providers(sys_config_path) do
    case :file.consult(String.to_charlist(sys_config_path)) do
      {:ok, [configs]} when is_list(configs) ->
        stripped =
          Enum.map(configs, fn
            {app, kvs} when is_atom(app) and is_list(kvs) ->
              {app, Keyword.delete(kvs, :config_providers)}

            other ->
              other
          end)

        tmp_path =
          Path.join(
            System.tmp_dir!(),
            "fly_deploy_peer_#{:erlang.unique_integer([:positive])}.config"
          )

        content = :io_lib.format(~c"~p.~n", [stripped]) |> IO.iodata_to_binary()
        File.write!(tmp_path, content)
        tmp_path

      _ ->
        # Can't parse, use original
        sys_config_path
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

  # Graceful shutdown: tells the peer to run :init.stop(), which triggers the
  # full OTP supervision tree shutdown. Endpoint drains connections, GenServers
  # get terminate/2 called, ETS tables are cleaned up, etc. We monitor the
  # peer process and wait for it to exit (with a timeout fallback).
  @peer_shutdown_timeout 30_000

  defp graceful_stop_peer(peer_pid, peer_node) do
    Logger.info("[BlueGreen.PeerManager] Gracefully stopping peer #{peer_node}")
    ref = Process.monitor(peer_pid)

    try do
      # :init.stop() is async — it starts the shutdown sequence and returns :ok.
      # The BEAM process exits after all applications have stopped.
      :erpc.call(peer_node, :init, :stop, [], 5_000)
    catch
      :exit, _ -> :ok
    end

    # Wait for the peer process to actually exit
    receive do
      {:DOWN, ^ref, :process, ^peer_pid, _reason} ->
        Logger.info("[BlueGreen.PeerManager] Peer #{peer_node} stopped gracefully")
    after
      @peer_shutdown_timeout ->
        Logger.warning(
          "[BlueGreen.PeerManager] Peer #{peer_node} did not stop within #{@peer_shutdown_timeout}ms, forcing"
        )

        try do
          :peer.stop(peer_pid)
        catch
          :exit, _ -> :ok
        end
    end

    Process.demonitor(ref, [:flush])
  end

  defp stop_peer(peer_pid, peer_node) do
    Logger.info("[BlueGreen.PeerManager] Stopping peer #{peer_node}")

    try do
      :peer.stop(peer_pid)
    catch
      :exit, _ -> :ok
    end
  end

  # -- Reuseport injection ---------------------------------------------------

  defp inject_reuseport(node, otp_app, endpoint) do
    :erpc.call(node, fn ->
      config = Application.get_env(otp_app, endpoint, [])
      http_config = Keyword.get(config, :http, [])
      ti_opts = Keyword.get(http_config, :thousand_island_options, [])
      transport_opts = Keyword.get(ti_opts, :transport_options, [])

      transport_opts = Keyword.merge(transport_opts, reuseport: true, reuseaddr: true)
      ti_opts = Keyword.put(ti_opts, :transport_options, transport_opts)
      http_config = Keyword.put(http_config, :thousand_island_options, ti_opts)
      config = Keyword.put(config, :http, http_config)

      Application.put_env(otp_app, endpoint, config)
    end)
  rescue
    e ->
      Logger.warning(
        "[BlueGreen.PeerManager] Failed to inject reuseport: #{Exception.message(e)}"
      )
  end

  # -- Release config loading ------------------------------------------------

  # Loads compile-time and runtime config into the peer's application env.
  #
  # With -boot start_clean, the kernel can't evaluate config providers from
  # sys.config because they reference Elixir modules that aren't loaded during
  # kernel boot. This means Application.get_env returns nil for all app config.
  #
  # We fix this by:
  # 1. Reading sys.config (Erlang term file) and applying static config values
  # 2. Evaluating runtime.exs (if present) and applying runtime config values
  defp load_release_config(node, vsn_dir) do
    :erpc.call(node, fn ->
      # Step 1: Load compile-time config from sys.config
      sys_config_path = Path.join(vsn_dir, "sys.config")

      if File.exists?(sys_config_path) do
        case :file.consult(String.to_charlist(sys_config_path)) do
          {:ok, [configs]} when is_list(configs) ->
            for {app, kvs} <- configs, is_atom(app), is_list(kvs) do
              for {key, val} <- kvs, key != :config_providers do
                Application.put_env(app, key, val, persistent: true)
              end
            end

            Logger.info(
              "[BlueGreen.PeerManager] Loaded compile-time config from #{sys_config_path}"
            )

          other ->
            Logger.warning(
              "[BlueGreen.PeerManager] Could not parse sys.config: #{inspect(other)}"
            )
        end
      end

      # Step 2: Load runtime config from runtime.exs
      # Runtime values are MERGED on top of compile-time values (Keyword.merge),
      # not replaced. This preserves compile-time keys that runtime.exs doesn't
      # re-set (e.g., adapter: Bandit.PhoenixAdapter in the endpoint config).
      runtime_path = Path.join(vsn_dir, "runtime.exs")

      if File.exists?(runtime_path) do
        configs = Config.Reader.read!(runtime_path, env: :prod)

        for {app, kvs} <- configs do
          for {key, val} <- kvs do
            case {Application.fetch_env(app, key), val} do
              {{:ok, existing}, val} when is_list(existing) and is_list(val) ->
                Application.put_env(app, key, Keyword.merge(existing, val), persistent: true)

              _ ->
                Application.put_env(app, key, val, persistent: true)
            end
          end
        end

        Logger.info("[BlueGreen.PeerManager] Loaded runtime config from #{runtime_path}")
      end
    end)
  rescue
    e ->
      Logger.warning(
        "[BlueGreen.PeerManager] Failed to load release config: #{Exception.message(e)}"
      )
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

              Logger.info(
                "[BlueGreen.PeerManager] Startup reapply: using #{length(paths)} code paths"
              )

              {paths, opts}

            {:error, reason} ->
              Logger.warning(
                "[BlueGreen.PeerManager] Startup reapply failed (#{inspect(reason)}), using current code"
              )

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
            case Map.get(body, "blue_green_upgrade") do
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
      Logger.warning(
        "[BlueGreen.PeerManager] Error checking for pending upgrade: #{Exception.message(e)}"
      )

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
