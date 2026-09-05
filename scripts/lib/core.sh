#!/bin/bash
#
# Shared core library: volume paths, family detection, process lifecycle.
# Sourced by entrypoint scripts, healthcheck, and rcon-cli.
#
# There are three families, and they are *platforms* rather than engines:
#
#   cod     Quake-derived servers Plutainer installs and runs itself
#           (Plutonium, IW4x, Alterware, CoD4x). You supply the game files.
#   steam   Servers SteamCMD installs (7DTD, CS2, L4D2, HL2:DM). You supply
#           nothing.
#   nebula  Dyson Sphere Program under Wine with the Nebula multiplayer mod.
#           You supply the owned game files; Plutainer installs the mod stack.
#
# Engine variation lives *below* the family, as a field in that family's game
# table, because it does not change how Plutainer treats the server: a
# Plutonium T6 and a CoD4x server differ far less from each other than either
# does from a SteamCMD install.
#
# Each family owns one file, one entry script, and one game table:
#   lib/fs.sh     symlink/mirroring helpers, shared by all families
#   lib/cod.sh    the cod family
#   lib/steam.sh  the steam family
#   lib/nebula.sh the nebula family
#
# Volume layout (v2):
#   /home/plutainer/app/
#     configs/                         # User-facing config files (flat).
#                                      # Real files unless PLUTAINER_USE_RAW_CONFIGS=true.
#     logs/                            # Stable symlinks to active *.log files
#                                      # (maintained by log-watcher.sh).
#     runtime/
#       gamefiles/                     # Symlinks into host /home/plutainer/gamefiles
#                                      # plus writable game state.  [CoD families]
#       plutonium/                     # Plutonium binaries + storage state.
#       steam/<game>/                  # SteamCMD-managed install.   [Steam family]
#       gamedata/<game>/               # Worlds, saves, mods — never
#                                      # touched by SteamCMD.        [Steam family]
#       nebula/<game>/                 # Writable DSP + BepInEx overlay.
#     .plutainer-version               # Layout marker (contains "2").
#

PLUTAINER_VOLUME_VERSION=2
PLUTAINER_APP_DIR="/home/plutainer/app"
PLUTAINER_CONFIGS_DIR="$PLUTAINER_APP_DIR/configs"
PLUTAINER_RUNTIME_DIR="$PLUTAINER_APP_DIR/runtime"
PLUTAINER_GAMEFILES_DIR="$PLUTAINER_RUNTIME_DIR/gamefiles"
PLUTAINER_PLUTONIUM_DIR="$PLUTAINER_RUNTIME_DIR/plutonium"
PLUTAINER_SOURCE_DIR="/home/plutainer/gamefiles"

# SteamCMD family. The install and the persistent data are kept apart on
# purpose: SteamCMD owns everything under steam/ and may delete or replace any
# of it on an update, so nothing the user cares about is allowed to live there.
PLUTAINER_STEAM_DIR="$PLUTAINER_RUNTIME_DIR/steam"
PLUTAINER_GAMEDATA_DIR="$PLUTAINER_RUNTIME_DIR/gamedata"
PLUTAINER_NEBULA_DIR="$PLUTAINER_RUNTIME_DIR/nebula"

# Halt without exiting. Container stays in the "running" state, docker
# restart policies won't fire a loop, healthchecks will eventually mark it
# unhealthy — user fixes config and runs `docker restart`.
hold_indefinitely() {
  local msg="${1:-Refusing to start.}"
  echo "-------------------------------------------------" >&2
  echo "$msg" >&2
  echo "[INFO] Holding container running (sleep infinity) to prevent a restart loop." >&2
  echo "[INFO] Fix the issue, then run: docker restart <container>" >&2
  exec sleep infinity
}

