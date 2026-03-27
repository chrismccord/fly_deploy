## 0.4.2 (2026-03-27)

### Bug Fixes
- Fix hot deploy triggering stale blue-green upgrade. Both modes shared a single marker file; a hot deploy would overwrite it, causing the blue-green Poller to re-apply a stale upgrade seconds later. Split into mode-specific markers (`fly_deploy_marker_hot.json`, `fly_deploy_marker_blue_green.json`).
- Halt the BEAM on initial peer start failure instead of leaving a zombie machine with no traffic serving.

### Enhancements
Support `--buildkit` flag

## 0.4.1 (2026-03-06)

### Enhancements
- Add `FlyDeploy.subscribe/0` for node-local deploy event notifications. Subscribers receive `{:fly_deploy, event, metadata}` messages for hot upgrade and blue-green lifecycle events.

## 0.4.0 (2026-03-05)

### Enhancements
- Add sentinel-based cutover for blue-green deploys. `before_cutover` now runs during OTP shutdown (after user processes have terminated), allowing processes to write handoff state in `terminate/2` that `before_cutover` can aggregate.
- Add `FlyDeploy.incoming_peer/0` — lets outgoing peer processes discover and communicate with the incoming peer during `terminate/2` for direct state handoff via `:erpc.call/4`.

## 0.3.9 (2026-03-04)

### Bug Fixes
- Fix `eaddrinuse` on blue-green deploys caused by `:badfun` when `inject_reuseport` and `load_release_config` used anonymous functions in `:erpc.call`. Anonymous functions carry module version hashes that don't match when fly_deploy is upgraded between deploys. Converted to named MFA calls.
- Fix `:badarg` failures when hot deploying minor `fly_deploy` version changes caused by anon functions
  cross the :erpc fence. Fixed by using MFA's instead.

### Enhancements
- Add `before_cutover` / `after_cutover` MFA callbacks for blue-green deploys. `before_cutover` runs on the outgoing peer and returns handoff state; `after_cutover` runs on the incoming peer and receives it.

## 0.3.8 (2026-03-03)

### Bug Fixes
- Fix `runtime.exs` `config_env()` returning `:prod` instead of the actual MIX_ENV (e.g., `:staging`) in blue-green peers

## 0.3.7 (2026-03-03)

### Enhancements
- Simplify BlueGreen startup

## 0.3.6 (2026-03-03)

### Enhancements
- Add parent-level children to `FlyDeploy.BlueGreen.start_link/2` for cross-machine mesh formation. Pass children like `DNSCluster` to run on the parent node, which has a consistent basename for DNS discovery. Peers mesh transitively through the parent backbone via `global` auto-connect.

## 0.3.5 (2026-03-02)

### Bug Fixes
- Fix `runtime.exs` config not overriding `prod.exs` values after blue-green deploy. `load_release_config` was using `Keyword.merge` which crashes on plain lists (e.g., `check_origin`) and only does a shallow merge. Now uses a deep merge matching Elixir's `Config.__merge__` semantics.

### Enhancements
- Increase default deploy timeout for blue-green mode from 60s to 10 minutes

## 0.3.4 (2026-03-02)

### Enhancements
- Protection against concurrent bg deploys
- Add `FlyDeploy.blue_green_cluster_status()`
- Fix early timeout errors being display on bluegreen deploys

## 0.3.3 (2026-03-02)

### Bug Fixes
- Fix `SO_REUSEPORT` not being set on peer listeners, causing `eaddrinuse` on blue-green upgrades. The reuseport config was being wiped by `Application.load/1` because it was set without `persistent: true`.

### Enhancements
- Add `FlyDeploy.outgoing_peer/0` to get the outgoing peer node during blue-green upgrades, useful for handoff coordination

## 0.3.2 (2026-02-27)

### Bug Fixes
- Fix failed peer start or peer nodedown failing to bring parent app down

## 0.3.1 (2026-02-27)

### Bug Fixes
- Do not start blue_green parent as hidden node

## 0.3.0 (2026-02-27)

### Enhancements
- **Blue-green deploys via hot `:peer` nodes**: Boot your app in a child BEAM process and swap to a new one on upgrade. See `FlyDeploy.BlueGreen` for setup.
- **`mix fly_deploy.blue_green`**: New mix task for blue-green deploys (equivalent to `mix fly_deploy.hot --mode blue_green`)
- **Hot upgrades inside blue-green peers**: The peer runs its own `FlyDeploy.Poller` with `mode: :hot`, so you can apply hot code upgrades in-place inside a running peer
- **Restart reapply**: On machine restart, both blue-green base and hot overlay are reapplied from S3 automatically
- **`FlyDeploy.list_remote_peers/0`**: List peer nodes visible from the current node, filtering out parent nodes and remsh sessions
- **`FlyDeploy.peer_node/0`**: Get the active peer's node name from the parent (useful for remsh)
- **Configurable `shutdown_timeout`**: Control max time to wait for the outgoing peer to shut down before force-killing. `nil` (default) waits indefinitely.

