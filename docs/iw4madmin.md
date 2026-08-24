# IW4MAdmin

Running [IW4MAdmin](https://github.com/RaidMax/IW4M-Admin) alongside Plutainer servers.

Verified against eleven servers at once — every supported game, MP and ZM — all attached.

## What IW4MAdmin needs from each server

1. **An RCON password.** Set `PLUTAINER_RCON_PASSWORD` ([RCON](rcon.md)).
2. **The game log**, so it can read events — and it must be mounted as a **file**, not reached through a symlink. See [the symlink trap](#the-symlink-trap-no-events-at-all) below; getting this wrong costs you every in-game event with no error message.
3. **Network reach** to the server's port.

## Compose

```yaml
services:
  t6zm-1:
    image: ghcr.io/ayymoss/plutainer:latest
    container_name: t6zm-1
    restart: unless-stopped
    ports: ["4976:4976/udp"]
    volumes:
      - /opt/game-files/T6ServerFiles:/home/plutainer/gamefiles:ro
      - ./t6zm-1:/home/plutainer/app
    environment:
      PLUTAINER_GAME: t6zm
      PLUTAINER_CONFIG_FILE: dedicated_zm.cfg
      PLUTAINER_RCON_PASSWORD: ${T6ZM_RCON}
      PLUTO_SERVER_KEY: ${T6ZM_KEY}
    networks: [games-net]

  iw4madmin:
    image: ghcr.io/raidmax/iw4madmin:latest
    container_name: iw4madmin
    restart: unless-stopped
    ports: ["1624:1624"]
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/London
    volumes:
      - ./IW4MAdmin/Configuration:/app/Configuration
      - ./IW4MAdmin/Plugins:/app/Plugins
      - ./IW4MAdmin/Localization:/app/Localization
      - ./IW4MAdmin/Database:/app/Database
      - ./IW4MAdmin/Log:/app/Log
      # Mount the LOG FILE itself, not the directory. Docker resolves the
      # symlink on the host at mount time, so the container sees a real file.
      - ./t6zm-1/logs/games_zm.log:/gamelogs/t6zm-1/logs/games_zm.log:ro
    depends_on:
      t6zm-1:
        condition: service_healthy      # wait for the server, not just the container
    networks: [iw4m-net]

networks:
  games-net:
    driver: bridge
  iw4m-net:
    driver: bridge
```

`depends_on: service_healthy` matters more than it looks: IW4x spends its first few minutes downloading 1–2 GB, and IW4MAdmin aborts startup if a configured server doesn't answer. Without it, a fresh deployment can come up with IW4MAdmin dead.

A full working example is in [`examples/with-iw4madmin.yml`](../examples/with-iw4madmin.yml).

## Server entries

In `IW4MAdmin/Configuration/IW4MAdminSettings.json`. Address the servers by your **host IP** and published port:

```json
{
  "Servers": [
    {
      "IPAddress": "10.0.0.5",
      "Port": 4976,
      "Password": "your-rcon-password",
      "ManualLogPath": "/gamelogs/t6zm-1/logs/games_zm.log",
      "RConParserVersion": "Plutonium T6 Parser (2024)",
      "EventParserVersion": "Plutonium T6 Parser (2024)"
    }
  ]
}
```

`ManualLogPath` matches the mount path above. Because the mount was taken through `logs/`, Docker resolved Plutainer's stable symlink at mount time and IW4MAdmin sees a plain file — which is what it needs.

### 7 Days to Die Telnet endpoint

7DTD uses Telnet on TCP port 8081 instead of RCON on the game port. Connect IW4MAdmin through a stable private host address and a published Telnet port, just as the other games use the host address and their published ports:

```yaml
ports:
  - "${SEVENDTD_TELNET_BIND:-127.0.0.1}:8081:8081/tcp"
```

Leave the loopback default when the management client runs on the host. For IW4MAdmin in Docker, set `SEVENDTD_TELNET_BIND` to a private LAN, VPN, or dedicated Docker bridge address reachable from its container, then use that address with port `8081` in `IW4MAdminSettings.json`. Do not store the 7DTD container's internal IP and do not expose Telnet on a public interface.

### Parsers and log names

| Game | Parser | Log file |
| --- | --- | --- |
| T4 MP | `Plutonium T4 MP Parser` | `games_mp.log` |
| T4 ZM (`t4sp`) | `Plutonium T4 CO-OP/Zombies Parser` | `games_zm.log` |
| T5 MP | `Plutonium T5 Parser` | `games_mp.log` |
| T5 ZM (`t5sp`) | `Plutonium T5 Parser` | `games_sp.log` |
| T6 MP / ZM | `Plutonium T6 Parser (2024)` | `games_mp.log` / `games_zm.log` |
| IW5 | `Plutonium IW5 Parser` | `games_mp.log` |
| IW4x | `IW4x Parser` | `games_mp.log` |
| T7x | `BOIII Parser` | `games_mp.log` / `games_zm.log` |
| CoD4x | `CoD4x Parser` | `games_mp.log` |
| 7 Days to Die | `7 Days to Die Parser` | `server-output.log` |

IW4MAdmin needs a pre-existing `IW4MAdminSettings.json` before its container will start — it won't generate one unattended.

## The symlink trap: no events at all

If IW4MAdmin connects, shows the server online and responds to RCON, but **never sees chat, joins, or in-game `!commands`**, this is almost certainly why.

IW4MAdmin decides whether to read by watching the log file's size:

```csharp
var fileSize = _reader.Length;              // new FileInfo(path).Length
var fileDiff = fileSize - _previousFileSize;
if (fileDiff < 1 ...) return;               // nothing new, don't read
```

On Linux, .NET's `FileInfo.Length` for a **symlink** returns the length of the link text, not of the target. Plutainer's `app/logs/games_mp.log` is a symlink, so its "size" is a constant 38 bytes no matter how much the real log grows. The difference is never positive, so **IW4MAdmin never reads a single line** — and logs no error, because nothing failed.

Measured directly: with `ManualLogPath` pointing at the symlink, a real map change grew the log from 191 to 861 bytes and IW4MAdmin logged nothing. Repointing it at the real file and repeating the map change produced `New map loaded` within two seconds.

Two ways to get it right:

- **Mount the log file** (what the examples do). Docker resolves the host-side symlink when it creates the mount, so the container sees a regular file and you still get to name it via the stable `logs/` path.
- **Point at the real path** under `runtime/`, e.g. `/gamelogs/t6zm-1/runtime/plutonium/storage/t6/main/logs/games_zm.log`. Works, but the path differs per game and moves when you change mods.

One caveat with the file mount: the target must exist when the container starts, or Docker creates a **directory** in its place. Start the game server first — `depends_on: condition: service_healthy` handles both this and the startup race.

## The whitelist rule that catches everyone

If IW4MAdmin attaches to your other games but **T5 and T6 fail** with:

```
Not monitoring server due to uncorrectable errors [10.0.0.5:4976]
NetworkException: Reached maximum retry attempts to send RCon data to server
```

…here's what's happening. T5 and T6 gate *unauthenticated* queries — `getinfo` and `getstatus` — on the RCON whitelist, and IW4MAdmin's T5/T6 parsers open the connection with `getinfo`. So the RCON handshake succeeds and the connection still fails:

```
getinfo                 -> (no reply)          ← fails here
rcon <pw> version       -> "Plutonium T6 …"    ← RCON is fine
rcon <pw> sv_running    -> "1"
getinfo  ×6             -> (no reply)          ← gives up
```

Measured on T6, from off-loopback:

| whitelist state | RCON | `getinfo` |
| --- | --- | --- |
| upstream's placeholder IPs | blocked | blocked |
| empty | works | blocked |
| gateway whitelisted | works | works |

Note the middle row: an **empty whitelist is not permissive** for these queries, even though it is for RCON commands — which is the opposite of what the comment in the stock config implies.

**Plutainer handles this automatically.** The address a sidecar appears to come from is the server container's Docker bridge gateway, assigned at run time and therefore impossible to bake into a config file — so Plutainer detects it at startup and passes `+rconWhitelistAdd <gateway>` as a launch argument. Your config is not modified.

You only need to intervene if your admin tool is on another machine:

```yaml
environment:
  PLUTAINER_RCON_WHITELIST: "10.10.1.20"
```

`PLUTAINER_RCON_WHITELIST_GATEWAY=false` disables the automatic entry. Note that any whitelist entry makes the whitelist non-empty, restricting T5/T6 RCON to the listed addresses plus loopback — the posture upstream's placeholder entries intended.

T4, IW5, IW4x, T7x and CoD4x answer queries regardless and get no whitelist entries.

## Networking

Running IW4MAdmin on a **separate bridge network** from the game servers is the tested arrangement, and what the examples use. Traffic then arrives at the game from the game's own gateway, which is the address Plutainer whitelists.

Running IW4MAdmin bare-metal on the host, or on a different machine entirely, also works — in that case whitelist its address with `PLUTAINER_RCON_WHITELIST` for T5/T6.
