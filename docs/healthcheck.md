# Healthcheck & restarts

## What "healthy" means

For Call of Duty engines, Plutainer asks the server for its status and requires it to **name a loaded map**. For 7 Days to Die, it requires the dedicated process and a successful TCP connection to the configured game port.

1. Work out the game and port.
2. Send an unauthenticated `getstatus` to `127.0.0.1`, falling back to `getinfo`.
3. Require a map name in the reply.

The 7DTD branch instead checks `7DaysToDieServer.x86_64` and connects to `127.0.0.1:<game port>`; it does not speak the Quake status protocol.

```
[OK] Health check passed: Server is responsive on port 4976 (map: zm_buried (via getstatus)).
```

**No RCON password required.** The engine answers these queries from the same connectionless handler, in the same server frame loop, that answers RCON `status`, and reports the map from the same cvar — so a stalled server or one that has lost its map fails this check exactly as it would have failed an RCON-based one, by not replying or by replying with no map.

Why both queries: IW5 and T5 only answer `getinfo`; everything else answers `getstatus`, which is preferred because T7x's `getinfo` reports the *lobby's* map rather than the running one.

Disable with `PLUTAINER_HEALTHCHECK=false`.

### Start period

The healthcheck allows **five minutes** before failures count, because a first start downloads a lot (including the full 7DTD dedicated server through SteamCMD). During that window `docker ps` shows `starting`.

## Restart behaviour

Plutainer separates *your* mistakes from the game's:

**Configuration errors** — missing `PLUTAINER_CONFIG_FILE`, an unknown `PLUTAINER_GAME`, a v1 volume, a missing Plutonium key. The container prints the reason and then holds in `Up` with `sleep infinity`.

No restart loop, no log spam burying the error. Fix it and `docker restart <container>`. The healthcheck keeps running and eventually marks the container unhealthy, so orchestration still sees something is wrong.

**Runtime crashes** — the game exits on its own. Plutainer waits **30 seconds**, then exits with the game's code, letting your `restart:` policy take over. That throttles a crash loop to roughly one restart per 30s instead of hammering.

Docker sends `SIGTERM` to Plutainer's launch wrapper. Call of Duty families retain their immediate-stop behaviour. For 7DTD, the wrapper forwards the signal to the native server and waits for its `ServerShutdown` save path to finish; its Compose example allows a two-minute grace period. Docker still force-kills the container if that timeout expires.

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
