# Plutainer: Dockerized Plutonium, IW4x & Alterware Game Servers

This repository contains the necessary files to build and run dedicated game servers for Plutonium, IW4x, and Alterware using Docker. The image is designed to be flexible and configurable through environment variables.

The container is available on GitHub Container Registry: `ghcr.io/ayymoss/plutainer:latest`

> **Tag layout:**
> - `:latest` (and the `:v2` alias) — current Plutainer v2. New volume layout, unified `PLUTAINER_*` environment variables. Built from `main`.
> - `:v1-final` (and the `:v1` alias) — frozen snapshot of the old v1 image. Legacy `PLUTO_*`/`IW4X_*`/`ALTER_*` env vars, flat `app/gamefiles/` + `app/plutonium/` layout. Shows a deprecation banner on every start. No further updates, fixes, or security patches.
>
> **Upgrading from v1?** See [MIGRATION.md](MIGRATION.md) — covers the env var rename, the volume migration command (one `docker run`), and how to pin `:v1-final` if you want to defer the migration.

## Overview

The primary goal of this Docker image is to simplify the setup and management of dedicated servers for the following games:

* **Plutonium:**
  * T4 (Call of Duty: World at War) - `t4mp`, `t4sp`
  * T5 (Call of Duty: Black Ops) - `t5mp`, `t5sp`
  * T6 (Call of Duty: Black Ops II) - `t6mp`, `t6zm`
  * IW5 (Call of Duty: Modern Warfare 3) - `iw5mp`
* **IW4x:** (Call of Duty: Modern Warfare 2) - `iw4x`
* **Alterware:**
  * T7x (Call of Duty: Black Ops III) - `t7x`

The container includes the installation of Wine, Plutonium, IW4x, and Alterware launchers, and sets up a non-root user for enhanced security.

## Prerequisites

Before you can use this Docker image, you will need to have the base game files for the server you wish to host. This image does not provide any copyrighted game files. You must legally own the games.

You will also need to have Docker and Docker Compose installed on your system.

## Getting Started: `docker-compose.yml`

Instead of using a long `docker run` command, it is highly recommended to use `docker-compose` to manage your server. See [EXAMPLE-docker-compose.yml](EXAMPLE-docker-compose.yml) for complete examples.

## Configuration

### Environment Variables

The container is configured entirely through environment variables. You must set `PLUTAINER_GAME` to one of the supported game tags.

#### Unified (`PLUTAINER_*`) — apply to all games

