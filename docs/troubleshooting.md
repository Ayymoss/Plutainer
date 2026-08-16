# Troubleshooting & FAQ

Find your symptom. Every entry is something that has actually happened.

**Start here:** `docker logs <container>`. Plutainer refuses loudly rather than looping, so the reason is usually the first `[ERROR]` line.

---

## Starting up

### The container is `Up` but nothing works, and the log ends with an error

That's deliberate. A configuration mistake **holds** the container instead of restart-looping, so the error stays readable at the end of the log. Fix it, then `docker restart <container>`. See [Restart behaviour](healthcheck.md#restart-behaviour).

### `Config file not found`

`PLUTAINER_CONFIG_FILE` names something that isn't in `app/configs/`. The error lists what *was* found, including case-insensitive matches — `Server.cfg` and `server.cfg` are different files.

Valid names per game are in [Games](games.md#at-a-glance). If you expected Plutainer to seed one, check you haven't set `PLUTAINER_SKIP_SEED=true`.

### `PLUTO_SERVER_KEY is not set`

T4, T5, T6 and IW5 need a key from <https://platform.plutonium.pw/serverkeys>. IW4x, T7x and CoD4x don't.

### `mkdir: cannot create directory … Permission denied`

The container runs as UID 1000 and can't write to your app directory:

```sh
sudo chown -R 1000:1000 ./your-server-dir
```

Usually caused by creating the directory with `sudo`.

### The container refuses to start and mentions v1

Your volume or your variables are from the old image. See [MIGRATION.md](../MIGRATION.md) — one `docker run` migrates the volume.

### First start is taking forever

Expected. IW4x downloads 1–2 GB, Plutonium ~500 MB, T7x a few MB, CoD4x nothing. `docker logs -f` shows progress. The healthcheck won't judge for five minutes.

---

## Server runs but nobody can play

### T5: log loops `Early out of maprotate, waiting for WAD!`

```
Error: Unable to fetch file online_tu14_mp_english.wad. (10ms)
```

**Your Plutonium key isn't valid.** T5 pulls that asset through Plutonium's authenticated service, so an invalid or placeholder key means no map ever loads — the client says *"Server is not running a map"*. T4, T6 and IW5 tolerate a junk key; T5 does not. Use a real key.

### Players are asked for a password, or can't join

Check `g_password` in `app/configs/<your>.cfg` — it should be empty:

```
set g_password ""
```

Older CoD4x volumes shipped `my_connect_password` from upstream. Seeds never overwrite an existing file, so a volume created before that was fixed still has it. Blank it and restart.

### The server doesn't appear in the server list

- **CoD4x**: `Server needs to provide a valid token in cvar sv_authtoken` — you have no masterserver token, so the server never registers and will not show up in the browser at all. Players can still connect directly by address. Get a 32-character token from <http://cod4master.cod4x.ovh> and set `PLUTAINER_COD4X_AUTH_TOKEN`.
- **Plutonium**: `Could not send heartbeat to nix! … 401` means the key was rejected. Playable locally, not listed.

### `steam_api.so not found` (CoD4x)

Harmless on a dedicated server. Ignore it.

---

## Health and monitoring

### `docker ps` says unhealthy but the server seems fine

The healthcheck requires a **loaded map**, not just a live process. A server sitting in a map-rotation loop is unhealthy on purpose. Run it by hand to see the reason:

```sh
docker exec <container> ./healthcheck.sh
```

It does *not* need an RCON password — if you're chasing a password problem, that's not this.

### Unhealthy containers aren't restarting

Docker only restarts containers that **exit**. An `Up`-but-unhealthy container needs [Auto Heal](healthcheck.md#auto-restarting-unhealthy-servers).

### An external query tool sees nothing, but the container is healthy

T5 and T6 only answer status queries from whitelisted addresses, and T5 effectively only from localhost. The in-container healthcheck is unaffected. For T5/T6, add the querying host to `PLUTAINER_RCON_WHITELIST`.

---

## RCON and IW4MAdmin

### `rcon-cli` says it can't parse `rcon_password`

None is set — that's the default. Set `PLUTAINER_RCON_PASSWORD` or edit the config ([RCON](rcon.md)). Setting it through `PLUTAINER_EXTRA_ARGS` does **not** work; Plutainer can't read it back.

### IW4MAdmin stops responding to in-game commands after a while

Check the size of the game log. **A large enough log kills logging permanently**: the engine's write fails, the buffered data is dropped, and nothing retries or reopens the file. RCON and the webfront keep working, but IW4MAdmin reads in-game `!commands` from the log, so it looks dead in game. Reported on CoD4x past ~1 GB.

Plutainer rotates game logs at 64 MB by default, so this shouldn't happen — unless rotation was turned off (`PLUTAINER_LOG_MAX_SIZE=0`) or the log grew before you updated. Restarting the container reopens the log and restores logging immediately.

### `No rconpassword set on server or password is shorter than 8 characters`

CoD4x specifically requires an RCON password of **8 characters or more**. Shorter ones are silently refused, which reads like a wrong password. Lengthen it and restart.

### IW4MAdmin connects to some games but not T5/T6

```
Not monitoring server due to uncorrectable errors
NetworkException: Reached maximum retry attempts to send RCon data
```

Those two gate unauthenticated `getinfo` on the RCON whitelist, and IW4MAdmin opens with `getinfo`. Plutainer whitelists the Docker gateway automatically, so check:

- Is the server actually running a Plutainer version with that support?
- Is IW4MAdmin on another **machine**? Add its address to `PLUTAINER_RCON_WHITELIST`.
- Did you set `PLUTAINER_RCON_WHITELIST_GATEWAY=false`?

Full explanation: [IW4MAdmin](iw4madmin.md#the-whitelist-rule-that-catches-everyone).

### IW4MAdmin dies at startup after a fresh deploy

It aborts if a configured server doesn't answer, and IW4x can take minutes to download on first run. Use `depends_on: condition: service_healthy` ([example](../examples/with-iw4madmin.yml)).

### IW4MAdmin is connected but sees no chat, joins or in-game commands

The classic cause: `ManualLogPath` points at a **symlink**. IW4MAdmin decides whether to read by comparing the log's size against last time, and .NET reports a symlink's size as the length of the link text — a constant. The difference is never positive, so it never reads a line, and it logs no error because nothing failed.

Mount the **log file** rather than a directory, which makes Docker resolve Plutainer's `logs/` symlink at mount time:

```yaml
- ./t6zm-1/logs/games_zm.log:/gamelogs/t6zm-1/logs/games_zm.log:ro
```

Full explanation in [IW4MAdmin](iw4madmin.md#the-symlink-trap-no-events-at-all).

### IW4MAdmin missed events right after a log rotation

Fixed as of the rotation feature: Plutainer writes a marker line immediately after truncating, so the log is never observed at zero bytes. IW4MAdmin treats a zero offset as "no position yet" and re-syncs instead of reading, which used to swallow the first batch of events after each rotation. Verified: the first map change after a rotation is now read.

---

## Configs

### My config edits don't take effect

Restart the container — the game reads its config at startup. Confirm you edited `app/configs/`, not a copy under `runtime/`.

### An image update overwrote my config

It doesn't. Seeding uses "copy only if absent", so an existing file is never touched. The flip side: **fixes to the bundled configs only reach new volumes.** If a seed default changed and you want it, edit your file or delete it and restart to be re-seeded.

### I want my configs at the engine path instead

`PLUTAINER_USE_RAW_CONFIGS=true` ([details](volumes-and-configs.md#raw-configs-mode)).

### What are the `// [Plutainer]` comments in my config?

Three container-specific changes: passwords blanked, placeholder `rconWhitelistAdd` entries commented out, `rcon_localhost_bypass` forced on. Reasons in [Games](games.md#bundled-configs). Edit or revert them freely — they're your files.

---

## Architecture

### `PLUTAINER_GAME=iw4x` refuses to start on arm64

Known and expected — upstream's launcher doesn't build for arm64 right now ([iw4x/launcher#76](https://github.com/iw4x/launcher/issues/76)). It resumes automatically when upstream is fixed. Everything except CoD4x works on arm64.

### CoD4x refuses to start on arm64

Permanent, not a bug: its server is a 32-bit x86 Linux binary and cannot execute on arm64.

### A SteamCMD game refuses to start on arm64

Expected: `SteamCMD is not present in this image`. Valve ships SteamCMD as x86_64 only, so `7dtd` and `hl2dm` need the amd64 image.

---

## SteamCMD games

### First start takes forever / goes `unhealthy` before it finishes

7DTD is about 17 GB. On a slow connection that outlasts the five-minute health grace period, so the container is marked `unhealthy` while it is still downloading, then recovers by itself. Watch `docker logs -f` rather than `docker ps`.

### `Failed to install app '<id>' (Missing configuration)`

SteamCMD's first contact in a fresh container is unreliable — it downloads its own client, re-execs, and an update issued before that settles fails this way. Plutainer retries three times, which has always been enough. If all three fail, the message is real: check the app ID and that the disk has room.

### `Failed to install app '<id>' (Invalid platform)`

That app has no Linux depot available to anonymous SteamCMD. Nothing Plutainer can do. Left 4 Dead 2 is the notable case — see [Games](games.md#half-life-2-deathmatch-hl2dm).

### My world wasn't saved when I stopped the container

Add `stop_signal: SIGTERM` and `stop_grace_period: 90s` to that service. The image's default is `SIGKILL`, which is instant and right for the Call of Duty engines but gives a world-based game no chance to save. See [Healthcheck](healthcheck.md#restart-behaviour).

### The disk filled up

The SteamCMD install lives in your app volume, not the image — 7DTD alone is ~17 GB. Point the volume somewhere with room; `app/runtime/steam/<game>/` is the large part, and it can be deleted and re-downloaded without losing worlds or configs.

### `no matching manifest for linux/arm64`

You pulled `:edge`, which is amd64-only. Use `:latest`. If `:latest` is also amd64-only, an arm64 build failed — check `docker manifest inspect ghcr.io/ayymoss/plutainer:latest`.

---

## Still stuck?

Discord: <https://discord.gg/JekrGGWAUg>. Bring `docker logs <container>` output, your compose file with secrets removed, and which game you're running.
