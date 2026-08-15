# RCON

Sending commands to a running server.

## Set a password first

**RCON is disabled out of the box.** Every bundled config ships `rcon_password ""`, deliberately — a password shipped inside a public image is a password everyone has, on a port anyone can find by scanning.

Two ways to set one:

```yaml
environment:
  PLUTAINER_RCON_PASSWORD: "something-only-you-know"
```

or edit `app/configs/<your>.cfg` directly and restart.

`PLUTAINER_RCON_PASSWORD` is opt-in and never destructive: leave it unset (or empty, which is what an unfilled compose variable looks like) and your config is untouched, so a password you set by hand is never wiped. When set, it rewrites the value on the existing `rcon_password` line — keeping any trailing `//` comment — or appends one if there isn't a line.

The healthcheck does **not** need any of this; it uses an unauthenticated status query.

> **CoD4x rejects passwords shorter than 8 characters.** It answers
> `No rconpassword set on server or password is shorter than 8 characters`
> and ignores the command — which looks exactly like a wrong password.

## rcon-cli

Built into the image. It works out which game, port and password to use by itself:

```sh
# one-shot
docker exec t6zm-1 rcon-cli status

# interactive session
docker exec -i t6zm-1 rcon-cli
```

```
> status
map: zm_buried
num score bot ping guid                             name             address
--- ----- --- ---- -------------------------------- ---------------- --------
```

## Password formats it understands

In your cfg, all of these parse:

```
set  rcon_password "your_password_here"
seta rcon_password 'also_works'
set  rcon_password unquoted_also_ok
```

Commented lines (`// …`) are ignored. If several uncommented `rcon_password` lines exist, the last wins. Set it via `PLUTAINER_EXTRA_ARGS` and Plutainer *cannot* read it back — `rcon-cli` and IW4MAdmin will both fail to authenticate.

## Who is allowed to send RCON

Loopback — which is where `rcon-cli` runs from, inside the container — always works.

From outside the container it depends on the game:

| Game | Off-container RCON |
| --- | --- |
| T4, IW5, IW4x, T7x, CoD4x | allowed once a password is set |
| **T5, T6** | only from whitelisted addresses |

For T5/T6 Plutainer automatically whitelists the container's Docker gateway at startup, which is the address a sidecar admin tool appears to come from. If your admin tool is on **another machine**, add it:

```yaml
environment:
  PLUTAINER_RCON_WHITELIST: "10.10.1.20,10.10.1.21"
```

Only single addresses are accepted — a CIDR range like `172.16.0.0/12` is rejected by the engine with `Error: Invalid address`.

The full explanation, including why this bites IW4MAdmin specifically, is in [IW4MAdmin](iw4madmin.md#the-whitelist-rule-that-catches-everyone).

## Rate limiting

T5 and T6 configs ship `rcon_rate_limit "500"` (milliseconds, per IP). If you use IW4MAdmin's Game Interface and see dropped commands, lowering it to `100` is the usual fix — upstream's own comment says so.
