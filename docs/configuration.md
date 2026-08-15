# Configuration

Every setting is an environment variable. Only two are required.

## Required

| Variable | Description |
| --- | --- |
| `PLUTAINER_GAME` | Which game — `t4mp`, `t4sp`, `t5mp`, `t5sp`, `t6mp`, `t6zm`, `iw5mp`, `iw4x`, `t7x`, `cod4x` |
| `PLUTAINER_CONFIG_FILE` | Which config to run, e.g. `dedicated_zm.cfg`. Must exist in `app/configs/` — Plutainer seeds one on first start ([names per game](games.md)) |

Plutonium games (`t4*`, `t5*`, `t6*`, `iw5mp`) also require `PLUTO_SERVER_KEY`.

## Common

| Variable | Description | Default |
| --- | --- | --- |
| `PLUTAINER_PORT` | Network port | [per game](games.md) |
| `PLUTAINER_RCON_PASSWORD` | Sets `rcon_password` in your config at startup. Opt-in — unset leaves your config untouched | unset |
| `PLUTAINER_SERVER_NAME` | Name shown in Plutainer's own startup logs (not the in-game hostname — that's `sv_hostname` in your cfg) | per family |
| `PLUTAINER_MOD` | Mod folder name. On T7x, a Steam Workshop ID instead | unset |
| `PLUTAINER_MAP_ROTATE` | `false` drops the automatic `+map_rotate` (`+start_map_rotate` on IW5), leaving map choice to your cfg or playlist. N/A on T7x | `true` |
| `PLUTAINER_EXTRA_ARGS` | Extra arguments appended to the launch command | unset |
| `PLUTAINER_AUTO_UPDATE` | `false` skips update checks at startup | `true` |
| `PLUTAINER_HEALTHCHECK` | `false` disables the healthcheck | `true` |
| `PLUTAINER_SKIP_SEED` | `true` skips seeding default configs | `false` |
| `PLUTAINER_USE_RAW_CONFIGS` | `true` puts cfg files directly at the engine path instead of `app/configs/` — see [Volumes & configs](volumes-and-configs.md#raw-configs-mode) | `false` |
| `PLUTAINER_LOG_SYMLINKS` | `false` disables the `app/logs/` symlink watcher | `true` |
| `PLUTAINER_LOG_POLL_INTERVAL` | Seconds between log watcher polls | `2` |
| `PLUTAINER_LOG_MAX_SIZE` | Rotate a game log once it reaches this size. Accepts `64M`, `1G`, or plain bytes. `0` disables rotation | `64M` |
| `PLUTAINER_LOG_KEEP` | How many rotated copies to keep. `0` truncates without keeping one | `1` |

> **Don't set `rcon_password` through `PLUTAINER_EXTRA_ARGS`.** Plutainer can't read it back from there, so `rcon-cli` and IW4MAdmin won't find it. Use `PLUTAINER_RCON_PASSWORD` or the config file.

## Game-specific

These only apply to one engine family.

| Variable | Description | Applies to |
| --- | --- | --- |
| `PLUTO_SERVER_KEY` | **Required.** Key from <https://platform.plutonium.pw/serverkeys> | Plutonium |
| `PLUTO_MAX_CLIENTS` | Maximum players (other games set this in the cfg) | Plutonium T5 |
| `IW4X_NET_LOG_IP` | `IP:port` for remote netlogging (`g_log_add`) | IW4x |
| `PLUTAINER_COD4X_AUTH_TOKEN` | Masterserver token. Without one the server runs but stays unlisted | CoD4x |
| `PLUTAINER_COD4X_AUTHORIZE_MODE` | `sv_authorizemode` used when no token is set (default `-1`) | CoD4x |
| `PLUTAINER_DEDICATED` | `dedicated` value: `2` public, `1` LAN (default `2`) | CoD4x |
| `PLUTAINER_RCON_WHITELIST` | Extra addresses allowed to send RCON, comma separated. See [IW4MAdmin](iw4madmin.md) | T5, T6 |
| `PLUTAINER_RCON_WHITELIST_GATEWAY` | `false` stops auto-whitelisting the Docker gateway (default `true`) | T5, T6 |

## Ports

| Game | Default |
| --- | --- |
| t4, t5, iw4x, cod4x | 28960 |
| t6 | 4976 |
| iw5 | 27016 |
| t7x | 27017 |

Publish as **UDP**. IW4x additionally wants TCP published if you host mods, for modlist metadata:

```yaml
ports:
  - "28960:28960/udp"
  - "28960:28960/tcp"   # IW4x mod hosting only
```

## Legacy variables

The `PLUTO_*` / `IW4X_*` / `ALTER_*` names from the v1 image are **not accepted** and are silently ignored. Three survive because they only ever applied to one family: `PLUTO_SERVER_KEY`, `PLUTO_MAX_CLIENTS`, `IW4X_NET_LOG_IP`.

Upgrading from v1? See [MIGRATION.md](../MIGRATION.md). Plutainer detects a v1 volume or v1 variables and refuses to start with instructions rather than silently doing the wrong thing.
