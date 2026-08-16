# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Plutainer is a Docker image for running Plutonium, IW4x, Alterware and CoD4x dedicated game servers (Call of Duty titles: T4/WaW, T5/BO1, T6/BO2, IW5/MW3, IW4x/MW2, T7x/BO3, CoD4x/CoD4). It uses Wine on Arch Linux to run the Windows game server binaries, configured entirely via environment variables. CoD4x is the exception: upstream ships a native Linux server, so it runs directly with no Wine (and is therefore amd64-only — the binary is 32-bit x86).

## Documentation layout

User-facing docs are split by concern; `README.md` is a landing page and should stay short. Put new material in the page that owns the topic rather than growing the README:

| File | Owns |
| --- | --- |
| `README.md` | What Plutainer is, supported games, links out |
| `docs/quickstart.md` | First server, start to finish |
| `docs/games.md` | Per-game: required game files, keys, config names, ports, quirks, arch support, bundled configs |
| `docs/configuration.md` | Environment variable reference |
| `docs/volumes-and-configs.md` | Volume layout, config symlink flow, raw mode, logs, permissions |
| `docs/rcon.md` | Passwords, `rcon-cli`, who may send RCON |
| `docs/iw4madmin.md` | Sidecar setup, parser table, the T5/T6 whitelist explanation |
| `docs/healthcheck.md` | What healthy means, restart behaviour, autoheal |
| `docs/troubleshooting.md` | Symptom-first FAQ |
| `examples/*.yml` | Copy-paste compose files |
| `MIGRATION.md` | v1 → v2 |

`docs/` and `examples/` are excluded from the build context in `.dockerignore`.

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

`main` is v2 and publishes every tag; the `v2-layout` branch no longer exists.

- `:latest` and `:v2` — built from `main`, multi-arch, identical content. `:v2` exists so existing compose files keep working.
- `:edge` — **amd64 only**, pushed from the amd64 build job without waiting on arm64. For iterative testing; pulling it on arm64 fails with a platform mismatch.
- `:sha-<short>` on every build, `:<tag>` on releases, `:pr-<n>` on PRs.

Tag logic lives in `metadata-action` in the `merge` job.

## Architecture support

amd64 is required. **arm64 is best-effort** (`optional: true` + `continue-on-error` in the build matrix): if it fails, amd64 still publishes and `merge` emits a `::warning::` and job-summary note. Only a missing *amd64* digest blocks a publish.

`iw4x/launcher` publishes `x86_64` binaries only, so `Dockerfile` downloads the prebuilt binary while `Dockerfile.arm64` compiles it, and the build2 toolchain, from source. `cpp-builder` exists solely for that; everything else arm64 needs (Wine, `plutonium-updater`, the T7x path) builds fine.

**Current state: iw4x does not work on arm64.** The source build fails and the image ships `/home/plutainer/.plutainer/iw4x-launcher.unavailable` instead of the binary. Plutonium (t4/t5/t6/iw5) and Alterware (t7x) are unaffected on both architectures. Background: iw4x/launcher#76.

**cod4x is amd64-only by nature**, not by build failure: upstream's native Linux server is a 32-bit x86 ELF, which cannot execute on arm64 at all. The `cod_update_cod4x` hook refuses with an explanation.

**The SteamCMD family is amd64-only**: Valve ships SteamCMD as x86_64 binaries only, so `Dockerfile.arm64` does not install it. `steamentry.sh` tests `-x` on `steamcmd.sh` and `hold_indefinitely`s if absent — a capability check, not an arch check, so the family starts working on arm64 the day an arm64 SteamCMD exists, with no code change.

**Degradation.** `Dockerfile.arm64` lets the launcher build fail, writing the `.unavailable` marker in its place. Stage 3 copies `/out/` as a **directory**, not a file — a file `COPY` of a missing path aborts the build, which is the coupling being avoided; the marker also keeps the directory non-empty. The `cod_update_iw4x` hook tests `-x` on the binary and `hold_indefinitely`s if absent. That is a capability check, not an arch check, so iw4x starts working again as soon as an image ships a binary, with no code change.

**`IW4X_LAUNCHER_REF` is load-bearing — do not remove it.** Both Dockerfiles fetch the launcher inside a `RUN`, so the layer cache key never changes on its own and upstream changes stay invisible until eviction. CI resolves the upstream ref (release tag for amd64, commit SHA for arm64) and passes it purely to key the cache. This matters most on arm64, where the `|| { … }` fallback makes the step exit 0 on failure, so a failed build caches as a success and would keep shipping the marker indefinitely.

**Both Dockerfiles carry their own seed-configs block — keep them in sync.** Both are now a single `COPY seed-configs/`; the files are vendored (see below), not fetched at build time.

## Architecture

Everything runs as the `plutainer` user from `/home/plutainer/.plutainer`. All entry scripts run with `set -euo pipefail`.

`scripts/` is copied into that directory wholesale, so the repo layout and the in-image layout are the same thing:

