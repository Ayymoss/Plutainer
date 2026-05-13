# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Plutainer is a Docker image for running Plutonium, IW4x, and Alterware dedicated game servers (Call of Duty titles: T4/WaW, T5/BO1, T6/BO2, IW5/MW3, IW4x/MW2, T7x/BO3). It uses Wine on Arch Linux to run the Windows game server binaries, configured entirely via environment variables.

## Build & Test

```bash
# Build the Docker image locally
docker build -t plutainer .

# Run a Plutonium container example (v2 env vars)
docker run -e PLUTAINER_GAME=t6zm -e PLUTO_SERVER_KEY=<key> -e PLUTAINER_CONFIG_FILE=dedicated.cfg \
  -v /path/to/game_files:/home/plutainer/gamefiles:ro \
  -v ./server-data:/home/plutainer/app \
  -p 4976:4976/udp plutainer

# Run an IW4x container example
docker run -e PLUTAINER_GAME=iw4x -e PLUTAINER_CONFIG_FILE=server.cfg \
  -v /path/to/game_files:/home/plutainer/gamefiles:ro \
  -v ./server-data:/home/plutainer/app \
  -p 28960:28960/udp plutainer
```

There are no automated tests or linters. The CI pipeline (`.github/workflows/docker-publish.yml`) builds and pushes to `ghcr.io` on pushes to `main` and on releases.

## Tags

- `ghcr.io/ayymoss/plutainer:v2` — built from `v2-layout` branch. New volume layout + unified `PLUTAINER_*` env vars. Opt-in. CI workflow tags it only on pushes to `v2-layout`; never promotes to `:latest`.
- `ghcr.io/ayymoss/plutainer:latest` — built from `main`. Deprecated v1 layout. No further v2 work merges here; bug-only updates if any.

CI logic in `.github/workflows/docker-publish.yml`:
- `type=raw,value=latest,enable={{is_default_branch}}` — only on main.
- `type=raw,value=v2,enable=${{ github.ref == 'refs/heads/v2-layout' }}` — only on v2-layout.
- Both branches also get `:sha-<short>`. Branches stay completely separated.

## Architecture

Everything runs as the `plutainer` user from `/home/plutainer/.plutainer`. All entry scripts run with `set -euo pipefail`.

1. **`entrypoint.sh`** — Top-level dispatcher. Sources `game-config.sh`, calls `detect_game_type` (requires `PLUTAINER_GAME`), `check_volume_version` (refuses v1 volumes), then `exec`s the family-specific entry script. On any failure: `hold_indefinitely` (sleep infinity) instead of exiting, to avoid restart loops.

2. **`plutoentry.sh`** — Plutonium server entrypoint. Symlinks game files from the read-only gamefiles mount, runs `plutonium-updater`, seeds bundled configs into the SOT location, fans out symlinks from `app/configs/` to the engine and (if `PLUTAINER_MOD` is set) the mod config dir, calls `ensure_config_present` (auto-lift + refusal), then `launch_game wine ...` (30s exit-throttle wrapper).

3. **`iw4xentry.sh`** — IW4x server entrypoint. Same shape: symlinks game files, runs `iw4x-launcher`, fans out config symlinks (engine + optional mod dir), validates, `launch_game wine iw4x.exe`. No seed bundle.

4. **`alterentry.sh`** — Alterware (T7x/BO3) entrypoint. Symlinks game files, uses `wget -N` (timestamping) to fetch `t7x.exe` only when upstream is newer, seeds Dss0/t7-server-config bundle, fans out config symlinks, starts `Xvfb` (T7x requires a display), `launch_game wine t7x.exe`. No mod dir (alterware MOD is a Steam Workshop ID).

