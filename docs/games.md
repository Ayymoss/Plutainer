# Games

What each game needs from you, and what Plutainer supplies. Find your game, check the three columns, done.

## At a glance

| Game | `PLUTAINER_GAME` | Server key? | Default port | Config files seeded |
| --- | --- | --- | --- | --- |
| World at War | `t4mp` `t4sp` | yes | 28960 | `server.cfg`, `server_zm.cfg`, `server_coop.cfg` |
| Black Ops | `t5mp` `t5sp` | **yes, must be valid** | 28960 | `dedicated.cfg`, `dedicated_sp.cfg` |
| Black Ops II | `t6mp` `t6zm` | yes | 4976 | `dedicated.cfg`, `dedicated_zm.cfg` |
| Modern Warfare 3 | `iw5mp` | yes | 27016 | `server.cfg` |
| Modern Warfare 2 | `iw4x` | no | 28960 | `server.cfg`, `serverlan.cfg`, `partyserver.cfg`, `partyserverlan.cfg` |
| Black Ops III | `t7x` | no | 27017 | `server.cfg`, `server_zm.cfg`, `server_cp.cfg` |
| Modern Warfare | `cod4x` | token, to be listed | 28960 | `server.cfg` |

`PLUTAINER_CONFIG_FILE` must name one of the seeded files, or a config you place in `app/configs/` yourself. Get it wrong and the container refuses to start with a hint listing what it found — including case-only mismatches like `Server.cfg` vs `server.cfg`.

The `sp` tags are how Plutonium runs zombies/co-op: **T4 zombies is `t4sp`** with `server_zm.cfg`, **T5 zombies is `t5sp`** with `dedicated_sp.cfg`.

## What goes in the gamefiles mount

Mounted read-only at `/home/plutainer/gamefiles`. One copy can be shared by any number of servers.

### Plutonium (T4, T5, T6, IW5)

That game's base install. Plutonium's updater fetches its own binaries into `app/runtime/plutonium/` on first start (~500 MB).

### IW4x

A stock MW2 install: `main/`, `zone/english/`, `zone/dlc/`, `binkw32.dll`, `localization.txt`, `mss32.dll`.

On first start `iw4x-launcher` fetches another 1–2 GB into `app/runtime/gamefiles/` — `iw4x.exe`, `iw4x.dll`, `zonebuilder.exe`, the `iw4x/` asset directory, all of `zone/patch/` and `zone/zonebuilder/`, and the DLC fastfiles. That download persists across container recreation.

