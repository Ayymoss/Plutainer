# Plutainer: Dockerized Plutonium, IW4x & Alterware Game Servers

This repository contains the necessary files to build and run dedicated game servers for Plutonium, IW4x, and Alterware using Docker. The image is designed to be flexible and configurable through environment variables.

The container is available on GitHub Container Registry: `ghcr.io/ayymoss/plutainer:v2`

> **Tag note (v2):** The `v2` tag tracks the new v2 volume layout and the unified `PLUTAINER_*` environment variables. It is built from the `v2-layout` branch and is intentionally separate from `latest`. The `latest` tag continues to point at the older v1 image (legacy `PLUTO_*`/`IW4X_*`/`ALTER_*` env vars, flat `app/gamefiles/` + `app/plutonium/` layout) and is deprecated — no further updates. If you are migrating an existing deployment, see [Upgrading from v1](#upgrading-from-v1). Opt in by changing your `image:` line to `ghcr.io/ayymoss/plutainer:v2`.

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

#### Backward compatibility (deprecated old-prefix names)

The old `PLUTO_*`, `IW4X_*`, and `ALTER_*` prefixed environment variables are still accepted but will emit a `[DEPRECATED]` warning at startup. They map onto the unified names below:

| Old (deprecated) | New canonical |
| --- | --- |
| `PLUTO_GAME`, `IW4X_GAME`, `ALTER_GAME` | `PLUTAINER_GAME` |
| `PLUTO_CONFIG_FILE`, `IW4X_CONFIG_FILE`, `ALTER_CONFIG_FILE` | `PLUTAINER_CONFIG_FILE` |
| `PLUTO_PORT`, `IW4X_PORT`, `ALTER_PORT` | `PLUTAINER_PORT` |
| `PLUTO_SERVER_NAME`, `IW4X_SERVER_NAME`, `ALTER_SERVER_NAME` | `PLUTAINER_SERVER_NAME` |
| `PLUTO_MOD`, `IW4X_MOD`, `ALTER_MOD` | `PLUTAINER_MOD` |
| `PLUTO_AUTO_UPDATE`, `IW4X_AUTO_UPDATE`, `ALTER_AUTO_UPDATE` | `PLUTAINER_AUTO_UPDATE` |
| `PLUTO_HEALTHCHECK`, `IW4X_HEALTHCHECK`, `ALTER_HEALTHCHECK` | `PLUTAINER_HEALTHCHECK` |
| `PLUTO_SKIP_SEED`, `ALTER_SKIP_SEED` | `PLUTAINER_SKIP_SEED` |
| `PLUTO_EXTRA_ARGS`, `IW4X_EXTRA_ARGS`, `ALTER_EXTRA_ARGS` | `PLUTAINER_EXTRA_ARGS` |

`PLUTO_SERVER_KEY`, `PLUTO_MAX_CLIENTS`, and `IW4X_NET_LOG_IP` keep their original names — they are not duplicates across families, so they don't need unification.

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

Nested configs (e.g. mod-specific cfgs inside `mods/<name>/`) stay at their engine path under `app/runtime/` and are not lifted to `configs/`. You can still edit them there.

***

### Upgrading from v1

If you have an existing deployment running the older `:latest` tag, your `app/` volume is in the **v1 layout** (no `configs/` or `runtime/` dirs, `gamefiles/` and `plutonium/` at the top level). The v2 container will refuse to start against a v1 volume — running it produces a clear error pointing to this section.

Run the bundled migration tool once per volume:

```sh
docker run --rm \
  -v <YOUR_APP_VOLUME>:/home/plutainer/app \
  --entrypoint /home/plutainer/.plutainer/migrate-v1-to-v2.sh \
  ghcr.io/ayymoss/plutainer:v2
```

Replace `<YOUR_APP_VOLUME>` with the path bound to `/home/plutainer/app` in your compose file (e.g. `./t6zm-1`). The tool:

1. Creates `runtime/` and `configs/`.
2. Moves `app/gamefiles/` → `app/runtime/gamefiles/`.
3. Moves `app/plutonium/` → `app/runtime/plutonium/`.
4. Lifts every top-level `*.cfg` from the engine config dirs into `app/configs/`, leaving a relative symlink in its place.
5. Clears stale entries in `app/logs/` (the log-watcher repopulates on next start).
6. Writes `app/.plutainer-version=2`.

Add `--dry-run` after the entrypoint to preview without modifying anything:

```sh
docker run --rm \
  -v <YOUR_APP_VOLUME>:/home/plutainer/app \
  --entrypoint /home/plutainer/.plutainer/migrate-v1-to-v2.sh \
  ghcr.io/ayymoss/plutainer:v2 --dry-run
```

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

Your server configuration file must have `rcon_password` set for `rcon-cli` to work.

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
