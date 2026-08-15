# Plutainer

Run a Call of Duty dedicated server in Docker. One image, seven games, configured with environment variables.

```yaml
services:
  my-server:
    image: ghcr.io/ayymoss/plutainer:latest
    ports: ["4976:4976/udp"]
    volumes:
      - /path/to/BO2/files:/home/plutainer/gamefiles:ro
      - ./my-server:/home/plutainer/app
    environment:
      PLUTAINER_GAME: t6zm
      PLUTAINER_CONFIG_FILE: dedicated_zm.cfg
      PLUTO_SERVER_KEY: your-key-here
    restart: unless-stopped
```

`docker compose up -d` and you have a Black Ops II zombies server. Plutainer writes a working config on first start, so there is nothing to prepare beyond the game files you own.

**[→ Start here: the Quickstart](docs/quickstart.md)**

## Supported games

| Game | `PLUTAINER_GAME` | Notes |
| --- | --- | --- |
| World at War (T4) | `t4mp`, `t4sp` | Plutonium. Needs a server key |
| Black Ops (T5) | `t5mp`, `t5sp` | Plutonium. Needs a **valid** server key — [see why](docs/games.md#t5-black-ops) |
| Black Ops II (T6) | `t6mp`, `t6zm` | Plutonium. Needs a server key |
| Modern Warfare 3 (IW5) | `iw5mp` | Plutonium. Needs a server key |
| Modern Warfare 2 (IW4x) | `iw4x` | No key. amd64 only |
| Black Ops III (T7x) | `t7x` | Alterware. No key |
| Modern Warfare (CoD4x) | `cod4x` | Multiplayer only, amd64 only. Needs a [masterserver token](docs/games.md#cod4x-modern-warfare) to appear in the server browser |

Image: `ghcr.io/ayymoss/plutainer:latest` — multi-arch (amd64 + arm64), with [two exceptions](docs/games.md#architecture-support).

## Documentation

| If you want to… | Read |
| --- | --- |
| Get a first server running | [Quickstart](docs/quickstart.md) |
| Know what *your* game needs | [Games](docs/games.md) — files, keys, config names, ports |
| Look up an environment variable | [Configuration](docs/configuration.md) |
| Understand where configs and logs live | [Volumes & configs](docs/volumes-and-configs.md) |
| Send RCON commands | [RCON](docs/rcon.md) |
| Connect IW4MAdmin | [IW4MAdmin](docs/iw4madmin.md) |
| Know when a server counts as healthy | [Healthcheck & restarts](docs/healthcheck.md) |
| Fix something that's broken | **[Troubleshooting & FAQ](docs/troubleshooting.md)** |
| Copy a working compose file | [Examples](examples/) |
| Upgrade from v1 | [Migration guide](MIGRATION.md) |

## What Plutainer does for you

- **Writes a working config on first start.** Community defaults are seeded into `app/configs/`, and never overwrite files you've edited.
- **Fetches the server binaries.** Plutonium, IW4x and T7x updaters run at startup; CoD4x ships in the image. You supply only the base game files.
- **Puts every config in one folder.** Edit `app/configs/whatever.cfg`; Plutainer symlinks it to wherever the engine expects it.
- **Keeps logs findable.** `app/logs/` holds stable symlinks to the active log files, wherever the game moved them.
- **Fails loudly, not endlessly.** A misconfiguration holds the container in `Up` with a readable error instead of a restart loop.
- **Reports real health.** The healthcheck asks the server for its current map — no RCON password required.

## Support

Discord: <https://discord.gg/JekrGGWAUg> — for Plutainer setup and configuration, including IW4MAdmin.

Plutonium-specific game issues are out of scope, and some familiarity with Docker is assumed. New to Docker? Start at <https://docs.docker.com/get-started/>.

## Credits

- Corey, for a production testing ground @ <https://cukservers.net/>
- HGM, for the name 'Plutainer' @ <https://hgmserve.rs/>
- The config authors credited in [Games](docs/games.md#bundled-configs).
