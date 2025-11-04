# FlyDeploy

Hot code upgrades for Elixir applications running on [Fly.io](https://fly.io) without restarts or downtime.

`FlyDeploy` enables zero-downtime deployments by upgrading running BEAM processes with new code while preserving their state.
Unlike traditional deployments that restart your entire application, hot upgrades suspend processes, swaps in new code, migrates
state via `code_change` callbacks, then resumes processes for seamless code upgrades.

## Features

- Zero-downtime deployments - upgrade code without restarting your application
- State preservation and migration - running processes maintain their state through upgrades and migrate state
  with standard OTP `code_change/3` callbacks
- Automatic startup reapply - machines that restart after hot upgrades automatically load the new code
- Concurrent upgrades - upgrade all machines in parallel for faster deployments
- Safe process suspension - only affects processes using changed modules
- Phoenix LiveView auto-reload - LiveView pages automatically re-render after upgrade without page refresh
- S3 storage - stores release tarballs for distribution to machines

## Comparison with OTP releases and release handlers

FlyDeploy provides a simplified approach to hot code upgrades compared to traditional OTP releases and the `release_handler` module.
Understanding the differences will help you choose the best tool for your needs.

### Traditional OTP release upgrades

OTP's `release_handler` provides the canonical hot upgrade mechanism for Erlang/Elixir applications:

- Requires `.appup` files for each application defining upgrade instructions
- Requires a `.relup` file describing the complete release upgrade path
- Uses `:release_handler.install_release/1` to perform upgrades
- Manages dependencies and startup order automatically
- Handles complex upgrade scenarios (adding/removing applications, changing supervision trees)
- Persists upgrade state within the release structure itself
- Well-tested over decades in production telecom systems

### FlyDeploy's simplified approach

FlyDeploy takes a different approach optimized for containerized deployments and simplified upgrades,
where we accept that some changes require cold deploys:

- No `.appup` or `.relup` files required - upgrades work automatically
- Detects changed modules using `:code.modified_modules()` after loading new beams
- Upgrades individual processes using `:sys.suspend/1`, `:sys.change_code/4`, and `:sys.resume/1`
- Stores upgrade metadata in external storage (S3/Tigris/etc) rather than in the release
- Builds on Docker images for distribution rather than release tarballs
- Optimized for typical code upgrades where frequent upgrades to supervision tree structures, upgrading deps, or
  careful ordering of the upgrade process is not required

### Key Differences

State Management:
- OTP has complex dependency tracking and upgrade ordering guarantees
- FlyDeploy relies on processes implementing `code_change/3` for state migration, with no strict ordering guarantees
- FlyDeploy detects changes automatically via `:code.modified_modules()`

Metadata Storage:
- OTP stores upgrade history in `releases/RELEASES` file on disk
- FlyDeploy stores metadata in S3 for distribution across ephemeral machines

Build Artifacts:
- OTP requires `.appup` and `.relup` files with detailed upgrade instructions
- FlyDeploy requires no additional build artifacts - just standard compilation on a `mix release` build server

### Limitations

Compared to OTP's release_handler, FlyDeploy **cannot**:

- **Add/remove applications or dependencies** - The supervision tree is built once at startup
- **Change supervision tree structure or process hierarchy** - Cannot add/remove child processes dynamically
- **Trigger `Application.config_change/3` callbacks** - Configuration changes are not detected or propagated
- **Upgrade the Erlang VM or OTP version** - VM version is fixed in the Docker image
- **Handle multi-step upgrade paths with intermediate versions** - Each upgrade is standalone
- **Upgrade NIFs or port drivers** - Native code requires a restart
- **Guarantee specific module load ordering** - All modules load concurrently (not an issue with the 4-phase upgrade approach)

### When to Use Each

Use FlyDeploy when:
- Deploying to containerized environments
- Most of your changes are to the top level OTP application modules and process that you wholly own
- You want simple hot upgrades without `.appup` files

Use OTP release_handler when:
- Adding/removing applications at runtime
- Requiring complex multi-step upgrade paths, with specific module upgrade ordering
- Needing VM upgrades without downtime
- Requiring telecom-grade reliability guarantees

## Installation

Add `fly_deploy` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fly_deploy, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Configure Fly Secrets

Set up AWS credentials for storage:

```bash
fly storage create -a myapp -n my-releases-bucket
```

Or for existing creds:

```bash
fly secrets set AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret>
```

You will also need to set a secret on the app of the Fly API token for the orchestrator machine:

```bash
fly secrets set FLY_API_TOKEN=$(fly tokens create machine-exec)
```

### 2. Add Startup Hook

In your `Application.start/2`, you **must** call `startup_reapply_current/1` **before** starting your supervision tree.
This will reapply any previously applied hot upgrade on top of the running container image, allowing hot deploys
to survive machine restarts.

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    # Apply any hot upgrade that builds on top of our static container image on startup
    FlyDeploy.startup_reapply_current(:my_app)

    children = [
      # your supervision tree
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### 3. Deploy

Run a hot deployment:

```bash
mix fly_deploy.hot
```

That's it. Your application will upgrade to the new code without restarting.

## How It Works

### Hot Upgrade Process

When you run `mix fly_deploy.hot`:

1. Build Phase - Creates a new Docker image with `fly deploy --build-only`
2. Orchestrator Phase - Spawns a temporary machine with the new image
3. Tarball Phase - Orchestrator extracts all `.beam` files and creates a tarball
4. Upload Phase - Uploads tarball to S3 storage
5. Metadata Phase - Updates deployment metadata with hot upgrade information
6. Reload Phase - Each running machine downloads the tarball
7. Extract Phase - Beam files are extracted and copied to disk
8. Detection Phase - `:code.modified_modules()` identifies changed modules
9. Suspension Phase - Processes using changed modules are suspended with `:sys.suspend/1`
10. Code Load Phase - Old modules are purged and new versions loaded
11. Migration Phase - `:sys.change_code/4` is called on each process
12. Resume Phase - Processes are resumed with `:sys.resume/1`

Total suspension time is typically under 1 second.

### Startup Reapply

When a machine restarts after a hot upgrade (due to crashes, scaling, or restarts):

1. `FlyDeploy.startup_reapply_current/1` checks for current hot upgrades
2. Compares the machine's Docker image ref with stored metadata
3. If refs match and a hot upgrade exists, downloads and applies it
4. Uses `:c.lm()` to load all modified modules before supervision tree starts
5. No process suspension needed since supervision tree hasn't started yet

This ensures machines that restart remain consistent with machines that were hot-upgraded.

## Configuration

### Environment Variables

Required:
- `AWS_ACCESS_KEY_ID` - S3 access key
- `AWS_SECRET_ACCESS_KEY` - S3 secret key
- `FLY_API_TOKEN` - Fly API token (usually auto-set)
- `FLY_APP_NAME` - Application name (auto-set by Fly)
- `FLY_IMAGE_REF` - Docker image reference (auto-set by Fly)

Optional:
- `AWS_BUCKET` - Override bucket name (defaults to `<app>-releases`)
- `AWS_ENDPOINT_URL_S3` - S3 endpoint (defaults to `https://fly.storage.tigris.dev`)
- `AWS_REGION` - AWS region (defaults to `auto` for Tigris)

### fly.toml Configuration

Environment variables from your `[env]` section are automatically passed to the orchestrator:

```toml
[env]
  AWS_ENDPOINT_URL_S3 = "https://fly.storage.tigris.dev"
  AWS_REGION = "auto"
  AWS_BUCKET = "my-app-staging"
```

### Mix Configuration

In `config/config.exs`:

```elixir
config :fly_deploy,
  bucket: "my-releases",
  max_concurrency: 10,
  env: %{
    "CUSTOM_VAR" => "value"
  }
```

## CLI Options

The `mix fly_deploy.hot` task supports several options:

- `--config` - Path to fly.toml file (default: "fly.toml")
- `--bucket` - Override S3 bucket name
- `--skip-build` - Skip building and use existing image (requires `--image`)
- `--image` - Use specific pre-built image
- `--dry-run` - Show what would be done without executing
- `--force` - Override deployment lock (use with caution)
- `--lock-timeout` - Lock expiry timeout in seconds (default: 300)

### Examples

Basic hot deployment:

```bash
mix fly_deploy.hot
```

Use staging configuration:

```bash
mix fly_deploy.hot --config fly-staging.toml
```

Preview changes without executing:

```bash
mix fly_deploy.hot --dry-run
```

Use pre-built image:

```bash
mix fly_deploy.hot --skip-build --image registry.fly.io/my-app:deployment-123
```

## Safety and Error Handling

FlyDeploy uses a 4-phase upgrade cycle to safely upgrade running processes:

1. **Phase 1: Suspend ALL processes** - All affected processes are suspended with `:sys.suspend/1` before any code loading
2. **Phase 2: Load ALL new code** - New code is loaded globally using `:code.purge/1` and `:code.load_file/1` while processes are safely suspended
3. **Phase 3: Upgrade ALL processes** - Each suspended process has `:sys.change_code/4` called to trigger its `code_change/3` callback
4. **Phase 4: Resume ALL processes** - All processes are resumed with `:sys.resume/1`
5. **Phase 5: Trigger LiveView reloads** (if applicable) - Phoenix LiveView pages automatically re-render with new code

This 4-phase approach eliminates race conditions where one upgraded process calls another that still has old code.

## Phoenix LiveView Integration

If you're using Phoenix LiveView, FlyDeploy automatically triggers re-renders after hot upgrades:

- Detects upgraded LiveView modules by checking for `Phoenix.LiveView` or `Phoenix.LiveComponent` behaviors
- Finds all active LiveView processes
- Sends `{:phoenix_live_reload, "fly_deploy", source_path}` messages directly to each LiveView PID
- LiveView automatically re-renders with the new code

## Rollback Strategy

Hot upgrades are forward-only. Once new code is loaded into the BEAM VM, you cannot unload it. If a hot upgrade causes issues, perform a cold deploy to a known good version:

```bash
fly deploy
```

The cold deploy will replace both the base Docker image and any hot upgrade state. This is similar to how OTP release upgrades work - they are also forward-only unless you build explicit downgrade instructions.

## Storage Structure

FlyDeploy stores two types of objects in S3:

### Release Tarballs

Path: `releases/<app>-<version>.tar.gz`

Contains all `.beam` files from `/app/lib/**/ebin/*.beam` with relative paths like:
```
lib/my_app-1.2.3/ebin/Elixir.MyModule.beam
lib/my_app-1.2.3/ebin/Elixir.MyModule.Server.beam
```

### Deployment Metadata

Path: `releases/<app>-current.json`

Tracks current deployment state:

```json
{
  "image_ref": "registry.fly.io/my-app:deployment-01K93Q...",
  "hot_upgrade": {
    "version": "1.2.3",
    "source_image_ref": "registry.fly.io/my-app:deployment-01K94R...",
    "tarball_url": "https://fly.storage.tigris.dev/bucket/releases/my_app-1.2.3.tar.gz",
    "deployed_at": "2024-01-15T10:30:00Z"
  }
}
```

## When to use cold deploy instead of hot upgrade
- Adding/removing services from supervision tree (database, cache, etc.)
- Changing port numbers, protocols, or network config
- Enabling/disabling major features that affect app structure
- Upgrading dependencies that change supervision requirements

## Testing

Run the test suite:

```bash
mix test
```

Run E2E tests (requires a deployed Fly app):

```bash
mix test test/fly_deploy/e2e_test.exs --only e2e
```


