# Migration: Plutainer v1 → v2

Plutainer v2 is now published as `ghcr.io/ayymoss/plutainer:latest` (and `:v2` as a permanent alias). The previous v1 image is frozen at `ghcr.io/ayymoss/plutainer:v1-final` and `:v1`.

This page covers everything you need to migrate an existing v1 deployment.

If you do not want to migrate right now, [pin v1-final](#path-a--stay-on-v1) instead and come back when you are ready. v1-final will continue to start, but it shows a deprecation banner every time and receives no further updates.

---

## What changed?

1. **Unified environment variables.** The old `PLUTO_*`, `IW4X_*`, and `ALTER_*` prefixes are gone. Everything is now `PLUTAINER_*` and game family is derived from `PLUTAINER_GAME`.
2. **New volume layout** inside `/home/plutainer/app/`:
   ```
   v1 layout                    v2 layout
   ─────────                    ─────────
   app/gamefiles/               app/configs/        ← your *.cfg files (flat)
   app/plutonium/               app/runtime/gamefiles/
   app/logs/                    app/runtime/plutonium/
                                app/logs/           ← stable symlinks to active logs
                                .plutainer-version  ← layout marker (contains "2")
   ```
   You now edit configs in one flat `app/configs/` directory. The entrypoint places relative symlinks from there into wherever the game engine expects them, so a single edit reaches both the engine path and any mod path.
3. **`app/logs/`** is now maintained by `log-watcher.sh` — every `*.log` under `app/` is surfaced as a stable relative symlink in this directory, so sidecars (IW4MAdmin) can read from one predictable path regardless of which mod dir the game is writing to.

---

## Path A — Stay on v1

```yaml
# docker-compose.yml
services:
  myserver:
    image: ghcr.io/ayymoss/plutainer:v1-final   # was: :latest
    # ... everything else stays as-is
```

Then:

```bash
docker compose pull
docker compose up -d
```

A deprecation banner appears in `docker logs` on every start. The server otherwise runs unchanged.

---

## Path B — Migrate to v2

### Step 1 — Stop the container

```bash
docker compose down
```

### Step 2 — Migrate the volume layout

Run the bundled migration tool against your existing volume. The tool moves files in place, replacing engine-path config files with relative symlinks back into the new `app/configs/` tree. **No data is deleted.**

```bash
docker run --rm \
  -v <YOUR_APP_VOLUME>:/home/plutainer/app \
  --entrypoint /home/plutainer/.plutainer/migrate-v1-to-v2.sh \
  ghcr.io/ayymoss/plutainer:v2
```

`<YOUR_APP_VOLUME>` is whatever host path is bound to `/home/plutainer/app` in your compose. For a directory-style mount like `./t6zm-1:/home/plutainer/app`, that is `./t6zm-1`.

**Preview first** by appending `--dry-run` — the tool prints every move it would make without touching the filesystem.

After the tool runs, your volume contains:
- `app/configs/<your *.cfg>` (real files, moved from old engine paths)
- Symlinks from the old engine paths back into `app/configs/` so the game still finds them
- `app/.plutainer-version` containing `2`
- `app/runtime/gamefiles/`, `app/runtime/plutonium/` (your old `app/gamefiles/`, `app/plutonium/` moved here)

### Step 3 — Rename your environment variables

Anything not listed in this table keeps its old name (notably `PLUTO_SERVER_KEY`, `PLUTO_MAX_CLIENTS`, `IW4X_NET_LOG_IP` — these are unchanged).

| v1 name              | v2 name                            |
| -------------------- | ---------------------------------- |
| `PLUTO_GAME`         | `PLUTAINER_GAME`                   |
| `PLUTO_CONFIG_FILE`  | `PLUTAINER_CONFIG_FILE`            |
| `PLUTO_PORT`         | `PLUTAINER_PORT`                   |
| `PLUTO_HEALTHCHECK`  | `PLUTAINER_HEALTHCHECK`            |
| `PLUTO_MOD`          | `PLUTAINER_MOD`                    |
| `PLUTO_SKIP_SEED`    | `PLUTAINER_SKIP_SEED`              |
| `PLUTO_AUTO_UPDATE`  | `PLUTAINER_AUTO_UPDATE`            |
| `PLUTO_SERVER_NAME`  | `PLUTAINER_SERVER_NAME`            |
| `PLUTO_EXTRA_ARGS`   | `PLUTAINER_EXTRA_ARGS`             |
| `IW4X_GAME`          | `PLUTAINER_GAME=iw4x`              |
| `IW4X_CONFIG_FILE`   | `PLUTAINER_CONFIG_FILE`            |
| `IW4X_PORT`          | `PLUTAINER_PORT`                   |
| `IW4X_HEALTHCHECK`   | `PLUTAINER_HEALTHCHECK`            |
| `IW4X_MOD`           | `PLUTAINER_MOD`                    |
| `IW4X_AUTO_UPDATE`   | `PLUTAINER_AUTO_UPDATE`            |
| `IW4X_SERVER_NAME`   | `PLUTAINER_SERVER_NAME`            |
| `IW4X_EXTRA_ARGS`    | `PLUTAINER_EXTRA_ARGS`             |
| `ALTER_GAME`         | `PLUTAINER_GAME` (e.g. `t7x`)      |
| `ALTER_CONFIG_FILE`  | `PLUTAINER_CONFIG_FILE`            |
| `ALTER_PORT`         | `PLUTAINER_PORT`                   |
| `ALTER_HEALTHCHECK`  | `PLUTAINER_HEALTHCHECK`            |
| `ALTER_MOD`          | `PLUTAINER_MOD`                    |
| `ALTER_SKIP_SEED`    | `PLUTAINER_SKIP_SEED`              |
| `ALTER_AUTO_UPDATE`  | `PLUTAINER_AUTO_UPDATE`            |
| `ALTER_SERVER_NAME`  | `PLUTAINER_SERVER_NAME`            |
| `ALTER_EXTRA_ARGS`   | `PLUTAINER_EXTRA_ARGS`             |

Update the `image:` line in your compose:

```yaml
image: ghcr.io/ayymoss/plutainer:latest   # or :v2 (alias)
```

### Step 4 — Start

```bash
docker compose up -d
docker compose logs -f
```

You should see a fresh boot ending in `Starting Plutonium <game> Server: ...` (or the equivalent for IW4x/Alterware) followed by the game process. Healthcheck flips to `healthy` once RCON responds.

---

## Troubleshooting

**Container holds with a v1 deployment refusal block.**
You started v2 against either a v1 volume, v1 env vars, or both. The block lists exactly what was detected. Fix what it lists, then `docker compose up -d`. The container does not restart-loop — it stays `Up` with `sleep infinity` so you can read the message in `docker logs`.

**Container holds with "Config file not found".**
Your `PLUTAINER_CONFIG_FILE` does not match a file in `app/configs/`. The block prints a case-insensitive hint (`Did you mean: ...?`) — filenames on Linux are case-sensitive.

**RCON / healthcheck warns "Could not parse rcon_password".**
The parser accepts `set rcon_password "..."`, `seta rcon_password '...'`, unquoted values, and the bare `rcon_password "..."` form. It strips `//` line comments. Do **not** set `rcon_password` via `PLUTAINER_EXTRA_ARGS` — it cannot be read back.

**I want the old behaviour where I edit configs directly in the engine path.**
Set `PLUTAINER_USE_RAW_CONFIGS=true`. The fan-out symlinks are skipped and the engine path becomes the source of truth.

---

## Rolling back

If something goes wrong, you can return to v1 immediately:

```yaml
image: ghcr.io/ayymoss/plutainer:v1-final
```

`docker compose up -d`. The v2 migration tool only moved files inside the bind-mounted volume — it did not delete anything. v1-final will read the v1 layout it remembers, ignore the new `app/configs/` and `app/runtime/` dirs, and start as before.

If you need to fully restore the pre-migration state (so the dirs from v2 are removed), back up first and then `mv` the contents of `app/runtime/gamefiles/` back to `app/gamefiles/` and `app/runtime/plutonium/` back to `app/plutonium/`. Symlinks at engine paths can be replaced with the real files from `app/configs/`. Most users will not need this.
