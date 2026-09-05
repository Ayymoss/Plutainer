# Quickstart

Getting one server running, start to finish. Budget ten minutes, most of it waiting for downloads.

## Before you start

You need three things:

1. **Docker and Docker Compose** on a Linux host.
2. **The base game files**, which you must own — for the Call of Duty engines and Dyson Sphere Program/Nebula. The SteamCMD games install themselves and need no gamefiles mount. What exactly each game needs is in [Games](games.md).
3. **A server key or token**, depending on the game:
   - **T4, T5, T6, IW5** need a Plutonium server key, free from <https://platform.plutonium.pw/serverkeys>. The server will not start without one.
   - **CoD4x** needs a masterserver token from <http://cod4master.cod4x.ovh> to be listed in the server browser. It runs without one, but nobody will find it.
   - **IW4x, T7x, Nebula and the SteamCMD games** need no key or token. Nebula's
     headless Steam API compatibility layer is built into the image; do not put
     Steam credentials in the container.

## 1. Put the game files somewhere

Anywhere on the host. They're mounted read-only, so they can be shared by as many servers as you like:

```
/opt/game-files/
  T6ServerFiles/
  IW4xServerFiles/
```

Skip this step for the SteamCMD games (`7dtd`, `cs2`, `l4d2`, `hl2dm`). For Nebula, use the root of your Dyson Sphere Program installation, with `DSPGAME.exe` directly inside it.

## 2. Write a compose file

Pick your game's example from [`examples/`](../examples/), or start from this one:

```yaml
services:
  t6zm-1:
    image: ghcr.io/ayymoss/plutainer:latest
    container_name: t6zm-1
    restart: unless-stopped
    ports:
      - "4976:4976/udp"
    volumes:
      - /opt/game-files/T6ServerFiles:/home/plutainer/gamefiles:ro
      - ./t6zm-1:/home/plutainer/app
    environment:
      PLUTAINER_GAME: t6zm
      PLUTAINER_CONFIG_FILE: dedicated_zm.cfg
      PLUTO_SERVER_KEY: ${T6ZM_KEY}
      PLUTAINER_RCON_PASSWORD: change-me-or-remove-this-line
```

Four settings matter:

| | |
| --- | --- |
| `PLUTAINER_GAME` | Which game. [Full list](games.md) |
| `PLUTAINER_CONFIG_FILE` | Which config to run. **Must be one Plutainer seeds** unless you supply your own — [names per game](games.md) |
| the gamefiles mount | Your base game files, read-only (not used by the SteamCMD games) |
| the app mount | Where server data, configs and logs live |

Put the key in a `.env` file next to your compose file so it stays out of the compose:

```
T6ZM_KEY=your-key-here
```

## 3. Start it

```sh
docker compose up -d
docker compose logs -f
```

**First start takes a while.** Plutonium downloads ~500 MB, IW4x 1–2 GB, 7DTD about 17 GB. Nebula downloads its mod plus dependencies, initializes the Windows game under Wine, and creates a new save; on modest hardware its first boot can take several minutes and use more than 3 GiB RAM. CoD4x is ready in under a minute since everything ships in the image. The healthcheck allows five minutes before it starts judging.

## 4. Check it worked

```sh
docker ps
```

`healthy` means the server answered a status query and reported a loaded map — it's genuinely up, not just running. If it says `unhealthy` or never leaves `starting`, go to [Troubleshooting](troubleshooting.md).

## 5. Edit your config

Everything is in one folder, whatever the game:

```sh
nano ./t6zm-1/configs/dedicated_zm.cfg
docker restart t6zm-1
```

Plutainer symlinks that file to wherever the engine expects it, so you never go hunting through `runtime/`. Details in [Volumes & configs](volumes-and-configs.md).

## What you get

```
t6zm-1/
  configs/          ← edit your *.cfg here
  logs/             ← stable symlinks to the live logs
  runtime/          ← game files, binaries, engine state (leave alone)
```

## Next steps

- **Send commands to the server** → [RCON](rcon.md). Set `PLUTAINER_RCON_PASSWORD` first; it's empty by default so RCON is off.
- **Add an admin tool** → [IW4MAdmin](iw4madmin.md)
- **Run several servers** → [`examples/multi-server.yml`](../examples/multi-server.yml). Each needs its own port and its own app directory; the gamefiles mount can be shared.
- **Restart servers automatically when they die** → [Healthcheck & restarts](healthcheck.md)

## A note on permissions

The container runs as UID `1000`. If you create the app directory as root, the container may not be able to write to it:

```sh
sudo chown -R 1000:1000 ./t6zm-1
```

Most desktop Linux users are already UID 1000 and never hit this. If the logs say `Permission denied` while creating `configs`, `logs` or `runtime`, this is why.
