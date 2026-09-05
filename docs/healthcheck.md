# Healthcheck & restarts

## What "healthy" means

For Call of Duty and SteamCMD games, Plutainer asks the server for its status and requires it to **name a loaded map**. A container is healthy only when the game is genuinely serving — not merely when the process is alive.

Nebula exposes no unauthenticated status request that names the loaded save, so its strongest non-invasive check is the presence of the game-owned TCP listener.

1. Work out the game and port.
2. Query it, unauthenticated:
   - **Call of Duty engines** — Quake3 `getstatus`, falling back to `getinfo`.
   - **SteamCMD games** — Valve's `A2S_INFO`, the query behind the Steam server browser.
   - **Nebula** — inspect Linux's TCP listener table for the configured port. This does not connect, produce WebSocket errors, or create a ghost player.
3. Require a map name where the protocol supplies one; for Nebula, require the listener.

All checks are unauthenticated on purpose. RCON would work for the other families, but it depends on a password, and every seeded config ships that empty — so a perfectly healthy first-run server could never report healthy.

The address is tried as `127.0.0.1` first, then the container's own IP. Source dedicated servers answer only on the latter: an identical A2S query times out on loopback and replies immediately on the container address, with the server healthy throughout.

```
[OK] Health check passed: Server is responsive on port 4976 (map: zm_buried (via getstatus)).
```

**No RCON password required.** The engine answers these queries from the same connectionless handler, in the same server frame loop, that answers RCON `status`, and reports the map from the same cvar — so a stalled server or one that has lost its map fails this check exactly as it would have failed an RCON-based one, by not replying or by replying with no map.

Why both queries: IW5 and T5 only answer `getinfo`; everything else answers `getstatus`, which is preferred because T7x's `getinfo` reports the *lobby's* map rather than the running one.

Disable with `PLUTAINER_HEALTHCHECK=false`.

### Start period

The healthcheck allows **five minutes** before failures count, because a first start downloads a lot (IW4x 1–2 GB, Plutonium ~500 MB, 7DTD ~17 GB through SteamCMD). During that window `docker ps` shows `starting`. A first 7DTD start will exceed five minutes on a slow connection; it shows `unhealthy` until the download finishes and then recovers on its own.

## Restart behaviour

Plutainer separates *your* mistakes from the game's:

**Configuration errors** — missing `PLUTAINER_CONFIG_FILE`, an unknown `PLUTAINER_GAME`, a v1 volume, a missing Plutonium key. The container prints the reason and then holds in `Up` with `sleep infinity`.

No restart loop, no log spam burying the error. Fix it and `docker restart <container>`. The healthcheck keeps running and eventually marks the container unhealthy, so orchestration still sees something is wrong.

**Runtime crashes** — the game exits on its own. Plutainer waits **30 seconds**, then exits with the game's code, letting your `restart:` policy take over. That throttles a crash loop to roughly one restart per 30s instead of hammering.

`STOPSIGNAL` is `SIGKILL`, so `docker stop` is instant. That is right for the Call of Duty engines, which have no state to flush.

A game that *does* — a world to save — opts in per service, because `SIGKILL` cannot be trapped by anything:

```yaml
    stop_signal: SIGTERM
    stop_grace_period: 90s
```

Plutainer then forwards the signal and waits. Nebula waits for its paired `_lastexit_.dsv` and `_lastexit_.server` files to settle before ending a Wine wrapper that remains stuck after saving. Docker sends `SIGKILL` itself when the grace period expires, so a server that ignores `SIGTERM` still cannot wedge a stop.

## Auto-restarting unhealthy servers

Docker restarts containers that *exit*; it does nothing about a container that's `Up` but unhealthy. Add [Auto Heal](https://github.com/willfarrell/docker-autoheal):

```yaml
  autoheal:
    image: willfarrell/autoheal
    restart: unless-stopped
    environment:
      - AUTOHEAL_CONTAINER_LABEL=autoheal
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
```

then label the servers you want watched:

```yaml
    labels:
      - autoheal=true
```

Be deliberate about pairing this with a *configuration* failure: a held container is unhealthy by design, and autoheal will restart it forever without fixing anything. Read the logs before assuming a restart loop is the game's fault.
