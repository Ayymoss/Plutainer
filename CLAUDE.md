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

1. **`entrypoint.sh`** — Top-level dispatcher. Sources `game-config.sh`, applies `shim_env_vars` (back-compat for old prefixed names), calls `detect_game_type` to derive `GAME_TYPE`/`BASE_GAME`/etc from `PLUTAINER_GAME`, runs `check_volume_version` (refuses v1 volumes), then `exec`s the family-specific entry script.

2. **`plutoentry.sh`** — Plutonium server entrypoint. Symlinks game files from the read-only gamefiles mount, runs `plutonium-updater`, seeds bundled configs into `app/configs/`, fans out symlinks from `app/configs/` to the engine's expected config dir, validates env vars, then `exec`s `wine bin/plutonium-bootstrapper-win32.exe`.

3. **`iw4xentry.sh`** — IW4x server entrypoint. Same shape: symlinks game files, runs `iw4x-launcher`, fans out config symlinks, validates env vars, `exec`s `wine iw4x.exe`. No seed bundle (IW4x has no community config repo configured).

4. **`alterentry.sh`** — Alterware (T7x/BO3) entrypoint. Symlinks game files, uses `wget -N` (timestamping) to fetch `t7x.exe` only when upstream is newer, seeds Dss0/t7-server-config bundle, fans out config symlinks, validates env vars, starts `Xvfb` (T7x requires a display), `exec`s `wine t7x.exe`.

5. **`game-config.sh`** — Shared shell library sourced by all other scripts. Provides:
   - Volume path constants: `PLUTAINER_APP_DIR`, `PLUTAINER_CONFIGS_DIR`, `PLUTAINER_RUNTIME_DIR`, `PLUTAINER_GAMEFILES_DIR`, `PLUTAINER_PLUTONIUM_DIR`, `PLUTAINER_SOURCE_DIR`.
   - `shim_env_vars`: maps deprecated `PLUTO_*`/`IW4X_*`/`ALTER_*` names onto unified `PLUTAINER_*` with a `[DEPRECATED]` warning.
   - `derive_family <game-tag>`: returns `plutonium`/`iw4x`/`alterware`.
   - `detect_game_type`: validates `PLUTAINER_GAME`, sets `GAME_TYPE`/`GAME_NAME`/`BASE_GAME`/`CONFIG_FILE`/`CUSTOM_PORT`/`HEALTHCHECK_FLAG`.
   - `resolve_default_port`, `resolve_engine_config_dir`, `resolve_config_path`.
   - `link_files <src> <dest> <name1>...`: existence-guarded symlink helper; replaces unsafe `ln -sf src/{a,b,c} dest/` bash brace expansion that creates dangling symlinks when source files are missing.
   - `seed_configs <game-key> <asset-root> <cfg-root-rel>`: walks bundled seed, lifts top-level `*.cfg` files inside `cfg-root-rel` into `app/configs/`, places everything else under `asset-root`. Idempotent (`cp -n`).
   - `link_configs <engine-config-dir>`: fans out symlinks from every `app/configs/*.cfg` into the engine's expected dir using relative paths. Reaps dangling cfg symlinks.
   - `check_volume_version`: refuses v1 volumes with explicit migration instructions; initialises fresh volumes; writes `.plutainer-version=2`.
   - `extract_rcon_password`: parses `rcon_password` from `CONFIG_PATH`.

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

## Backward Compatibility

Old prefixed env vars (`PLUTO_*`, `IW4X_*`, `ALTER_*`) still work — `shim_env_vars` in `game-config.sh` copies them onto the canonical `PLUTAINER_*` names and emits a `[DEPRECATED]` warning. Three names stay as-is because they only apply to a single engine family: `PLUTO_SERVER_KEY`, `PLUTO_MAX_CLIENTS`, `IW4X_NET_LOG_IP`.

A v1 `app/` volume is refused on startup (`check_volume_version`) with explicit instructions to run `migrate-v1-to-v2.sh`.