`zone/patch/` and `zone/zonebuilder/` belong entirely to the launcher — copies in your mount are ignored, so a slimmed install is fine. Client-only assets (`main/video/`, `logo.bmp`, `splash.bmp`) are unused; [`mxve/shrink-iw4x`](https://github.com/mxve/shrink-iw4x) strips those and the media inside `main/*.iwd`, taking a full install from ~15 GB to ~6 GB.

> **Never put your own files in `zone/patch/` or `zone/zonebuilder/`.** A *symlink* there stops the launcher extracting at all, which silently disables updates. Custom scripts and assets go in `userraw/`, which the updater never touches.

### T7x

BO3 server files: `BlackOps3_UnrankedDedicatedServer.exe`, `zone/`, `machinecfg`, `codlogo.bmp`, and the `steam_api64` / `steamclient64` / `tier0_s64` / `vstdlib_s64` DLLs. Plutainer downloads `t7x.exe` itself and re-fetches only when upstream is newer.

### CoD4x

**Only `main/` and `zone/`.** The client binaries (`iw3mp.exe`, `iw3sp.exe`, `binkw32.dll`, `d3dx9_34.dll`, `mss32.dll`, the bitmaps) are never read by a dedicated server and can be deleted from your mount.

Plutainer ships the server binary and the two assets a stock install lacks — `cod4x_patchv2.ff` and `jcod4x_00.iwd` — so nothing is downloaded at runtime.

## Per-game notes

### T5 (Black Ops)

**A placeholder key will not work.** T4, T6 and IW5 start and play with any key string; T5 does not. It pulls `online_tu14_mp_english.wad` through Plutonium's authenticated service, so with an invalid key the log loops:

```
Error: Unable to fetch file online_tu14_mp_english.wad.
Early out of maprotate, waiting for WAD!
```

The server process runs, binds its port, and never loads a map — a client sees *"Server is not running a map"*. It looks like a broken server; it's an unauthenticated key. Use a real one from <https://platform.plutonium.pw/serverkeys>.

T5 also only answers status queries from localhost, so external query tools see nothing even when it's perfectly healthy. Plutainer's healthcheck runs inside the container, so it is unaffected.

### T7x (Black Ops III)

Launches with `-headless`, which is what removes the need for a virtual display — without it the server hangs on window creation and never binds its port. `-dedicated` is passed separately and is also required.

`PLUTAINER_MOD` here is a **Steam Workshop ID**, not a folder name.

### CoD4x (Modern Warfare)

Multiplayer only. This is the one family that does **not** run under Wine: upstream ships a native Linux server, and Plutainer runs it directly.

**A public server needs a masterserver token.** It isn't a Plutonium-style key — the server starts and plays without one — but without it CoD4x cannot register with the master:

```
Can not register server on the masterserver. Server needs to provide a valid token in cvar sv_authtoken.
```

An unregistered server **never appears in the in-game server browser**, so in practice nobody finds it; only players you give the address to can connect directly. Host migration also requires one.

Get a token from <http://cod4master.cod4x.ovh> and pass it as `PLUTAINER_COD4X_AUTH_TOKEN`. The engine expects exactly **32 characters**. With no token set, Plutainer passes `sv_authorizemode -1` so the server still runs rather than refusing to start.

**RCON passwords must be at least 8 characters.** Shorter ones are refused with `No rconpassword set on server or password is shorter than 8 characters`, which reads like a wrong password rather than a too-short one.

**The server self-updates.** CoD4x rewrites its own binary in `app/runtime/gamefiles/`, which is why Plutainer copies it there rather than symlinking it out of the image. Tested behaviour:

- A build the updater fetched is **kept** across container restarts.
- If a newer Plutainer image ships a newer pinned build, that one is restaged — briefly downgrading a self-updated binary, which the updater then corrects on the next start. Set `PLUTAINER_AUTO_UPDATE=false` to pin whatever is in your volume.
- A stale `autoupdate.lock` left behind by a killed container is harmless; startup time is unaffected.

### IW4x (Modern Warfare 2)

Four seeded configs: `server.cfg` is the normal dedicated one, the `partyserver*` pair run lobby mode from playlists, and the `*lan` variants are LAN mode.

Upstream ships `sv_maprotation` commented out, which would leave `+map_rotate` with nothing to load, so Plutainer's copy of `server.cfg` carries a stock-MW2 rotation under an `// Added by Plutainer` comment. Edit it freely, or set `PLUTAINER_MAP_ROTATE=false` and drive maps from a playlist.

## Architecture support

`linux/amd64` and `linux/arm64` are both published, with two exceptions:

- **IW4x does not work on arm64.** Upstream publishes `x86_64` binaries only, so the arm64 image builds the launcher from source, and that build is currently broken ([iw4x/launcher#76](https://github.com/iw4x/launcher/issues/76)). It refuses to start and says why. It will work again automatically once upstream builds.
- **CoD4x is amd64-only, permanently.** Its server is a 32-bit x86 Linux binary, which cannot execute on arm64 at all.

Plutonium and T7x work on both. If an arm64 build fails outright, `:latest` publishes amd64-only rather than being held back — check with `docker manifest inspect ghcr.io/ayymoss/plutainer:latest` before upgrading an arm64 host.

## Bundled configs

On first start Plutainer copies a working config into `app/configs/`. Existing files are **never** overwritten, so your edits survive every image update. Opt out entirely with `PLUTAINER_SKIP_SEED=true`.

| Game | Source |
| --- | --- |
| T4 | [xerxes-at/T4ServerConfigs](https://github.com/xerxes-at/T4ServerConfigs) |
| T5 | [xerxes-at/T5ServerConfig](https://github.com/xerxes-at/T5ServerConfig) |
| T6 | [xerxes-at/T6ServerConfigs](https://github.com/xerxes-at/T6ServerConfigs) |
| IW5 | [xerxes-at/IW5ServerConfig](https://github.com/xerxes-at/IW5ServerConfig) |
| T7x | [Dss0/t7-server-config](https://github.com/Dss0/t7-server-config) — includes the lobby scripts `sv_lobby_mode` needs |
| IW4x | [iw4x/iw4-server-configs](https://github.com/iw4x/iw4-server-configs) |
| CoD4x | Maintained in this repo, adapted from [matracey/docker-cod4](https://github.com/matracey/docker-cod4) |

These are vendored into the repository under `seed-configs/`, not downloaded at build time, so a build can't break because someone renamed a repo — which happens. Each game's `seed-configs/<game>/SOURCE` records the exact upstream commit.

Plutainer makes three changes to what upstream ships, each marked with a `[Plutainer]` comment:

- **All passwords blanked** — `rcon_password`, `g_password`, `sv_privatePassword`. A password shipped in a public image is a password everyone knows: as an RCON password it invites strangers in, and as a *join* password it locks your own players out.
- **Placeholder `rconWhitelistAdd` entries commented out** — they pointed at someone else's LAN and blocked the admin tools you'd actually connect. See [IW4MAdmin](iw4madmin.md#the-whitelist-rule-that-catches-everyone).
- **`rcon_localhost_bypass` forced to `1`** where the cvar exists, so `rcon-cli` works from inside the container.

Maintainers: update them with `tools/refresh-seeds.sh` (all games) or `tools/refresh-seeds.sh t6 iw4x` (a subset), then commit the diff.