# Run the game binary in the foreground, then sleep 30s before letting the
# container exit.
# Restart policies (e.g. `restart: unless-stopped`) react to container exit
# but docker compose has no native min-delay knob — the in-script sleep is
# how we throttle real crashes to one restart per ~30s.
#
# The image's STOPSIGNAL is SIGKILL, so `docker stop` never reaches this
# function: docker kills the container outright and the CoD engines lose
# nothing by it. A game that DOES have state to flush on shutdown uses
# launch_game_graceful below instead, and asks for SIGTERM in its compose file.
# Args: command + its arguments (e.g. wine ...).
launch_game() {
  set +e
  "$@"
  local rc=$?
  set -e

  echo "[INFO] Game process exited (rc=$rc)." >&2
  echo "[INFO] Sleeping 30s before container exit to throttle restart." >&2
  sleep 30
  exit "$rc"
}

# As launch_game, but forwards SIGTERM to the game so it can shut down cleanly.
#
# Why this is separate rather than folded into launch_game: SIGKILL cannot be
# trapped, so a game that must flush state on stop can only be served by the
# container receiving SIGTERM — which means changing the image's STOPSIGNAL for
# everything, or letting the one game that needs it ask for SIGTERM per service:
#
#     stop_signal: SIGTERM
#     stop_grace_period: 90s
#
# The second costs one line in a compose file and changes nothing for the seven
# CoD servers people are already running, so that is what we do. Without those
# lines the container still stops correctly — instantly, without the clean save.
#
# The hang case needs no code: docker sends SIGKILL itself once
# stop_grace_period expires, so a game that ignores SIGTERM cannot wedge a stop.
#
# Args: command + its arguments.
launch_game_graceful() {
  launch_game_graceful_signal TERM "$@"
}

# Graceful wrapper with an explicit signal for the child. Most native servers
# want SIGTERM; Wine-hosted Nebula documents Ctrl+C/SIGINT as its save-and-exit
# path, while the container still receives the compose service's SIGTERM.
# Args: <child-signal> <command> [arguments...]
launch_game_graceful_signal() {
  local child_signal="$1"
  shift
  set +e
  "$@" &
  local game_pid=$!
  local rc=0
  local stopping=false
  local stop_guard_pid=""

  # `wait` is interrupted by a trapped signal even while the child lives, so the
  # loop below re-enters it until the child has actually gone.
  # shellcheck disable=SC2317
  _forward_stop() {
    stopping=true
    trap - TERM INT
    if declare -F plutainer_graceful_stop_prepare >/dev/null 2>&1; then
      plutainer_graceful_stop_prepare
    fi
    echo "[INFO] Stop requested — forwarding SIG${child_signal} to ${GAME_NAME} (pid ${game_pid})."
    kill "-${child_signal}" "$game_pid" 2>/dev/null || true
    if declare -F plutainer_graceful_stop_finish >/dev/null 2>&1; then
      plutainer_graceful_stop_finish "$game_pid" &
      stop_guard_pid=$!
    fi
  }
  trap _forward_stop TERM INT

  while true; do
    wait "$game_pid"
    rc=$?
    kill -0 "$game_pid" 2>/dev/null || break
  done

  trap - TERM INT
  if [[ -n "$stop_guard_pid" ]]; then
    kill "$stop_guard_pid" 2>/dev/null || true
    wait "$stop_guard_pid" 2>/dev/null || true
  fi
  set -e

  if [[ "$stopping" == "true" ]]; then
    echo "[INFO] ${GAME_NAME} shut down cleanly."
    exit 0
  fi

  echo "[INFO] Game process exited (rc=$rc)." >&2
  echo "[INFO] Sleeping 30s before container exit to throttle restart." >&2
  sleep 30
  exit "$rc"
}

# Derive the game family from PLUTAINER_GAME.
# Returns 1 if unknown.
# Nothing is hardcoded here: each family owns its own game list, so adding a
# game is a one-file change that never has to be mirrored into the core.
derive_family() {
  cod_is_known_game   "$1" && { echo "cod";   return 0; }
  steam_is_known_game "$1" && { echo "steam"; return 0; }
  nebula_is_known_game "$1" && { echo "nebula"; return 0; }
  return 1
}

