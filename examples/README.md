# Examples

Copy the one that matches what you're doing, adjust the paths, `docker compose up -d`.

| File | What it is |
| --- | --- |
| [`single-server.yml`](single-server.yml) | One server. Start here |
| [`per-game.yml`](per-game.yml) | One ready-made service block for **every** supported game — copy the ones you want |
| [`multi-server.yml`](multi-server.yml) | Several servers sharing one set of game files |
| [`with-iw4madmin.yml`](with-iw4madmin.yml) | Servers plus an IW4MAdmin sidecar |
| [`env.example`](env.example) | Keys and passwords, kept out of the compose file |

## The three things you must change

1. **The gamefiles path** — `/opt/game-files/…` in every example. Point it at your own copy.
2. **`PLUTAINER_CONFIG_FILE`** — must name a config Plutainer seeds for that game ([list](../docs/games.md#at-a-glance)).
3. **Ports** — one server per port. Publish UDP.

## Secrets

Put keys and RCON passwords in a `.env` file next to your compose file, and reference them as `${VARIABLE}`:

```
cp examples/env.example .env
```

`.env` is picked up automatically by `docker compose`. Don't commit it.

## New to this?

Read the [Quickstart](../docs/quickstart.md) first — it walks through the same thing with explanations.