| Variable | Description | Default |
| --- | --- | --- |
| `PLUTAINER_GAME` | **Required.** Game tag: `t4mp`, `t4sp`, `t5mp`, `t5sp`, `t6mp`, `t6zm`, `iw5mp`, `iw4x`, or `t7x`. | |
| `PLUTAINER_CONFIG_FILE` | **Required.** Filename of your server's config (e.g., `dedicated.cfg`). Lives in `app/configs/` (see [Volume Layout](#volume-layout)). | |
| `PLUTAINER_PORT` | Network port for the server. | Game-specific (see [Default Ports](#default-ports)). |
| `PLUTAINER_SERVER_NAME` | Display name used in startup logs. | Game-family-specific default. |
| `PLUTAINER_MOD` | Mod folder name (Plutonium/IW4x) or Steam Workshop ID (T7x). Omit if no mod. | |
| `PLUTAINER_AUTO_UPDATE` | Set to `"false"` to skip update checks at startup. | `true` |
| `PLUTAINER_HEALTHCHECK` | Set to `"false"` to disable the RCON health check. | `true` |
| `PLUTAINER_SKIP_SEED` | Set to `"true"` to skip first-run [config seeding](#bundled-config-seeds). | `false` |
| `PLUTAINER_EXTRA_ARGS` | Extra arguments appended to the launch command. | |
| `PLUTAINER_USE_RAW_CONFIGS` | Set to `"true"` to put cfg files directly in the engine path under `app/runtime/...` and skip the `app/configs/` symlink system. See [Raw Configs Mode](#raw-configs-mode). | `false` |
| `PLUTAINER_LOG_SYMLINKS` | Set to `"false"` to disable the [log symlink watcher](#log-symlinks). | `true` |
| `PLUTAINER_LOG_POLL_INTERVAL` | Seconds between log watcher polls. | `2` |

#### Game-specific (unique to one stack)

These cannot be unified because they only apply to a single engine family:

| Variable | Description | Applies to |
| --- | --- | --- |
| `PLUTO_SERVER_KEY` | **Required for Plutonium.** Server key from <https://platform.plutonium.pw/serverkeys>. | Plutonium only |
| `PLUTO_MAX_CLIENTS` | Maximum players (Plutonium T5 only — other games set this in the cfg). | Plutonium T5 only |
| `IW4X_NET_LOG_IP` | IP:port for IW4x remote netlogging (`g_log_add`). | IW4x only |

#### Default ports

| Game | Default |
| --- | --- |
| iw4x | 28960 |
| iw5 | 27016 |
| t4, t5 | 28960 |
| t6 | 4976 |
| t7x | 27017 |

> The legacy `PLUTO_*`/`IW4X_*`/`ALTER_*` prefixed env vars from the `:latest` (v1) image are **not accepted** on `:v2`. Use the unified `PLUTAINER_*` names above. The only old names that remain are `PLUTO_SERVER_KEY`, `PLUTO_MAX_CLIENTS`, and `IW4X_NET_LOG_IP` — they are single-family vars and never had a unified form.

***

### Volume Layout

The container expects two volume mounts:

| Container path | Purpose | Recommended host mount |
| --- | --- | --- |
| `/home/plutainer/gamefiles` | Read-only base game files you own. | Bind-mount with `:ro`. |
| `/home/plutainer/app` | Persistent server state, configs, and logs. | Bind-mount or named volume. |

On a fresh `app/` mount, the container initialises this layout on first start:

```
app/
  configs/                # Your server's *.cfg files. Edit here.
  logs/                   # Stable symlinks to active *.log files (see Log Symlinks).
  runtime/
    gamefiles/            # Symlinks into the read-only gamefiles mount, plus
                          # writable game state (mods, maps, plutonium storage).
    plutonium/            # Plutonium binaries and storage.
  .plutainer-version      # "2" — marks volume layout version.
```

**Where to put your `*.cfg` files:** drop them in `app/configs/` and set `PLUTAINER_CONFIG_FILE` to the filename. The container creates a symlink at the engine's expected path on each start, so the game still reads from its usual location — you just have one predictable place to edit.

Example: for a T6 server with `PLUTAINER_CONFIG_FILE=dedicated_zm.cfg`, you edit `app/configs/dedicated_zm.cfg`, and the container symlinks `app/runtime/plutonium/storage/t6/dedicated_zm.cfg → ../../../../configs/dedicated_zm.cfg`.

If you set `PLUTAINER_MOD`, the same cfg also gets symlinked into the mod's config dir (e.g. `app/runtime/plutonium/storage/t6/<mod>/dedicated_zm.cfg`), so the engine finds it whether it looks in the base dir or the mod-scoped one.

Nested configs (e.g. cfg files referenced by mods using subdirectories) stay at their engine path under `app/runtime/` and are not lifted to `configs/`. You can still edit them there.

**Auto-lift:** if you set `PLUTAINER_CONFIG_FILE=dedicated.cfg` but the file is at `app/runtime/.../dedicated.cfg` (as a real file, not symlink) rather than `app/configs/dedicated.cfg`, the container moves it into `app/configs/` on next start and the symlink fan-out picks it up. One-time fix, no manual migration.

**Filename mismatch:** if the configured file doesn't exist anywhere, the container refuses to start with a clear error and (if there's a case-only mismatch like `Server.cfg` vs `server.cfg`) tells you which case-insensitive match it found. Filenames remain case-sensitive — the container won't auto-rename.

***

### Raw Configs Mode

Set `PLUTAINER_USE_RAW_CONFIGS=true` to opt out of the `app/configs/` SOT model. With this on:

- The engine config dir under `app/runtime/...` becomes the source of truth.
- `app/configs/` is left untouched (whatever's there is ignored).
- No symlinks are placed; cfg files live where the game reads them.
- Seed configs go directly into the engine dir.

Use this when you want the v1 editing experience inside the v2 directory layout (e.g. tooling on your host expects to find `t6zm-1/runtime/plutonium/storage/t6/dedicated.cfg` as a real file). Default-off so most users get the "edit in one folder" affordance without thinking about it.

You can toggle this between restarts. Plutainer doesn't migrate files when you flip the flag — that's on you.

***

### Upgrading from v1

If you have an existing deployment that was running an older `:latest` (now `:v1-final`), pulling the new `:latest` (v2) refuses to start: v2 detects either v1 environment variables (`PLUTO_*`/`IW4X_*`/`ALTER_*`) or the v1 volume layout (`app/gamefiles/`, `app/plutonium/` at the top level with no `.plutainer-version` marker) and prints a combined refusal block in `docker logs` listing exactly what was detected, plus the two paths forward.

**Full step-by-step guide:** [MIGRATION.md](MIGRATION.md) — env var mapping table, the one-command volume migration, dry-run option, and how to pin `:v1-final` if you would rather defer.

Quick summary of the migration path:

1. `docker compose down`
2. Run the migration tool once per volume (append `--dry-run` to preview):
   ```sh
   docker run --rm \
     -v <YOUR_APP_VOLUME>:/home/plutainer/app \
     --entrypoint /home/plutainer/.plutainer/migrate-v1-to-v2.sh \
     ghcr.io/ayymoss/plutainer:v2
   ```
3. Rename `PLUTO_*`/`IW4X_*`/`ALTER_*` env vars to `PLUTAINER_*` in your compose (full table in MIGRATION.md).
4. `docker compose up -d`

If you also have IW4MAdmin sidecar mounts pointing at log paths like `./t6zm-1/plutonium/storage/...`, update them to `./t6zm-1/runtime/plutonium/storage/...` — or better, switch to the stable [log symlink directory](#log-symlinks).

***

### Bundled Config Seeds

To make first-run setup painless, the image bundles default configs from community repos and copies them into the bind-mounted `app/` volume on container start. Files that already exist are **never overwritten** — existing user configs are always kept as-is.

Top-level `*.cfg` files from each seed bundle land in `app/configs/` (flat). Other assets (mod scripts, maps, nested cfgs, lobby scripts) land under `app/runtime/` at their engine-expected paths.

| Game | Source repo |
| --- | --- |
| Plutonium T4 | [xerxes-at/T4ServerConfigs](https://github.com/xerxes-at/T4ServerConfigs) |
| Plutonium T5 | [xerxes-at/T5ServerConfig](https://github.com/xerxes-at/T5ServerConfig) |
| Plutonium T6 | [xerxes-at/T6ServerConfigs](https://github.com/xerxes-at/T6ServerConfigs) |
| Plutonium IW5 | [xerxes-at/IW5ServerConfig](https://github.com/xerxes-at/IW5ServerConfig) |
| Alterware T7x | [Dss0/t7-server-config](https://github.com/Dss0/t7-server-config) (includes `t7x/lobby_scripts/` required for `sv_lobby_mode`) |

To opt out — for example if you manage configs entirely yourself and don't want any default files appearing in your bind mount — set `PLUTAINER_SKIP_SEED=true`.

The seed snapshot is frozen at image build time. Pulling a newer image only seeds files that don't yet exist in your bind mount, so the upstream repo never silently overwrites your edits.

***

### Permissioning

#### Mount Permissions

When you mount volumes from your host machine into the container, the `plutainer` user (with UID `1000`) needs to have the appropriate permissions to read and write to those directories. If the ownership on your host directories is incorrect, the server may fail to start or be unable to save data.

On many desktop Linux distributions, the first user you create is automatically assigned UID `1000`. If you are that user, you may not need to do anything. However, if you created the directories as `root` (e.g., using `sudo mkdir`), you will need to update their ownership.

#### How to Fix Permissions

To ensure the container has the correct access, change the ownership of your persistent data directory to match the container's user. Run the following command on your host machine, adjusting the path to match your setup:

```sh
sudo chown -R 1000:1000 /opt/pluto-servers/t6zm-server-1/
```

The `-R` flag applies the ownership recursively, ensuring all files and sub-folders have the correct permissions.

***

### RCON CLI

The container includes a built-in RCON client for sending commands to your server. It automatically detects the game type, port, and RCON password from your configuration — no extra setup needed.

```sh
# Send a single command
docker exec <container_name> rcon-cli status

# Open an interactive RCON session
docker exec -i <container_name> rcon-cli
```

Your server configuration file must have `rcon_password` set for `rcon-cli` to work. Accepted forms in the cfg:

```
set  rcon_password "your_password_here"
seta rcon_password 'also_works'
set  rcon_password unquoted_also_ok
```

Comment-only lines (`// ...`) are ignored. If multiple uncommented `rcon_password` lines exist, the last one wins. If the parser can't find one, the container prints a `[WARN]` at startup but keeps running — healthcheck and rcon-cli are then unavailable until you add it. **Do not** set `rcon_password` via `PLUTAINER_EXTRA_ARGS` — Plutainer cannot read it back from there.

***

### Restart behavior

Plutainer distinguishes between *configuration errors* (your fault) and *runtime crashes* (the game's fault):

- **Configuration error** (e.g. missing `PLUTAINER_CONFIG_FILE`, wrong volume version, unparseable `PLUTAINER_GAME`): the container prints the error and then `sleep infinity` to **hold** in the `Up` state. No restart loop. Fix the issue and run `docker restart <container>`.
- **Runtime crash** (wine exits, game segfaults, etc): the container sleeps **30 seconds** after the game process exits, then exits itself. Docker's `restart: unless-stopped` (or your chosen policy) then restarts it. This rate-limits crash loops to ~1 restart per 30s instead of hammering immediately.

Healthcheck still runs on a held container and will eventually mark it unhealthy — useful signal for orchestration.

***

### Log Symlinks

The container maintains a flat directory of symlinks at `app/logs/` pointing at the active `*.log` file for each basename. Game logs move around per game/mod (e.g. `runtime/plutonium/storage/t5/mods/<mod>/logs/games_zm.log`); the watcher surfaces them all in one predictable place so IW4MAdmin (or any other log reader) doesn't have to chase the exact path.

Mount `app/logs/` as the source for downstream log consumers:

```yaml
volumes:
  - ./t6zm-1/logs:/app/gamelogs/t6zm-1:ro
```

Symlinks are relative, so they resolve correctly from the host, this container, or a sidecar container mounting the same `app/` volume.

Disable with `PLUTAINER_LOG_SYMLINKS=false`; change poll interval with `PLUTAINER_LOG_POLL_INTERVAL` (default 2s).

***

### Advanced: IW4MAdmin & RCON

Connecting a containerized IW4MAdmin to your Plutainer server requires special network configuration due to the way Docker handles container-container networking via its proxy.

This guide applies to a specific scenario:

* Your Plutainer game server is running in a container.
* IW4MAdmin is running in a **separate container on the same host**, but on a **different Docker bridge network**.

Do **not** run IW4MAdmin from within the same bridge network as your Plutainer containers.
In this setup, when IW4MAdmin sends an RCON command, the game server sees the request as coming from its own network's **gateway IP**, not the IW4MAdmin container's IP.

#### Solution: Whitelist the Gateway

You must whitelist your Plutainer container's network gateway IP for RCON commands.

**Example:** Consider this `docker-compose.yml` network configuration:

```yaml
networks:
  pluto-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.26.10.0/24
          gateway: 172.26.10.1 # <--- This is the gateway IP
```

If your game server is attached to `pluto-net`, you must add `"172.26.10.1"` to your server's `.cfg` RCON whitelist directive to grant IW4MAdmin access.

This issue does **not** occur if you are running IW4MAdmin directly on the host machine (bare-metal) or on an entirely different machine.

***

### Healthcheck

The container includes a robust health check script that verifies the server is running and responsive. It works by:

1. Detecting the game type and port.
2. Locating your server configuration file in `app/configs/`.
3. Extracting your `rcon_password` from the config.
4. Sending an RCON `status` command to the server.
5. Checking for a valid response.

The health check is enabled by default. You can disable it by setting `PLUTAINER_HEALTHCHECK=false`. This can be useful for debugging or if you do not wish to set an RCON password.

For the healthcheck to work correctly, games that support RCon whitelists need to have localhost permitted and/or `127.0.0.1`.

To have your servers restarted automatically, add [Auto Heal](https://github.com/willfarrell/docker-autoheal) to the compose.

***

### Support?

Discord Support: <https://discord.gg/PjrFw4tNES>

Please note that I will not be supporting Plutonium-specific issues. There is an expectation that you're already familiar with Docker. If you're brand new, please visit <https://docs.docker.com/get-started/>

This Discord is to be specific to Plutainer and its setup and configuration (including IW4MAdmin).

***

#### Credits

- Corey, for a production testing ground @ <https://cukservers.net/>
- HGM, for the name 'Plutainer' @ <https://hgmserve.rs/>