## 0.2.5 (2026-01-29)
- Log specific process info for processes timing out on suspend/resume

## 0.2.4 (2026-01-27)
- Better logging on failures
- Do not allow processes to be stuck in suspended state
- Suspend and resume in parallel for faster upgrades, which prevents in single
  process or set of processes from failing the upgrade with timeouts

## 0.2.3 (2026-01-27)

### Bug Fixes
- Fix lack of x-tigris-consistent header on tigris leading to race conditions on applying
the latest deploy and reporting pending/failed upgrades

## 0.2.2 (2026-01-16)
- Handle case where code is already loaded from binary (ie copy pasta'd into iex remsh)
- Use t3.storage.dev for more robust connections

## 0.2.1 (2026-01-15)

### Bug Fixes
- Fix upgrade failures leaving machines "stuck in pending" - now writes error result to S3
- Fix failed upgrades not retrying - clear ETag cache on failure to enable automatic retry on next poll

## 0.2.0 (2026-01-13)

### Breaking Changes
- **New supervision tree integration**: Replace `FlyDeploy.startup_reapply_current(:my_app)` with `{FlyDeploy, otp_app: :my_app}` in your supervision tree. Must be placed at the TOP of children list.
- `startup_reapply_current/1` is deprecated

### New Features
- **S3 polling architecture**: Machines now poll S3 for upgrades for more robust hot upgrade signaling
- **`FlyDeploy.current_vsn/0`**: Query the current code version fingerprint at runtime. Returns base image ref, hot upgrade ref, version, and a 12-char fingerprint hash.
- **Continuous polling**: After initial startup, machines continue polling S3 (default: every 1 second) for new upgrades. Configurable via `:poll_interval` option.
- **Machine-written results**: Each machine writes its upgrade result to S3, allowing the orchestrator to track progress without RPC.

### Improvements
- Renamed internal `ReloadScript` module to `Upgrader` for clarity
- Orchestrator now polls S3 for results instead of using `fly machines exec`
- Better timeout handling with explicit timeout errors in orchestrator output

## 0.1.17 (2026-01-09)
- Fix `fly_deploy.status` not parsing `locally_applied` field from RPC response

## 0.1.16 (2026-01-08)
- Add retry handling for failed machine upgrades (3 retries with exponential backoff)
- Add local marker file to accurately detect per-machine upgrade status
- fix `fly_deploy.status` claiming successful upgrade for partially failed machine upgrades

## 0.1.15 (2025-12-19)
- Fix new module code not being loaded on upgrades

## 0.1.14 (2025-12-06)
- Add `:suspend_timeout` configuration and catch timeouts from `:sys.suspend` when process time out suspending

## 0.1.13 (2025-11-26)
- Add `<FlyDeploy.Components.hot_reload_css socket={@socket} asset="app.css" />` when using LiveView
  to render a hidden element that triggers CSS hot reload when static assets change on hot deploy.

## 0.1.12 (2025-11-25)
- Launch orchestrator with more memory beyond 256mb default to avoid OOMs

## 0.1.11 (2025-11-25)
- Ship static assets and recache manifest on upgrade

## 0.1.10 (2025-11-19)
- Add retries for cases where the orchestrator races new image propagation and improve error messaging

## 0.1.9 (2025-11-06)
- Support --build-arg to pass to `fly deploy`

## 0.1.8 (2025-11-06)
- Ensure consolidated protocols are upgraded

## 0.1.7 (2025-11-05)
- Fix `mix fly_deploy.status` failing when more than one machine exists

## 0.1.6 (2025-11-05)
- Add `mix fly_deploy.status`

## 0.1.5 (2025-11-05)
- Fully optimize suspension time when applying hot upgrade

## 0.1.4 (2025-11-04)
- Optimize suspension time by only copying parent OTP app files
that changed and precomputing changes

## 0.1.3 (2025-11-04)
- Instrument and log suspension time

## 0.1.2 (2025-11-04)
- Fix LiveView process lookup, which was failing to send :phoenix_live_reload message, require a hard refresh to pick up upgraded changes to LiveViews

## 0.1.1 (2025-11-04)
- Use BUCKET_NAME as default bucket (automatically set by `fly storage create`)

## 0.1.0 (2025-11-04)
- Initial release