# --- Hooks ------------------------------------------------------------------
#
# Each family runs one entry script driven by a game table, and expresses
# per-game behaviour as functions named <family>_<hook>_<suffix>. Suffixes are
# tried most-specific first, so a game inherits its engine's behaviour and
# overrides only what genuinely differs:
#
#   cod_launch_t7x   ->  cod_launch_alterware
#   steam_seed_cs2   ->  steam_seed_srcds
#
# Run <family>_<hook>_<suffix> for the first suffix that exists; return 1 if
# none do.
plutainer_hook() {
  local family="$1" hook="$2"
  shift 2
  local suffix fn
  for suffix in "$@"; do
    [[ -n "$suffix" ]] || continue
    fn="${family}_${hook}_${suffix}"
    if declare -F "$fn" >/dev/null 2>&1; then
      "$fn"
      return 0
    fi
  done

  # Say so. Callers run under `set -e`, so a bare non-zero return here would
  # kill the entry script with no output at all — which is exactly how a
  # mis-passed suffix list once looked like a silent crash.
  echo "[WARN] No ${family}_${hook}_* hook for: $*" >&2
  return 1
}

plutainer_hook_exists() {
  local family="$1" hook="$2"
  shift 2
  local suffix
  for suffix in "$@"; do
    [[ -n "$suffix" ]] || continue
    declare -F "${family}_${hook}_${suffix}" >/dev/null 2>&1 && return 0
  done
  return 1
}

# Fail loudly at startup for a hook nobody implemented, instead of silently
# doing nothing at the point it was needed. Hook names are strings, so a typo is
# otherwise invisible until someone notices a server ignoring its config — which
# is exactly how the CS2 depot-config bug hid.
# Args: <family> <comma-separated suffixes> <required hook>...
plutainer_require_hooks() {
  local family="$1" suffixes="$2"
  shift 2
  local -a candidates
  IFS=',' read -ra candidates <<< "$suffixes"

  local hook
  local -a missing=()
  for hook in "$@"; do
    plutainer_hook_exists "$family" "$hook" "${candidates[@]}" || missing+=("$hook")
  done

  [[ ${#missing[@]} -eq 0 ]] && return 0

  echo "[ERROR] ${GAME_NAME}: nothing implements hook(s): ${missing[*]}" >&2
  echo "  Looked for ${family}_<hook>_<suffix> with suffix in: ${suffixes}" >&2
  echo "  This is a bug in Plutainer, not a problem with your configuration." >&2
  return 1
}

# Populate GAME_TYPE, GAME_NAME, BASE_GAME, CONFIG_FILE, CUSTOM_PORT,
# HEALTHCHECK_FLAG from PLUTAINER_*.
detect_game_type() {
  if [[ -z "${PLUTAINER_GAME:-}" ]]; then
    echo "[ERROR] No game specified. Set PLUTAINER_GAME (e.g. t6zm, iw4x, t7x)." >&2
    return 1
  fi

  GAME_NAME="${PLUTAINER_GAME}"
  GAME_TYPE="$(derive_family "$GAME_NAME")" || {
    echo "[ERROR] Unknown PLUTAINER_GAME value: '${GAME_NAME}'." >&2
    return 1
  }

  # Cleared first so a value can never leak in from a previous resolve — these
  # are globals, and healthcheck/rcon-cli resolve more than one thing per run.
  BASE_GAME=""
  COD_ENGINE=""
  STEAM_ENGINE=""
  NEBULA_ENGINE=""
  ENGINE_CONFIG_DIR=""
  MOD_CONFIG_DIR=""

  case "$GAME_TYPE" in
    cod)   cod_resolve_game   || return 1 ;;
    steam) steam_resolve_game || return 1 ;;
    nebula) nebula_resolve_game || return 1 ;;
  esac

  CONFIG_FILE="${PLUTAINER_CONFIG_FILE:-}"
  CUSTOM_PORT="${PLUTAINER_PORT:-}"
  HEALTHCHECK_FLAG="${PLUTAINER_HEALTHCHECK:-}"
}

