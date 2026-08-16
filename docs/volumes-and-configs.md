# Volumes & configs

Where everything lives, and why your configs are in one folder instead of scattered through the game tree.

## Two mounts

| Container path | What it is | Mount as |
| --- | --- | --- |
| `/home/plutainer/gamefiles` | Base game files you own | bind-mount, `:ro` |
| `/home/plutainer/app` | Server state, configs, logs | bind-mount or named volume |

The gamefiles mount is read-only and shareable — point ten servers at the same copy. Anything an updater downloads goes into `app/` instead, so don't stage binaries in the gamefiles mount.

The SteamCMD games (`7dtd`, `hl2dm`) do not use `/home/plutainer/gamefiles` at all; SteamCMD installs them under the app volume instead.

## What appears in `app/`

Created on first start:

```
app/
  configs/            ← your *.cfg files (or serverconfig.xml for 7DTD)
  logs/               ← stable symlinks to the active *.log files
  runtime/
    gamefiles/        ← symlinks into your read-only mount + writable game state
    plutonium/        ← Plutonium binaries and storage
    steam/<game>/     ← SteamCMD-managed install (SteamCMD games)
    gamedata/<game>/  ← worlds, saves, logs (SteamCMD games)
  .plutainer-version  ← layout marker
```

You edit `configs/`. You read `logs/`. You can ignore `runtime/`.

## How configs actually work

Every game reads its config from a different place — `main/`, `admin/`, `userraw/`, `zone/`, `plutonium/storage/t6/`. Rather than make you learn each one, Plutainer keeps the real file in `app/configs/` and puts a symlink at the engine's path.

```
app/configs/dedicated_zm.cfg                             ← the real file, you edit this
app/runtime/plutonium/storage/t6/dedicated_zm.cfg  ────┘ ← symlink, the game reads this
```

Consequences worth knowing:

- **Edit in one place**, whatever the game.
- **RCON `writeconfig` writes through the symlink**, so it updates the real file in `configs/`.
- **If `PLUTAINER_MOD` is set**, the same config is also linked into the mod's config dir, so the engine finds it whether it looks in the base or mod-scoped location.
- **Nested configs stay put.** Files in subdirectories (gametype configs, mod configs) remain under `runtime/` at their engine path. Edit them there.
- **A real file at the engine path is never clobbered.** Plutainer warns and leaves it alone.

### Auto-lift

Put a config at the engine path by hand and Plutainer moves it into `app/configs/` on the next start, then links it back. One-time, no manual migration.

### Filename mismatches

If `PLUTAINER_CONFIG_FILE` names something that doesn't exist, the container refuses to start and prints a case-insensitive search of what it did find — so `Server.cfg` vs `server.cfg` is obvious immediately. Filenames stay case-sensitive; nothing is auto-renamed.

## Raw configs mode

`PLUTAINER_USE_RAW_CONFIGS=true` turns the symlink system off:

- The engine config dir under `app/runtime/…` becomes the source of truth
- `app/configs/` is ignored
- Seeds go straight to the engine dir

Use it when host-side tooling expects the real file at the engine path. You can toggle it between restarts, but Plutainer won't move existing files when you flip it — that part's yours.

## Logs

`app/logs/` holds symlinks to the live log file for each basename. Game logs move around per game and per mod (`runtime/plutonium/storage/t5/mods/<mod>/logs/games_zm.log`), so the watcher surfaces them all in one predictable place:

```
app/logs/games_mp.log -> ../runtime/gamefiles/main/games_mp.log
```

Point log readers at that directory:

```yaml
volumes:
  - ./t6zm-1/logs:/app/gamelogs/t6zm-1:ro
```

The symlinks are **relative**, so they resolve identically from the host, from inside the container, or from a sidecar mounting the same `app/` volume.

> **Mounting one of these into a sidecar: mount the file, not the directory.** `- ./t6zm-1/logs/games_zm.log:/gamelogs/t6zm-1/logs/games_zm.log:ro` makes Docker resolve the symlink at mount time, so the sidecar sees a real file. Mount the directory instead and the sidecar sees a symlink — which breaks any reader that judges "has this file grown?" by the file's size, IW4MAdmin included. Details in [IW4MAdmin](iw4madmin.md#the-symlink-trap-no-events-at-all).

Disable with `PLUTAINER_LOG_SYMLINKS=false`; tune with `PLUTAINER_LOG_POLL_INTERVAL`.

### Rotation

Game logs are rotated once they reach **64 MB**, keeping one previous copy alongside the live file (`games_mp.log.1`). Worst case is therefore ~128 MB per server — deliberately modest, because thirty servers each sitting on gigabyte logs adds up to tens of gigabytes nobody reads.

```yaml
environment:
  PLUTAINER_LOG_MAX_SIZE: "64M"   # 0 disables rotation entirely
  PLUTAINER_LOG_KEEP: "1"         # 0 keeps no copy at all
```

This is not just housekeeping. **A large enough log stops the server logging permanently.** CoD4x buffers log output and hands each chunk to `fwrite()`; when that write fails the engine prints a warning and drops the data, having already advanced its buffer. Nothing retries and nothing reopens the file, so the log is dead for the life of the process — and since IW4MAdmin reads in-game commands from the log, it looks like the admin tool has stopped responding even though RCON still works.

Rotation is copy-truncate: the live file is copied aside and then truncated in place. That is safe because every engine here opens its game log in **append mode** (CoD4x is literally `fopen(path, "ab")`), so the next write seeks to end-of-file and resumes at offset 0. Renaming would be wrong — the engine holds an open handle and would keep writing to the renamed file, so the path your admin tool reads would silently stop updating, which is the very failure being fixed.

Verified on all eleven server types, and confirmed on a live CoD4x server: after truncation a map change wrote a fresh `InitGame:` line to the emptied file.

Two related details, both for the benefit of log readers that track a byte offset:

- After truncating, Plutainer writes a one-line marker so the file is never seen at zero bytes. IW4MAdmin treats a zero offset as "no position yet" and re-syncs instead of reading, which would otherwise swallow the first batch of events after every rotation.
- A brand-new empty log is primed with the same kind of line, for the same reason — otherwise the first map's events on a fresh deployment are never ingested. Measured across eleven servers: the three whose logs happened to be empty missed their first event and caught the second; priming removes that.

## Trimming the gamefiles mount

Deleting files from the read-only mount is fine — Plutainer relinks from scratch on each start and removes links whose target is gone. Nothing needs rebuilding. What each game genuinely needs is in [Games](games.md#what-goes-in-the-gamefiles-mount).

## Permissions

The container runs as UID `1000`. If `docker logs` shows:

```
mkdir: cannot create directory '/home/plutainer/app/configs': Permission denied
```

fix ownership on the host:

```sh
sudo chown -R 1000:1000 ./your-server-dir
```

This usually bites when the directory was created with `sudo`.