```
scripts/
  entrypoint.sh          # dispatcher
  healthcheck.sh         # dispatches on family
  rcon-cli               # dispatches on protocol
  log-watcher.sh
  migrate-v1-to-v2.sh
  games/                 # codentry.sh, steamentry.sh — one per family
  lib/                   # core.sh, fs.sh, cod.sh, steam.sh
  protocols/             # one module per wire protocol
```

**There are exactly two families, and they are platforms rather than engines.** `cod` is everything Plutainer installs and runs itself from game files you supply; `steam` is everything SteamCMD installs. Engine variation (plutonium / iw4x / alterware / cod4x, unity / srcds) lives *below* the family as a table field, because it does not change how Plutainer treats the server — a Plutonium T6 and a CoD4x server differ far less from each other than either does from a SteamCMD install.

Both families have the same shape: one entry script, one game table, and hooks resolved most-specific-first. Adding a game to either should touch that family's file and nothing else, and never add a branch to `entrypoint.sh`, `healthcheck.sh` or `rcon-cli`.

1. **`entrypoint.sh`** — Top-level dispatcher. Sources `lib/core.sh`, calls `detect_game_type` (requires `PLUTAINER_GAME`), `check_volume_version` (refuses v1 volumes), then `exec`s the family-specific entry script. On any failure: `hold_indefinitely` (sleep infinity) instead of exiting, to avoid restart loops.

   **T5/T6 gate unauthenticated queries on the RCON whitelist — this is what makes or breaks IW4MAdmin.** IW4MAdmin's T5/T6 parsers open with `getinfo` (unlike its BOIII, T4 CO-OP/ZM and TeknoMW3 parsers, which set `RConGetInfo = null`). On T5/T6, `getinfo`/`getstatus` are refused off-loopback unless the sender is whitelisted, and an *empty* whitelist does **not** mean "everyone" for those queries, though it does for RCON commands. Measured on T6 zombies, off-loopback:

   | whitelist state | RCON | `getinfo` |
   | --- | --- | --- |
   | upstream placeholder IPs | blocked | blocked |
   | empty | works | blocked |
   | gateway whitelisted | works | works |

   So a sidecar admin tool completes the RCON handshake (`rcon <pw> version`, `sv_running` both answer) and then fails on repeated unanswered `getinfo`, aborting startup. The sender's address is this container's *bridge gateway*, which Docker assigns at run time, so it cannot be baked into a config file — `resolve_rcon_whitelist_args` detects it and appends `+rconWhitelistAdd`. T4 and IW5 answer queries regardless and are deliberately skipped, since adding an entry would newly restrict their RCON for no gain; iw4x and t7x have no such command.