# Set DEFAULT_PORT based on BASE_GAME (or the arg). SteamCMD games carry their
# port in the family table rather than here.
# Every family keeps its default port in its own table, so this is a lookup
# through whichever table is active rather than a second copy of the data.
resolve_default_port() {
  case "${GAME_TYPE}" in
    cod)   DEFAULT_PORT="$COD_DEFAULT_PORT" ;;
    steam) DEFAULT_PORT="$STEAM_DEFAULT_PORT" ;;
    nebula) DEFAULT_PORT="$NEBULA_DEFAULT_PORT" ;;
    *)
      echo "[ERROR] Could not determine default port for '${GAME_NAME}'." >&2
      return 1
      ;;
  esac
}

# The port this server actually uses. Resolved in one place so the entry script,
# the health check and rcon-cli cannot disagree about it.
resolve_active_port() {
  if [[ -n "${CUSTOM_PORT:-}" ]]; then
    if [[ ! "$CUSTOM_PORT" =~ ^[0-9]+$ ]] || (( CUSTOM_PORT < 1 || CUSTOM_PORT > 65535 )); then
      echo "[ERROR] PLUTAINER_PORT must be a port number between 1 and 65535, got '${CUSTOM_PORT}'." >&2
      return 1
    fi
    ACTIVE_PORT="$CUSTOM_PORT"
  else
    resolve_default_port || return 1
    ACTIVE_PORT="$DEFAULT_PORT"
  fi
}

# Resolve CONFIG_PATH (and the surrounding CONFIG_SOT_DIR/ALT_CONFIG_DIR) for
# whichever family is active. This is the entry point healthcheck.sh and
# rcon-cli use; entry scripts call the family functions directly.
resolve_config_path() {
  case "${GAME_TYPE}" in
    cod)   cod_resolve_config_path ;;
    steam) steam_resolve_config_path ;;
    nebula) nebula_resolve_config_path ;;
  esac
}

# Addresses worth trying when talking to our own server, in order.
#
# Loopback is right for everything except Source dedicated servers, which bind
# their query and RCON sockets to the container's interface address and simply
# do not answer on 127.0.0.1 — measured on HL2:DM: identical A2S query, timeout
# on loopback, full reply on the container IP, with the server perfectly
# healthy throughout. Rather than encode which engines behave which way, try
# loopback first (cheap, and correct for every other family) and fall back.
# `ip` rather than `hostname -i`: iproute2 is already a dependency here (the T5/T6
# gateway detection uses it) whereas Arch's `hostname` comes from inetutils,
# which this image does not install.
plutainer_query_hosts() {
  local -a hosts=("127.0.0.1")
  local addr
  while read -r addr; do
    [[ -n "$addr" && "$addr" != "127.0.0.1" ]] && hosts+=("$addr")
  done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]}')
  echo "${hosts[@]}"
}

