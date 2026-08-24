# Configuration

Every setting is an environment variable. Only two are required.

## Required

| Variable | Description |
| --- | --- |
| `PLUTAINER_GAME` | Which game — `t4mp`, `t4sp`, `t5mp`, `t5sp`, `t6mp`, `t6zm`, `iw5mp`, `iw4x`, `t7x`, `cod4x`, `7dtd`, `cs2`, `l4d2`, `hl2dm`, `nebula` |
| `PLUTAINER_CONFIG_FILE` | Which config to run, e.g. `dedicated_zm.cfg`. Must exist in `app/configs/` — Plutainer seeds one on first start ([names per game](games.md)). Optional for SteamCMD games and Nebula, which default to their own config name |

Plutonium games (`t4*`, `t5*`, `t6*`, `iw5mp`) also require `PLUTO_SERVER_KEY`.

## Common

| Variable | Description | Default |
| --- | --- | --- |
| `PLUTAINER_PORT` | Network port | [per game](games.md) |
| `PLUTAINER_RCON_PASSWORD` | Sets `rcon_password` in your config at startup. Opt-in — unset leaves your config untouched | unset |
| `PLUTAINER_SERVER_NAME` | Name shown in Plutainer's startup logs. On the SteamCMD games it also sets the real server name (7DTD's XML `ServerName`, Source's `hostname`); CoD engines still use `sv_hostname` in their cfg | per family |
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
| `PLUTAINER_LOG_ROTATE` | `false` turns rotation off entirely. The SteamCMD games set this themselves, because copy-truncate is only safe against a writer that opens its log in append mode ([why](healthcheck.md)) | `true`, `false` on SteamCMD games |

> **Don't set `rcon_password` through `PLUTAINER_EXTRA_ARGS`.** Plutainer can't read it back from there, so `rcon-cli` and IW4MAdmin won't find it. Use `PLUTAINER_RCON_PASSWORD` or the config file.

## Game-specific

These only apply to one engine family.