5. **`game-config.sh`** — Shared shell library sourced by all other scripts. Key helpers:
   - Volume path constants: `PLUTAINER_APP_DIR`, `PLUTAINER_CONFIGS_DIR`, `PLUTAINER_RUNTIME_DIR`, `PLUTAINER_GAMEFILES_DIR`, `PLUTAINER_PLUTONIUM_DIR`, `PLUTAINER_SOURCE_DIR`.
   - `hold_indefinitely <msg>`: print the error, then `exec sleep infinity` so the container stays `Up` instead of looping through restarts. Used for any startup validation failure.
   - `launch_game <cmd>...`: wraps the game invocation; on exit, sleeps 30s before letting the script exit, so docker's restart policy throttles to ~1 restart per 30s.
   - `derive_family <game-tag>`: returns `plutonium`/`iw4x`/`alterware`.
   - `detect_game_type`: validates `PLUTAINER_GAME` (no shim — only PLUTAINER_* accepted), sets `GAME_TYPE`/`GAME_NAME`/`BASE_GAME`/`CONFIG_FILE`/`CUSTOM_PORT`/`HEALTHCHECK_FLAG`.
   - `resolve_default_port`, `resolve_engine_config_dir`, `resolve_mod_config_dir`.
   - `resolve_config_layout`: sets `CONFIG_SOT_DIR` and `ALT_CONFIG_DIR` based on `PLUTAINER_USE_RAW_CONFIGS`. Default: SOT = `configs/`, ALT = engine dir. With raw mode on: swapped.
   - `resolve_config_path`: convenience wrapper that resolves the engine dir + layout in one call so healthcheck/rcon-cli only need this.
   - `link_files <src> <dest> <name1>...`: existence-guarded symlink helper; replaces unsafe `ln -sf src/{a,b,c} dest/` bash brace expansion.
   - `seed_configs <game-key> <asset-root> <cfg-root-rel>`: walks bundled seed, lifts top-level `*.cfg` files inside `cfg-root-rel` into `CONFIG_SOT_DIR`, places everything else under `asset-root`. Idempotent.
   - `link_configs <engine-dir1> [engine-dir2 ...]`: variadic. Fans out symlinks from every `configs/*.cfg` into each engine dir using relative paths. Refuses to overwrite a real (non-symlink) file at engine path (warns instead). Reaps dangling cfg symlinks. No-op when `PLUTAINER_USE_RAW_CONFIGS=true`.
   - `ensure_config_present`: checks that `CONFIG_FILE` exists at `CONFIG_SOT_DIR`. If absent there but present as a real file at the ALT location, moves it (auto-lift). If absent everywhere, prints a refusal with a `find -iname` case-insensitive hint, returns non-zero.
   - `check_volume_version`: refuses v1 volumes with explicit migration instructions; initialises fresh volumes; writes `.plutainer-version=2`.
   - `extract_rcon_password`: parses `rcon_password` from `CONFIG_PATH`. Handles double-quoted, single-quoted, and unquoted values. Strips `//` comments. On failure, prints a structured `[WARN]` (don't block startup) telling the user the accepted forms and not to set the password via `PLUTAINER_EXTRA_ARGS`.

6. **`migrate-v1-to-v2.sh`** — One-shot migration tool, run via `docker run --entrypoint`. Moves `app/gamefiles` → `app/runtime/gamefiles`, `app/plutonium` → `app/runtime/plutonium`, lifts top-level cfg files from known engine config dirs into `app/configs/` and replaces them with relative symlinks, clears stale `app/logs/` entries, writes `.plutainer-version=2`. Supports `--dry-run`.

7. **`log-watcher.sh`** — Background poller started by each entrypoint before `exec wine`. Discovers every `*.log` under `/home/plutainer/app/` (excluding `app/logs/` itself to avoid cycles) and maintains relative symlinks at `/home/plutainer/app/logs/<basename>` pointing at the active one. Active = newest mtime >= container boot time. Agnostic to log name. Symlinks are relative so they resolve the same on host, in this container, or in a sidecar IW4MAdmin container. Disable with `PLUTAINER_LOG_SYMLINKS=false`; poll interval via `PLUTAINER_LOG_POLL_INTERVAL` (default 2s).

8. **`healthcheck.sh`** — Sources `game-config.sh`, then uses `pyquake3.py` to send an RCON `status` command. Enabled by default; disable with `PLUTAINER_HEALTHCHECK=false`. HEALTHCHECK directive uses `--start-period=5m` to accommodate first-run downloads.

9. **`rcon-cli`** — Python script providing interactive and one-shot RCON access via `docker exec`. Calls `game-config.sh` to resolve port/credentials. Supports Plutonium, IW4x, and Alterware.

10. **`pyquake3.py`** — Python 3 Quake 3 protocol library (UDP). Used by the health check and `rcon-cli` for RCON queries.

## Volume Layout (v2)

```
/home/plutainer/gamefiles            # read-only host gamefiles bind
/home/plutainer/app/
  configs/                           # User-facing real *.cfg files (flat).
                                     # Edit here. Engine paths symlink in.
  logs/                              # Stable symlinks to active *.log files
                                     # (maintained by log-watcher.sh).
                                     # Sidecars (IW4MAdmin) mount this dir.
  runtime/
    gamefiles/                       # Symlinks into host gamefiles plus
                                     # writable game state (mods, .iwd, etc).
    plutonium/                       # Plutonium binaries + storage state.
  .plutainer-version                 # "2" — layout marker.
/home/plutainer/.plutainer/          # Scripts, updaters, pyquake3, seed-configs.
```

**Config flow:** user edits `app/configs/<file>.cfg` → entrypoint places a relative symlink at the engine's expected path → game reads via symlink. RCON `writeconfig` writes through the symlink, modifying the real file in `configs/`.

## Game-Specific Behavior

For Plutonium, `BASE_GAME` is derived by stripping the last two chars from `PLUTAINER_GAME` (e.g., `t6zm` → `t6`). This drives:

- **Default ports**: iw4x→28960, iw5→27016, t4/t5→28960, t6→4976, t7x→27017.
- **Engine config dirs** (where the game reads `+exec`'d cfg files): t4 → `runtime/gamefiles/main/`, iw5 → `runtime/gamefiles/admin/`, iw4x → `runtime/gamefiles/userraw/`, t7x → `runtime/gamefiles/zone/`, others → `runtime/plutonium/storage/<base_game>/`.
- **Command args**: iw5 uses `+set sv_config` and `+start_map_rotate`; others use `+exec` and `+map_rotate`.
- **Game-file symlinks** differ per base game (see `plutoentry.sh` case statement).

## Compatibility surface

The `:v2` image is a **clean break** from `:latest`. The two share no env vars (other than the always-unique `PLUTO_SERVER_KEY`, `PLUTO_MAX_CLIENTS`, `IW4X_NET_LOG_IP`) and no volume layout. There is no env-var shim in `:v2` — legacy `PLUTO_*`/`IW4X_*`/`ALTER_*` names are silently ignored.

A v1 `app/` volume is refused on startup (`check_volume_version`) with explicit instructions to run `migrate-v1-to-v2.sh`.

## Restart behavior

Two distinct failure modes:

- **Configuration errors** (validation failures, missing env vars, missing config file, v1 volume, unknown game): `hold_indefinitely` → `exec sleep infinity`. Container stays `Up`; healthcheck eventually marks it unhealthy. No restart loop. User fixes and runs `docker restart <name>`.
- **Runtime crashes** (wine exits): `launch_game` wrapper catches the exit, sleeps 30s, then exits with the original return code. Docker's restart policy fires after that, giving ~1 restart per 30s instead of immediate churn.

`STOPSIGNAL` is `SIGKILL`, so neither path interferes with `docker stop` — that's instant by design.