# Resolve how rcon-cli should talk to this server, setting:
#
#   ADMIN_PROTOCOL   quake3 | source-rcon | telnet | none
#   ADMIN_PORT       TCP or UDP port, per protocol
#   ADMIN_PASSWORD   credential, possibly empty
#   ADMIN_HOSTS      addresses to try, in order (see plutainer_query_hosts)
#
# "none" is a legitimate answer — a game with no remote console at all — and
# rcon-cli says so rather than failing obscurely. Returns non-zero only if the
# game itself could not be resolved.
resolve_admin_endpoint() {
  ADMIN_PROTOCOL="none"
  ADMIN_PORT=""
  ADMIN_PASSWORD=""
  ADMIN_HOSTS="$(plutainer_query_hosts)"

  case "${GAME_TYPE}" in
    cod)   cod_resolve_admin_endpoint ;;
    steam) steam_resolve_admin_endpoint ;;
    nebula) nebula_resolve_admin_endpoint ;;
  esac
}
# Scan environment for v1-era legacy env var names. Populates
# LEGACY_ENVS_FOUND with each name that is set+non-empty. Returns 0 if none
# found (clean v2 env), 1 if any are present. Caller is responsible for
# printing the unified refusal block.
detect_legacy_env_vars() {
  LEGACY_ENVS_FOUND=()
  local v
  local legacy_names=(
    PLUTO_GAME PLUTO_CONFIG_FILE PLUTO_PORT PLUTO_HEALTHCHECK
    PLUTO_SKIP_SEED PLUTO_AUTO_UPDATE PLUTO_MOD PLUTO_SERVER_NAME PLUTO_EXTRA_ARGS
    IW4X_GAME IW4X_CONFIG_FILE IW4X_PORT IW4X_HEALTHCHECK
    IW4X_AUTO_UPDATE IW4X_MOD IW4X_SERVER_NAME IW4X_EXTRA_ARGS
    ALTER_GAME ALTER_CONFIG_FILE ALTER_PORT ALTER_HEALTHCHECK
    ALTER_SKIP_SEED ALTER_AUTO_UPDATE ALTER_MOD ALTER_SERVER_NAME ALTER_EXTRA_ARGS
  )
  for v in "${legacy_names[@]}"; do
    if [[ -n "${!v:-}" ]]; then
      LEGACY_ENVS_FOUND+=("$v")
    fi
  done
  [[ ${#LEGACY_ENVS_FOUND[@]} -eq 0 ]]
}

# Check the mounted app/ volume's layout state.
# Outcomes (silent on v1 detection — the unified refusal block is printed by
# entrypoint.sh via print_v1_migration_block):
#   - Marker present + matches PLUTAINER_VOLUME_VERSION: ensure expected dirs
#     exist, return 0.
#   - Marker present but version mismatch (e.g. future v3 marker under v2
#     image): print specific error, return 1.
#   - Marker absent + v1 layout dirs present: set V1_VOLUME_DETECTED=true,
#     return 1. No print.
#   - Marker absent + no v1 dirs: fresh volume — initialise as v2, return 0.
check_volume_version() {
  V1_VOLUME_DETECTED=false
  local marker="$PLUTAINER_APP_DIR/.plutainer-version"

  if [[ -f "$marker" ]]; then
    local v
    v="$(cat "$marker" 2>/dev/null || echo "")"
    if [[ "$v" != "$PLUTAINER_VOLUME_VERSION" ]]; then
      echo "[ERROR] Volume marker reports version '$v'; this image expects '$PLUTAINER_VOLUME_VERSION'." >&2
      echo "[ERROR] You appear to be running an older image against a newer volume, or vice-versa." >&2
      return 1
    fi
    mkdir -p "$PLUTAINER_CONFIGS_DIR" "$PLUTAINER_APP_DIR/logs" "$PLUTAINER_RUNTIME_DIR"
    return 0
  fi

  # Marker missing. Distinguish v1 volume vs fresh volume.
  if [[ -d "$PLUTAINER_APP_DIR/plutonium" || -d "$PLUTAINER_APP_DIR/gamefiles" ]]; then
    V1_VOLUME_DETECTED=true
    return 1
  fi

  # Fresh volume — initialise v2.
  mkdir -p "$PLUTAINER_CONFIGS_DIR" "$PLUTAINER_APP_DIR/logs" "$PLUTAINER_RUNTIME_DIR"
  echo "$PLUTAINER_VOLUME_VERSION" > "$marker"
  echo "[INFO] Initialised fresh v2 volume at $PLUTAINER_APP_DIR"
}

# Combined v1-deployment refusal block. Adapts to what was detected.
# Args: $1=has_legacy_env (true/false), $2=has_v1_volume (true/false).
# Reads LEGACY_ENVS_FOUND[] populated by detect_legacy_env_vars.
print_v1_migration_block() {
  local has_legacy_env="${1:-false}" has_v1_volume="${2:-false}"

  cat >&2 <<'HEADER'
========================================================================
[ERROR] Plutainer v2 cannot start against a v1 deployment.

Detected on this container:
HEADER

  if [[ "$has_legacy_env" == "true" ]]; then
    echo "  - Legacy env vars set: ${LEGACY_ENVS_FOUND[*]}" >&2
  fi
  if [[ "$has_v1_volume" == "true" ]]; then
    echo "  - v1 volume layout (app/plutonium/ or app/gamefiles/ present, no .plutainer-version marker)" >&2
  fi

  cat >&2 <<'PATHS'

You have two paths. Pick one.

────────────────────────────────────────────────────────────────────────
PATH A — Stay on v1 (frozen, no further updates)

  In your compose file, pin:
    image: ghcr.io/ayymoss/plutainer:v1-final

  Then: docker compose up -d
  Server starts as before. A deprecation banner will appear on every
  start until you migrate.

────────────────────────────────────────────────────────────────────────
PATH B — Migrate to v2 (recommended)

  1. docker compose down

  2. Migrate the volume layout (no data is deleted; --dry-run previews):
       docker run --rm \
         -v <YOUR_APP_VOLUME>:/home/plutainer/app \
         --entrypoint /home/plutainer/.plutainer/migrate-v1-to-v2.sh \
         ghcr.io/ayymoss/plutainer:v2

     <YOUR_APP_VOLUME> is the host path bound to /home/plutainer/app
     in your compose (e.g. ./t6zm-1).

  3. Rename env vars in your compose (mapping table — anything not listed
     here keeps its old name, e.g. PLUTO_SERVER_KEY is unchanged):
       PLUTO_GAME          → PLUTAINER_GAME
       PLUTO_CONFIG_FILE   → PLUTAINER_CONFIG_FILE
       PLUTO_PORT          → PLUTAINER_PORT
       PLUTO_HEALTHCHECK   → PLUTAINER_HEALTHCHECK
       PLUTO_MOD           → PLUTAINER_MOD
       PLUTO_SKIP_SEED     → PLUTAINER_SKIP_SEED
       PLUTO_AUTO_UPDATE   → PLUTAINER_AUTO_UPDATE
       PLUTO_SERVER_NAME   → PLUTAINER_SERVER_NAME
       PLUTO_EXTRA_ARGS    → PLUTAINER_EXTRA_ARGS
       IW4X_GAME           → PLUTAINER_GAME=iw4x
       IW4X_CONFIG_FILE    → PLUTAINER_CONFIG_FILE
       IW4X_PORT           → PLUTAINER_PORT
       IW4X_HEALTHCHECK    → PLUTAINER_HEALTHCHECK
       IW4X_MOD            → PLUTAINER_MOD
       IW4X_AUTO_UPDATE    → PLUTAINER_AUTO_UPDATE
       IW4X_SERVER_NAME    → PLUTAINER_SERVER_NAME
       IW4X_EXTRA_ARGS     → PLUTAINER_EXTRA_ARGS
       ALTER_GAME          → PLUTAINER_GAME (e.g. t7x)
       ALTER_CONFIG_FILE   → PLUTAINER_CONFIG_FILE
       ALTER_PORT          → PLUTAINER_PORT
       ALTER_HEALTHCHECK   → PLUTAINER_HEALTHCHECK
       ALTER_MOD           → PLUTAINER_MOD
       ALTER_SKIP_SEED     → PLUTAINER_SKIP_SEED
       ALTER_AUTO_UPDATE   → PLUTAINER_AUTO_UPDATE
       ALTER_SERVER_NAME   → PLUTAINER_SERVER_NAME
       ALTER_EXTRA_ARGS    → PLUTAINER_EXTRA_ARGS

     Full guide: https://github.com/Ayymoss/Plutainer/blob/main/MIGRATION.md

  4. docker compose up -d
========================================================================
PATHS
}

# --- Family libraries -------------------------------------------------------
#
# Sourced last so they can rely on everything above. All are always loaded:
# healthcheck.sh and rcon-cli dispatch on GAME_TYPE at runtime and need each
# set available. Keeping them in separate files is about where code is allowed
# to live, not about loading less of it — a CoD change should never require
# reading the Steam helpers, and vice versa.
PLUTAINER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PLUTAINER_LIB_DIR/fs.sh"
source "$PLUTAINER_LIB_DIR/cod.sh"
source "$PLUTAINER_LIB_DIR/steam.sh"
source "$PLUTAINER_LIB_DIR/nebula.sh"

# Every game tag this image accepts, for error messages. Assembled after the
# family libraries load so neither list has to be restated here.
PLUTAINER_KNOWN_GAMES="$(printf '%s, ' "${COD_GAMES[@]}" "${STEAM_GAMES[@]}" "${NEBULA_GAMES[@]}" | sed 's/, $//')"