| Variable | Description | Applies to |
| --- | --- | --- |
| `PLUTO_SERVER_KEY` | **Required.** Key from <https://platform.plutonium.pw/serverkeys> | Plutonium |
| `PLUTO_MAX_CLIENTS` | Maximum players (other games set this in the cfg) | Plutonium T5 |
| `IW4X_NET_LOG_IP` | `IP:port` for remote netlogging (`g_log_add`) | IW4x |
| `PLUTAINER_COD4X_AUTH_TOKEN` | Masterserver token, 32 characters, from <http://cod4master.cod4x.ovh>. Without one the server runs but is never listed in the server browser | CoD4x |
| `PLUTAINER_COD4X_AUTHORIZE_MODE` | `sv_authorizemode` used when no token is set (default `-1`) | CoD4x |
| `PLUTAINER_DEDICATED` | `dedicated` value: `2` public, `1` LAN (default `2`) | CoD4x |
| `PLUTAINER_RCON_WHITELIST` | Extra addresses allowed to send RCON, comma separated. See [IW4MAdmin](iw4madmin.md) | T5, T6 |
| `PLUTAINER_RCON_WHITELIST_GATEWAY` | `false` stops auto-whitelisting the Docker gateway (default `true`) | T5, T6 |
| `PLUTAINER_STEAM_BETA` | Steam branch to install instead of the default, e.g. `latest_experimental` | SteamCMD games |
| `PLUTAINER_STEAM_BETA_PASSWORD` | Password for a private Steam branch | SteamCMD games |
| `PLUTAINER_STEAM_VALIDATE` | `true` adds `validate` to the SteamCMD update, re-checking every file. Slow; use after a corrupted install | SteamCMD games |
| `PLUTAINER_STEAM_ATTEMPTS` | How many times to retry a failed SteamCMD install. Its first contact in a fresh container is unreliable, so more than one is the norm | SteamCMD games (default `3`) |
| `PLUTAINER_STEAM_APP_ID` | Override the Steam app ID. Escape hatch for testing; the built-in value is normally right | SteamCMD games |
| `PLUTAINER_MAX_CLIENTS` | Player slots | Source games |
| `PLUTAINER_START_MAP` | Map to boot into | Source games |
| `PLUTAINER_CS2_GSLT` | Game Server Login Token, from <https://steamcommunity.com/dev/managegameservers>. Without it the server runs but never appears in the browser | CS2 |
| `PLUTAINER_CS2_GAME_ALIAS` | Game mode alias, e.g. `competitive`, `casual`, `deathmatch` (default `competitive`) | CS2 |
| `PLUTAINER_CS2_LAN` | `1` restricts the server to LAN (default `0`) | CS2 |
| `PLUTAINER_NEBULA_VERSION` | Nebula release: `latest` checks for the current stable release at every start; use an exact version such as `0.9.22` to pin it | Nebula (default `latest`) |
| `PLUTAINER_NEBULA_MODS` | Declarative comma-separated Thunderstore packages as `Owner-Package[:version]` (or unambiguous `Owner/Package[:version]`); omitted versions and `:latest` update at every start, while an exact version pins that mod | Nebula |
| `PLUTAINER_NEBULA_SAVE` | Save name to load (without `.dsv`). Unset loads the newest save, or creates one on a fresh volume | Nebula |
| `PLUTAINER_NEBULA_NEW_GAME` | `true` starts a new game from `nebulaGameDescSettings.cfg` even when saves exist | Nebula |
| `PLUTAINER_NEBULA_UPS` | Fixed simulation UPS; Nebula accepts 5–240 | Nebula |
| `PLUTAINER_NEBULA_SERVER_PASSWORD` | Password players must provide to join | Nebula |
| `PLUTAINER_NEBULA_REMOTE_PASSWORD` | Enables Nebula's authenticated `/server` chat commands and sets their password | Nebula |
| `PLUTAINER_NEBULA_AUTO_PAUSE` | `true` pauses when no players are connected; `false` keeps simulating | Nebula |

## Ports

| Game | Default |
| --- | --- |
| t4, t5, iw4x, cod4x | 28960 |
| t6 | 4976 |
| iw5 | 27016 |
| t7x | 27017 |
| 7dtd | 26900 |
| cs2 | 27015 |
| l4d2 | 27015 |
| hl2dm | 27015 |
| nebula | 8469/TCP |

CoD games use **UDP**. IW4x additionally wants TCP published if you host mods, for modlist metadata:

```yaml
ports:
  - "28960:28960/udp"
  - "28960:28960/tcp"   # IW4x mod hosting only
```

7DTD uses TCP and UDP on its base port plus the next three UDP ports. With the default:

```yaml
ports:
  - "26900:26900/tcp"
  - "26900-26903:26900-26903/udp"
```

Its Telnet RCON console uses TCP port 8081. Publish that port only on a private host address. Loopback is safest for host-side tools; a containerized IW4MAdmin needs a stable private host address it can reach:

```yaml
ports:
  - "${SEVENDTD_TELNET_BIND:-127.0.0.1}:8081:8081/tcp"
```

Do not bind Telnet to a public interface. Set `SEVENDTD_TELNET_BIND` to a private LAN, VPN, or dedicated Docker bridge address and use that same address in the management client.

Nebula uses one TCP port:

```yaml
ports:
  - "8469:8469/tcp"
```

## Legacy variables

The `PLUTO_*` / `IW4X_*` / `ALTER_*` names from the v1 image are **not accepted** and are silently ignored. Three survive because they only ever applied to one family: `PLUTO_SERVER_KEY`, `PLUTO_MAX_CLIENTS`, `IW4X_NET_LOG_IP`.

Upgrading from v1? See [MIGRATION.md](../MIGRATION.md). Plutainer detects a v1 volume or v1 variables and refuses to start with instructions rather than silently doing the wrong thing.