2. **`games/codentry.sh`** — Entry script for the whole `cod` family. **One script serves all ten games**; per-game facts live in the table in `lib/cod.sh` and per-engine steps are hooks it defines, resolved most-specific-first as `cod_<hook>_<game>` → `cod_<hook>_<base game>` → `cod_<hook>_<engine>`. Adding a game is a table row plus whatever hooks genuinely differ. If a game ever needs a `case` block in the entry script, the abstraction has slipped.

   The step order is load-bearing and was arrived at the hard way: **stage** (mirror the read-only game files, because the engine writes next to them) → **update** (fetch server binaries) → **auto-lift** (a real cfg the user left at the engine path is the strongest signal of intent, so it moves into `configs/` *before* seeding, or the seed's `cp -n` would paper over it) → **seed** → **link** (fan `configs/*.cfg` out to the engine and mod dirs) → **validate** → **launch**.

   Hooks are checked at startup with `plutainer_require_hooks`, so a mis-named or missing one fails immediately with the list of names that were tried, instead of silently skipping a step. That check is not theoretical: during the refactor a comma-separated suffix list was passed where an array was wanted, and every server died with no output at all until `plutainer_hook` was made to say what it could not find.

   **Plutonium (t4/t5/t6/iw5).** Plutonium server entrypoint. Symlinks game files from the read-only gamefiles mount, runs `plutonium-updater`, seeds bundled configs into the SOT location, fans out symlinks from `app/configs/` to the engine and (if `PLUTAINER_MOD` is set) the mod config dir, calls `ensure_config_present` (auto-lift + refusal), then `launch_game wine ...` (30s exit-throttle wrapper).

   **IW4x.** IW4x server entrypoint. Same shape: symlinks game files, runs `iw4x-launcher`, seeds bundled configs, fans out config symlinks (engine + optional mod dir), validates, `launch_game wine iw4x.exe`. Seed bundle is `iw4x/iw4-server-configs` with `cfg_root_rel="userraw"`, so its top-level `userraw/*.cfg` lift into `configs/` and the playlist `*.info` files stay under `runtime/gamefiles/userraw/`. `tools/refresh-seeds.sh` appends a stock-MW2 `sv_maprotation` to the seed's `server.cfg` — upstream ships it commented out there, unlike every other seed here, which would leave `+map_rotate` with nothing to load on a first run. (`serverlan.cfg` already carries an active one upstream, and the guard skips it; `partyserver*.cfg` run lobby mode off playlists and are left alone.) The append is committed into the vendored file, so what ships is what is in the repo.

   **The launcher has no `--path` flag.** It canonicalises `/proc/self/exe` and uses its own directory as the installation root, ignoring cwd. The entrypoint therefore `cp`s the binary into `runtime/gamefiles/` and runs it from there, putting the install root inside the volume. It must be a real copy — `canonical()` resolves a symlink back to `.plutainer/`, an image layer, and the ~800MB it fetches would be re-downloaded on every container recreate.

   Launcher outputs, relative to that root: `iw4x.exe`, `iw4x.dll`, `zonebuilder.exe`, `steam.exe`, `steam_api64.dll`, `iw4x/` (incl. `iw4x_0{0..5}.iwd`), `zone/patch/*.ff`, `zone/zonebuilder/*.ff`, `iw3/zone/dlc/*.ff` (written to `zone/dlc/` — the manifest prefix is stripped), and `cache/iw4x.db`, the update-check marker. Its `clean()` only prunes files tracked in its own DB, so our symlinks are untouched.

   **Never pre-populate `zone/patch/` or `zone/zonebuilder/`.** The rawfiles component unpacks `release.zip` by writing straight through each destination path, so a symlink at the directory *or* the leaf resolves into the read-only mount and aborts the whole run:

   ```
   [E] failed to extract file: zone/patch/iw4_credits_load.ff
   ```

   That also skips `sync_dlc`/`sync_helper` and leaves rawfiles unstamped, so every later start fails identically and client updates never apply. Nothing is lost by ceding both: the launcher's 56 `zone/patch` entries are a superset of a full MW2 install's 39, and `zone/zonebuilder` is the same lone `zonebuilder_minigun.ff`.

   `zone/english` and `zone/dlc` *are* mirrored. Every component other than rawfiles stages downloads and renames into place, which replaces a symlink rather than writing through it, so mirroring is safe there — and useful, since the reconciler hash-validates existing host fastfiles and skips re-downloading matches.

   A launcher failure is fatal only on first run (no `iw4x.exe` yet); otherwise it warns and starts the existing install.

   **Alterware (T7x).** Alterware (T7x/BO3) entrypoint. Symlinks game files, uses `wget -N` (timestamping) to fetch `t7x.exe` only when upstream is newer, seeds Dss0/t7-server-config bundle, fans out config symlinks, `launch_game wine t7x.exe -headless -dedicated ...`. No mod dir (alterware MOD is a Steam Workshop ID).

   **`-headless` is what removes the X dependency — do not drop it.** t7x's `console` component calls `Sys_CreateConsole` and builds a real Win32 console *window* unless `game::is_headless()`; with `-headless` it attaches to the parent console and `fputs`es to stdout instead. Without it, under Wine with no display, the process hangs at `err:winediag:nodrv_CreateWindow` and never binds its port. The image ships no X server at all now; the flag is the only thing standing in for one. `-dedicated` is separate and still required (it forces `is_server` rather than relying on the "server exe present, client exe absent" fallback).

   **CoD4x.** CoD4x (Call of Duty 4) entrypoint. MP only. Same shape as the rest: mirrors `main/` and `zone/english/` from the read-only mount, stages the server binary and CoD4x assets, seeds configs, fans out config symlinks, validates, `launch_game ./cod4x18_dedrun`.

   **The only family that does not use Wine.** Upstream publishes a native Linux dedicated server, `cod4x18_dedrun`, and it is a plain console app — no window, so no display either. The Windows build was tested and dies at `nodrv_CreateWindow` exactly as T7x does without `-headless`, which would have meant reintroducing Xvfb. The native binary was the risk to check instead: it is a 32-bit x86 ELF, and 32-bit Linux socket code is what Docker's seccomp blocks via `socketcall(2)` — the very reason this image sits on an Arch pure-WoW64 base. Measured: it opens its UDP and TCP sockets fine. Cost is `lib32-glibc` + `lib32-gcc-libs` from multilib.

   **Therefore CoD4x is amd64-only** — a 32-bit x86 ELF cannot run on arm64 at all. The entrypoint checks for the binary and `hold_indefinitely`s with an explanation, the same capability-check (not arch-check) pattern the iw4x hook uses.

   The binary is **copied** into the volume, not symlinked: CoD4x self-updates in place, which would fail against a read-only image layer, and a copy means an updated build survives container recreation. Same reasoning as the IW4x launcher, different cause.

   **Two assets come from the *client* release, and are not optional.** The server release ships only binaries and plugin zips; the server refuses to load any map without `zone/english/cod4x_patchv2.ff`, which upstream publishes under `CoD4x_Client_pub`. `jcod4x_00.iwd` is referenced too. Nothing else from the client is used — `cod4x_021.dll`, `launcher.dll`, `core` and `mss` are client-side, and `cod4x_ambfix.ff` is referenced zero times by a running server. Both refs are pinned (`COD4X_SERVER_REF`, `COD4X_CLIENT_REF`) rather than tracking latest: the last server release is 2022 and the binary self-updates anyway.

   Without `PLUTAINER_COD4X_AUTH_TOKEN` the launch passes `sv_authorizemode -1`; the server runs and is fully playable, just unlisted on the master.

3. **`games/steamentry.sh`** — SteamCMD family entrypoint. **One script serves every game in the family**; per-game differences live in a table plus optional hooks in `lib/steam.sh`, so adding a game is a table row, not a new entry script. If a game ever needs a `case` block here, the abstraction has slipped.

   Shape matches the CoD entry scripts deliberately: resolve the game, put the server on disk, seed a config on first run, apply the generic `PLUTAINER_*` settings, validate, launch. Differences: no gamefiles mount, no Wine, and whether configs get symlinked into the install is per game (`stage` hook) rather than family-wide.

   **Install and persistent data are deliberately separate.** `app/runtime/steam/<game>/` is SteamCMD's, and it may replace anything in there on update; `app/runtime/gamedata/<game>/` holds worlds, saves and logs and SteamCMD never touches it.

   **SteamCMD's first contact is unreliable, so `app_update` is retried.** Its first run downloads its own client and re-execs; an `+app_update` issued before that settles fails with `Failed to install app '<id>' (Missing configuration)`. Measured on both 7DTD and HL2:DM in fresh containers, with the immediately following attempt succeeding. Pre-bootstrapping with `steamcmd.sh +quit` first — at runtime or at image build time — was tried and did **not** reliably prevent it. Three attempts, 5s apart; a genuinely broken install fails identically every time and still ends in the refusal.

   **Not pre-bootstrapped at build time.** `steamcmd.sh +quit` in the Dockerfile would pull a few hundred MB of Steam client into `$HOME` that every CoD-only user carries forever — the same reason 340 MB of Xvfb was removed. The retry above is the trade.

   **Source 1 servers do not answer on loopback.** Measured on HL2:DM and L4D2 (CS2, oddly, does answer on loopback — another reason to try both rather than encode it): an identical A2S query times out on `127.0.0.1` and replies immediately on the container's own address, with the server healthy throughout; its RCON socket likewise `LISTEN`s on the container IP, not `0.0.0.0`. `plutainer_query_hosts` returns loopback then the container address, and both `healthcheck.sh` and `rcon-cli` try them in order rather than encoding which engine behaves which way.

   **A depot-shipped config must be reclaimed, not respected.** `link_configs` refuses to replace a *real* file at the engine path, because for the CoD families that is the strongest signal of user intent. Inside a SteamCMD install it means the opposite: the directory is Steam's, so a real file is whatever the depot shipped and gets restored on the next update anyway. CS2 exposed this — its depot ships a 33-byte `game/csgo/cfg/server.cfg` reading `// Defaults in server_default.cfg`, so the fan-out skipped it with a warning and the server ran on stock settings (hostname, hibernation and logging all ignored) while `app/configs/server.cfg` sat there looking correct. `steam_reclaim_depot_configs` moves the depot's copy to `<name>.depot-original` first. Measured before/after: `hostname = Counter-Strike 2` → `hostname = Plutainer CS2 Test`, and the A2S name a browser shows changed with it.

   **`STEAM_WORKDIR`.** CS2 is launched through the depot's own `game/cs2.sh` from inside `game/`, not the raw `bin/linuxsteamrt64/cs2`, because that wrapper sets up the Steam Runtime library paths the binary is linked against.

   **CS2 needs `-usercon`** or it refuses every RCON connection whatever `rcon_password` says, and the password is passed on the command line as well as written to the config because RCON initialises before `server.cfg` is exec'd. `PLUTAINER_CS2_GSLT` fills the same role as CoD4x's masterserver token.

   **srcds event logs are redirected out of the install.** `log on` writes to `<install>/<game>/logs/`, which SteamCMD owns and which `log-watcher.sh` prunes (an install is tens of thousands of files to walk every 2s). `steam_redirect_srcds_logs` symlinks that directory into `gamedata/<game>/logs`, so the watcher surfaces them in `app/logs/` like every other game.

   **Log rotation is off for this family** (`PLUTAINER_LOG_ROTATE=false`). Copy-truncate is only valid against an O_APPEND writer; a Unity `-logfile` writer keeps its own offset, so truncation would leave a sparse hole and the apparent size would snap straight back over the limit, re-triggering every poll. Unmeasured against a live 7DTD, so the safe failure (an unbounded log, which is what the game does unmanaged) was chosen over a rotation loop. The real fix, when there is time to test it, is `-logfile -` teed through an append-mode fd — which would also put the server in `docker logs`, where it currently prints nothing.

   **Some apps need a multi-phase install — `STEAM_INSTALL_PLATFORMS`.** Valve restricted anonymous Linux installation of L4D2 (app `222860`): *every* depot is flagged `windows`, including the 9.5 GB content one, so a plain `app_update` on Linux fails with `Invalid platform`. Open upstream issue (ValveSoftware/steam-for-linux#11522) which also breaks LinuxGSM, so "it used to work" is true and not a local fault.

   The fix, which [Left4DevOps/l4d2-docker](https://github.com/Left4DevOps/l4d2-docker) also uses, is to run `app_update` once per platform inside one SteamCMD session: force `windows` to fetch the content, then force `linux` and update again with `validate` so the native binaries depot overlays it. The table expresses that as `STEAM_INSTALL_PLATFORMS="windows linux"`; games with an empty value take the normal single-phase path. Verified: the result runs `srcds_linux` (32-bit ELF), no Wine process, and the server reports `os: Linux Dedicated`.

   Its 32-bit ELF is only runnable here for the same reason CoD4x is — the Arch pure-WoW64 base sidesteps Docker's `socketcall(2)` seccomp block.

4. **`lib/`** — The shared library, split so that a CoD change never requires reading the Steam helpers and vice versa. This is the main structural guard against the two platforms bleeding into each other:

    | File | Owns |
    | --- | --- |
    | `core.sh` | Volume paths, family detection, process lifecycle, the hook mechanism, and the dispatchers `healthcheck.sh`/`rcon-cli` use. Sources the other three. |
    | `fs.sh` | `link_files`, `link_dir_contents`, `link_configs` — symlink hygiene, used by both families. |
    | `cod.sh` | The cod game table plus its hooks: game-file staging, updaters, launch arguments, config layout, `rcon_password` parsing/writing, the T5/T6 whitelist. |
    | `steam.sh` | The steam game table plus its hooks: SteamCMD install/update, XML and cfg editing, launch arguments. |

    Audited for coupling: **zero cross-family calls in either direction**. Anything both needed — the symlink helpers — was moved to `fs.sh` instead.

    **Hooks (`plutainer_hook`, `plutainer_require_hooks`).** Both families name per-game behaviour `<family>_<hook>_<suffix>` and try suffixes most-specific-first, so a game inherits its engine's implementation and overrides only what genuinely differs — `steam_launch_args_cs2` exists, but CS2's seed/configure/stage come from `srcds`. That fallback deleted fifteen one-line pass-through functions and makes another Source game a pure table row. Hook names are strings, so `plutainer_require_hooks` verifies the mandatory ones resolve at startup and prints what it tried.

    Both family libraries are always loaded — `healthcheck.sh` and `rcon-cli` dispatch on `GAME_TYPE` at runtime and need either set available. The split is about where code is allowed to live, not about loading less of it.

    **`lib/core.sh`** key helpers:
   - Volume path constants: `PLUTAINER_APP_DIR`, `PLUTAINER_CONFIGS_DIR`, `PLUTAINER_RUNTIME_DIR`, `PLUTAINER_GAMEFILES_DIR`, `PLUTAINER_PLUTONIUM_DIR`, `PLUTAINER_SOURCE_DIR`, `PLUTAINER_STEAM_DIR`, `PLUTAINER_GAMEDATA_DIR`.
   - `hold_indefinitely <msg>`: print the error, then `exec sleep infinity` so the container stays `Up` instead of looping through restarts. Used for any startup validation failure.
   - `launch_game <cmd>...`: wraps the game invocation; on exit, sleeps 30s before letting the script exit, so docker's restart policy throttles to ~1 restart per 30s.
   - `derive_family <game-tag>`: returns `cod` or `steam`, by asking each family whether it knows the tag. Neither list is duplicated here, so adding a game touches one file.
   - `plutainer_hook` / `plutainer_hook_exists` / `plutainer_require_hooks`: the shared hook mechanism, above.
   - `resolve_active_port`: the port the server will actually use, resolved once so the entry script, health check and rcon-cli cannot disagree.
   - `launch_game` / `launch_game_graceful`: see Restart behaviour at the bottom.
   - `plutainer_query_hosts`: loopback, then the container's own address. Uses `ip` rather than `hostname -i` — iproute2 is already a dependency (the T5/T6 gateway detection uses it) while Arch's `hostname` comes from inetutils, which this image does not install.
   - `resolve_config_path` / `resolve_admin_endpoint`: family dispatchers, used by `healthcheck.sh` and `rcon-cli`. Entry scripts call the family functions directly.
   - `detect_game_type`: validates `PLUTAINER_GAME` (no shim — only PLUTAINER_* accepted), sets `GAME_TYPE`/`GAME_NAME`/`BASE_GAME`/`CONFIG_FILE`/`CUSTOM_PORT`/`HEALTHCHECK_FLAG`.
   - `resolve_default_port`, `resolve_engine_config_dir`, `resolve_mod_config_dir`.
   - `resolve_config_layout`: sets `CONFIG_SOT_DIR` and `ALT_CONFIG_DIR` based on `PLUTAINER_USE_RAW_CONFIGS`. Default: SOT = `configs/`, ALT = engine dir. With raw mode on: swapped.
   - `resolve_config_path`: convenience wrapper that resolves the engine dir + layout in one call so healthcheck/rcon-cli only need this.
   - `link_files <src> <dest> <name1>...`: existence-guarded symlink helper; replaces unsafe `ln -sf src/{a,b,c} dest/` bash brace expansion.
   - `link_dir_contents <src_root> <dest_root> <name>`: mirrors `src_root/name` into `dest_root/name`, recreating **every** directory level as a real dir and symlinking only leaf files. Use instead of `link_files` for any dir that must stay writable while also carrying read-only host game files — the engine config dir, or one an updater writes into. A symlinked dir at *any* depth inherits the read-only mount, so mirroring only the top level is not enough. `name` may be nested (`zone/english`) to mirror one subtree and leave its siblings alone; symlinks are replaced at every component of the path, since an older image may have linked a parent. Never overwrites a real file at the destination, so an updater-written copy wins over the host's.
   - `seed_configs <game-key> <asset-root> <cfg-root-rel>`: walks bundled seed, lifts top-level `*.cfg` files inside `cfg-root-rel` into `CONFIG_SOT_DIR`, places everything else under `asset-root`. Idempotent.
   - `link_configs <engine-dir1> [engine-dir2 ...]`: variadic. Fans out symlinks from every `configs/*.cfg` into each engine dir using relative paths. Refuses to overwrite a real (non-symlink) file at engine path (warns instead). Reaps dangling cfg symlinks. No-op when `PLUTAINER_USE_RAW_CONFIGS=true`.
   - `ensure_config_present`: checks that `CONFIG_FILE` exists at `CONFIG_SOT_DIR`. If absent there but present as a real file at the ALT location, moves it (auto-lift). If absent everywhere, prints a refusal with a `find -iname` case-insensitive hint, returns non-zero.
   - `check_volume_version`: refuses v1 volumes with explicit migration instructions; initialises fresh volumes; writes `.plutainer-version=2`.
   - `resolve_rcon_whitelist_args`: builds `+rconWhitelistAdd <ip>` launch args (into `RCON_WHITELIST_ARGS`) from the container's detected default gateway plus `PLUTAINER_RCON_WHITELIST`. **T5/T6 only** — see the IW4MAdmin note under `entrypoint.sh`. Disable the gateway entry with `PLUTAINER_RCON_WHITELIST_GATEWAY=false`.
   - `apply_rcon_password`: writes `PLUTAINER_RCON_PASSWORD` into `CONFIG_SOT_DIR/CONFIG_FILE`. **Opt-in and never destructive** — unset or empty is a no-op, so it can't null out a password the user set by hand. Rewrites the value on an existing `rcon_password` line (keeping its trailing `//` comment) or appends one. Uses python3, not sed: the value is arbitrary user input that would otherwise need escaping against sed's replacement metacharacters. There is deliberately **no default value** — a shipped placeholder would be a known credential on a port anyone can find by scanning for `getstatus` responders. Called by all three entrypoints after `ensure_config_present`.
   - `extract_rcon_password`: parses `rcon_password` from `CONFIG_PATH`. Handles double-quoted, single-quoted, and unquoted values. Strips `//` comments. On failure, prints a structured `[WARN]` (don't block startup) telling the user the accepted forms and not to set the password via `PLUTAINER_EXTRA_ARGS`.

5. **`migrate-v1-to-v2.sh`** — One-shot migration tool, run via `docker run --entrypoint`. Moves `app/gamefiles` → `app/runtime/gamefiles`, `app/plutonium` → `app/runtime/plutonium`, lifts top-level cfg files from known engine config dirs into `app/configs/` and replaces them with relative symlinks, clears stale `app/logs/` entries, writes `.plutainer-version=2`. Supports `--dry-run`.

6. **`log-watcher.sh`** — Background poller started by each entrypoint before `exec wine`. Discovers every `*.log` under `/home/plutainer/app/` (excluding `app/logs/` itself to avoid cycles) and maintains relative symlinks at `/home/plutainer/app/logs/<basename>` pointing at the active one. Active = newest mtime >= container boot time. Agnostic to log name. Symlinks are relative so they resolve the same on host, in this container, or in a sidecar IW4MAdmin container. Disable with `PLUTAINER_LOG_SYMLINKS=false`; poll interval via `PLUTAINER_LOG_POLL_INTERVAL` (default 2s).

   Two knobs exist for the SteamCMD family, both set by `steamentry.sh` rather than by users:
   - `PLUTAINER_LOG_PRUNE_DIRS` (colon separated) keeps the poller out of a directory. A SteamCMD install is tens of thousands of files and would otherwise be walked every 2 seconds.
   - `PLUTAINER_LOG_ROTATE=false` disables rotation. Copy-truncate is only valid against an O_APPEND writer — see the rotation note under `steamentry.sh`.

7. **`healthcheck.sh`** — Sources `lib/core.sh`, resolves the port, then queries the server **unauthenticated** and requires a non-empty map name in the reply. Two protocols, dispatched on family: Quake3 `getstatus`/`getinfo` for the CoD engines, Valve `A2S_INFO` for the SteamCMD family. Both report a map, so "healthy" means the same thing everywhere rather than degrading to a TCP accept for the new family. Tries loopback then the container's own address (see the Source note under `steamentry.sh`). Enabled by default; disable with `PLUTAINER_HEALTHCHECK=false`. HEALTHCHECK directive uses `--start-period=5m` to accommodate first-run downloads.

   **Why not RCON `status`, which it used before:** both queries are handled by the same connectionless-packet path in the same server frame loop, and both read the map from the same `mapname`/`sv_mapname` cvar, so their failure detection is identical — a stalled loop replies to neither, and a server that has lost its map reports no map to either. RCON only added a dependency on `rcon_password`, which every bundled seed ships empty, so a perfectly healthy first-run server could never report healthy. Match the map key case-insensitively: iw4x/t4/t5/t6 answer `mapname`, t7x answers `MapName`.

   **`getstatus` first, `getinfo` second — the order is load-bearing in both directions.** IW5 (MW3) does not answer `getstatus` at all, only `getinfo`, so without the fallback a healthy IW5 server reports unhealthy forever. T7x answers both, but its `infoResponse` advertises the *lobby's* map while `statusResponse` reports the map actually running (observed: `getinfo` → `mp_chinatown` while `getstatus` → `mp_spire` on the same server), so preferring `getinfo` would report the wrong map. Verified across iw4x, t4 MP/ZM, t6 MP/ZM, t7x MP/ZM (all via `getstatus`) and iw5 (via `getinfo`).

8. **`rcon-cli`** — Interactive and one-shot remote console via `docker exec`. Calls `resolve_admin_endpoint` in `lib/core.sh`, which returns a protocol, port, credential and address list; the script is one small class per protocol and a dispatch table, so a new protocol is a class plus a table entry.

    "RCON" is kept as the command name because it is what people search for, but three different protocols hide behind it:

    | Family | Protocol | Transport | Credential source |
    | --- | --- | --- | --- |
    | Plutonium, IW4x, Alterware, CoD4x | Quake3 RCON | UDP, game port | `rcon_password` in the cfg |
    | Source (hl2dm) | Valve RCON | TCP, game port | `rcon_password` in the cfg |
    | 7 Days to Die | telnet console | TCP, `TelnetPort` | `TelnetPassword` in the XML |

    `ADMIN_PROTOCOL=disabled` is a distinct answer from `none`: the game has a console but it is switched off in config, and the user gets told which setting to change.

9. **`protocols/`** — One module per wire protocol, split by protocol rather than by game because the mapping is many-to-many: Quake3 covers seven CoD titles, A2S covers every Steam-networked server regardless of engine, and querying is a different protocol from administering. `quake3.py` (query + rcon), `a2s.py` (query), `source_rcon.py` (admin), `telnet_admin.py` (admin). Which one a game uses is decided by the family tables in `lib/`, not here.

    **`protocols/quake3.py`** (was `pyquake3.py`) — Minimal Quake 3 connectionless-protocol client (UDP), trimmed from the upstream GPL library to the two paths in use: `query_values(query)` (unauthenticated `getstatus`/`getinfo`) backs the health check, `rcon()` backs `rcon-cli`. The upstream `Player`/`parse_players`/`rcon_update` machinery was removed — nothing consumed it.

    Two engine quirks live in `parse_packet`, both found the hard way:
    - **T7x prefixes its `statusResponse` with a stray `0x44` byte** before the `\xff\xff\xff\xff` connectionless prefix. Demanding the prefix at offset 0 rejected it as `Malformed packet`, which is why **RCON never worked on t7x at all** — the old healthcheck failed there regardless of password. The prefix is now located within an 8-byte window.
    - **Not every reply has a payload:** t5's zombies build answers unexpected connectionless packets with a bare `disconnect` and no newline. That is now parsed as "type, empty body" so the caller reports "replied without a map name" instead of a parse error.

10. **`tools/refresh-seeds.sh`** — The only thing that should rewrite `seed-configs/`. Resolves each upstream repo's branch to a commit SHA, downloads that exact tarball, copies the per-repo subpaths, strips `*REFERENCE*` dirs and `.bat`/`.sh`/`README*`, appends the iw4x `sv_maprotation` block, applies `harden_rcon_for_docker` (below), and writes `seed-configs/<game>/SOURCE` with the commit.

    **`harden_rcon_for_docker` — two upstream defaults that are wrong inside a container.** `rcon_localhost_bypass` is forced to `1` where the cvar exists (t5 ships `0`, which subjects even loopback to whitelist and rate-limit checks; `rcon-cli` runs over loopback inside the container). And every `rconWhitelistAdd` line is commented out: the seeds ship example IPs from another network (`192.168.0.7`, `10.0.0.12`, `172.16.8.7`), and per upstream's own comment a *non-empty* whitelist admits only those plus loopback — so the placeholders silently block the sidecar IW4MAdmin the user is trying to connect. Verified on a live t4 server: RCON from the Docker gateway was dropped until that gateway's exact IP was whitelisted, and works with no manual step once the placeholders are gone. **Ranges are not an option** — `rconWhitelistAdd "172.16.0.0/12"` answers `Error: Invalid address`, only single addresses are accepted — and enumerating Docker gateways is futile since subnets are user-defined (`172.17.0.1`, `172.26.10.1`, …). Commenting them out restores upstream's own "empty = all IPs" default; RCON still requires the password, which every seed ships empty. Takes game names to refresh a subset; honours `GITHUB_TOKEN` for API rate limits.

    **Seeds are vendored, not fetched at build time.** Six `wget`s of six third-party repos meant any one of them disappearing broke the build for *every* game — and `alterware/t7x` 404'd during development, so this is not hypothetical. Worse, the `RUN` string never changed, so BuildKit cached the layer indefinitely: upstream edits were invisible until eviction and no image could say which revision it shipped. A `COPY` re-hashes on content, so updates are a reviewable commit. Five of the six upstream repos declare no license (`iw4x/iw4-server-configs` is BSD-3-Clause); the published images already redistributed these bytes, so vendoring changes nothing legally, but keep the attribution table in README.

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
    steam/<game>/                    # SteamCMD-managed install. SteamCMD owns
                                     # this and may replace any of it.
    gamedata/<game>/                 # Worlds, saves, logs. SteamCMD never
                                     # touches this — that is the whole point
                                     # of the split.
  .plutainer-version                 # "2" — layout marker.
/home/plutainer/.plutainer/          # Scripts, updaters, steamcmd, protocols,
                                     # seed-configs.
```

**Config flow:** user edits `app/configs/<file>.cfg` → entrypoint places a relative symlink at the engine's expected path → game reads via symlink. RCON `writeconfig` writes through the symlink, modifying the real file in `configs/`.

## Game-Specific Behavior

For Plutonium, `BASE_GAME` is derived by stripping the last two chars from `PLUTAINER_GAME` (e.g., `t6zm` → `t6`). This drives:

- **Default ports**: iw4x→28960, iw5→27016, t4/t5→28960, t6→4976, t7x→27017. SteamCMD games carry their port in the family table instead (7dtd→26900, hl2dm→27015), so `resolve_default_port` delegates rather than listing them.
- **Engine config dirs** (where the game reads `+exec`'d cfg files): t4 → `runtime/gamefiles/main/`, iw5 → `runtime/gamefiles/admin/`, iw4x → `runtime/gamefiles/userraw/`, t7x → `runtime/gamefiles/zone/`, others → `runtime/plutonium/storage/<base_game>/`.
- **Command args**: iw5 uses `+set sv_config` and `+start_map_rotate`; others use `+exec` and `+map_rotate`. The map-rotate arg is opt-out family-wide via `PLUTAINER_MAP_ROTATE=false` (Plutonium + IW4x; T7x never had one).
- **Game-file symlinks** differ per base game (see the `cod_stage_*` hooks in `lib/cod.sh`).

## Compatibility surface

The `:v2` image is a **clean break** from `:latest`. The two share no env vars (other than the always-unique `PLUTO_SERVER_KEY`, `PLUTO_MAX_CLIENTS`, `IW4X_NET_LOG_IP`) and no volume layout. There is no env-var shim in `:v2` — legacy `PLUTO_*`/`IW4X_*`/`ALTER_*` names are silently ignored.

A v1 `app/` volume is refused on startup (`check_volume_version`) with explicit instructions to run `migrate-v1-to-v2.sh`.

## Restart behavior

Two distinct failure modes:

- **Configuration errors** (validation failures, missing env vars, missing config file, v1 volume, unknown game): `hold_indefinitely` → `exec sleep infinity`. Container stays `Up`; healthcheck eventually marks it unhealthy. No restart loop. User fixes and runs `docker restart <name>`.
- **Runtime crashes** (wine exits): `launch_game` wrapper catches the exit, sleeps 30s, then exits with the original return code. Docker's restart policy fires after that, giving ~1 restart per 30s instead of immediate churn.

`STOPSIGNAL` is `SIGKILL`, so neither path interferes with `docker stop` — that's instant by design, and the CoD engines lose nothing by it.

**Graceful shutdown is opt-in per service, not image-wide.** SIGKILL cannot be trapped, so a game with world state to flush can only be served by the container receiving SIGTERM. The two ways to get that are changing `STOPSIGNAL` for all nine games, or letting the games that need it ask:

```yaml
    stop_signal: SIGTERM
    stop_grace_period: 90s
```

The second costs one line in a compose file and changes nothing for the seven CoD servers people are already running, so that is what is done. `launch_game` is therefore untouched and still runs the game in the foreground; `launch_game_graceful` is a **separate** wrapper that backgrounds the child, traps TERM/INT, forwards the signal and waits. Only the SteamCMD family calls it. Measured on 7DTD: SIGTERM forwarded, save files written, exit 0, 3.5s — against 254ms for the same image with no `stop_signal`.

The hang case needs no code: Docker sends SIGKILL itself once `stop_grace_period` expires, so a server that ignores SIGTERM cannot wedge a stop.
