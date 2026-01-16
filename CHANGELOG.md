## 0.2.2 (2026-01-16)
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
