#!/bin/bash
#
# Shared game configuration library.
# Sourced by entrypoint scripts, healthcheck, and rcon-cli.
#
# Volume layout (v2):
#   /home/plutainer/app/
#     configs/                         # User-facing config files (flat).
#                                      # Real files unless PLUTAINER_USE_RAW_CONFIGS=true.
#     logs/                            # Stable symlinks to active *.log files
#                                      # (maintained by log-watcher.sh).
#     runtime/
#       gamefiles/                     # Symlinks into host /home/plutainer/gamefiles
#                                      # plus writable game state.
#       plutonium/                     # Plutonium binaries + storage state.
#     .plutainer-version               # Layout marker (contains "2").
#

PLUTAINER_VOLUME_VERSION=2
PLUTAINER_APP_DIR="/home/plutainer/app"
PLUTAINER_CONFIGS_DIR="$PLUTAINER_APP_DIR/configs"
PLUTAINER_RUNTIME_DIR="$PLUTAINER_APP_DIR/runtime"
PLUTAINER_GAMEFILES_DIR="$PLUTAINER_RUNTIME_DIR/gamefiles"
PLUTAINER_PLUTONIUM_DIR="$PLUTAINER_RUNTIME_DIR/plutonium"
PLUTAINER_SOURCE_DIR="/home/plutainer/gamefiles"

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

# Run the game binary, then sleep 30s before letting the container exit.
# Restart policies (e.g. `restart: unless-stopped`) react to container exit
# but docker compose has no native min-delay knob — the in-script sleep is
# how we throttle real crashes to one restart per ~30s.
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

# Derive the game family ("plutonium", "iw4x", "alterware") from PLUTAINER_GAME.
# Returns 1 if unknown.
derive_family() {
  case "$1" in
    iw5mp|t4mp|t4sp|t5mp|t5sp|t6mp|t6zm) echo "plutonium" ;;
    iw4x)                                echo "iw4x" ;;
    t7x)                                 echo "alterware" ;;
    *)                                   return 1 ;;
  esac
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

  case "$GAME_TYPE" in
    plutonium) BASE_GAME="${GAME_NAME%??}" ;;
    iw4x)      BASE_GAME="iw4x" ;;
    alterware) BASE_GAME="${GAME_NAME}" ;;
  esac

  CONFIG_FILE="${PLUTAINER_CONFIG_FILE:-}"
  CUSTOM_PORT="${PLUTAINER_PORT:-}"
  HEALTHCHECK_FLAG="${PLUTAINER_HEALTHCHECK:-}"
}

# Set DEFAULT_PORT based on BASE_GAME (or the arg).
resolve_default_port() {
  local base_game="${1:-$BASE_GAME}"
  case "${base_game}" in
    "iw4x")      DEFAULT_PORT="28960" ;;
    "iw5")       DEFAULT_PORT="27016" ;;
    "t4" | "t5") DEFAULT_PORT="28960" ;;
    "t6")        DEFAULT_PORT="4976"  ;;
    "t7x")       DEFAULT_PORT="27017" ;;
    *)
      echo "[ERROR] Could not determine default port for game '${base_game}'." >&2
      return 1
      ;;
  esac
}

# Set ENGINE_CONFIG_DIR — the directory where the game engine reads cfg files
# from. Entrypoints place symlinks here that point back into CONFIG_SOT_DIR
# (unless PLUTAINER_USE_RAW_CONFIGS is true, in which case engine path IS the SOT).
resolve_engine_config_dir() {
  case "${GAME_TYPE}" in
    plutonium)
      case "${BASE_GAME}" in
        t4)  ENGINE_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/main" ;;
        iw5) ENGINE_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/admin" ;;
        *)   ENGINE_CONFIG_DIR="$PLUTAINER_PLUTONIUM_DIR/storage/${BASE_GAME}" ;;
      esac
      ;;
    iw4x)      ENGINE_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/userraw" ;;
    alterware) ENGINE_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/zone" ;;
    *)
      echo "[ERROR] Unknown game type '${GAME_TYPE}'." >&2
      return 1
      ;;
  esac
}

# Set MOD_CONFIG_DIR — the dir where the game looks for cfg files inside the
# active mod (fs_game), if PLUTAINER_MOD is set. Empty when no mod or N/A
# (e.g. alterware uses Steam Workshop IDs, not filesystem paths).
resolve_mod_config_dir() {
  MOD_CONFIG_DIR=""
  [[ -z "${PLUTAINER_MOD:-}" ]] && return 0
  case "$GAME_TYPE" in
    plutonium)
      case "$BASE_GAME" in
        t4|iw5) MOD_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/$PLUTAINER_MOD" ;;
        *)      MOD_CONFIG_DIR="$PLUTAINER_PLUTONIUM_DIR/storage/$BASE_GAME/$PLUTAINER_MOD" ;;
      esac
      ;;
    iw4x)
      MOD_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/$PLUTAINER_MOD"
      ;;
    # alterware: PLUTAINER_MOD is a Steam Workshop ID; no filesystem cfg dir.
  esac
}

# Decide the config source-of-truth. Default: configs/ (symlink fan-out to
# engine dir). With PLUTAINER_USE_RAW_CONFIGS=true: engine dir IS the SOT
# (no symlinks, cfgs live where the game reads them).
# Requires ENGINE_CONFIG_DIR set first (call resolve_engine_config_dir).
# Sets CONFIG_SOT_DIR, ALT_CONFIG_DIR, CONFIG_PATH.
resolve_config_layout() {
  if [[ "${PLUTAINER_USE_RAW_CONFIGS:-}" == "true" ]]; then
    CONFIG_SOT_DIR="$ENGINE_CONFIG_DIR"
    ALT_CONFIG_DIR="$PLUTAINER_CONFIGS_DIR"
  else
    CONFIG_SOT_DIR="$PLUTAINER_CONFIGS_DIR"
    ALT_CONFIG_DIR="$ENGINE_CONFIG_DIR"
  fi
  CONFIG_PATH="$CONFIG_SOT_DIR/$CONFIG_FILE"
}

# Convenience for callers (healthcheck.sh, rcon-cli) that only need
# CONFIG_PATH set. Runs the chain end-to-end.
resolve_config_path() {
  resolve_engine_config_dir || return 1
  resolve_config_layout
}

# Symlink specific named entries from a source dir into a destination dir.
# Skips (with a warning) any names that don't exist — avoids the dangling
# symlink trap that bash brace expansion `{a,b,c}` creates when files are
# missing. Existing dest entries are replaced (ln -sf).
# Usage: link_files <source_dir> <dest_dir> <name1> [name2 ...]
link_files() {
  local src="$1" dest="$2"
  shift 2
  local name
  for name in "$@"; do
    if [[ -e "$src/$name" ]]; then
      ln -sf "$src/$name" "$dest/"
    else
      echo "[WARN] missing $src/$name — skipping symlink" >&2
    fi
  done
}

# Copy bundled community seed configs into the volume on first run.
# Strategy:
#   - Top-level *.cfg files inside the seed's "config root" subdir
#     (cfg_root_rel within the seed bundle) land in CONFIG_SOT_DIR.
#   - Everything else (assets, mod scripts, nested cfgs, etc) lands under
#     asset_root, preserving the seed's relative path.
# Always idempotent: never overwrites a file that already exists.
# Args: <game-key> <asset_root> <cfg_root_rel>
seed_configs() {
  local game="$1" asset_root="$2" cfg_root_rel="${3:-}"
  local src="/home/plutainer/.plutainer/seed-configs/${game}"
  [[ -d "$src" ]] || return 0
  mkdir -p "$asset_root" "$CONFIG_SOT_DIR"

  local rel parent dest
  while IFS= read -r -d '' relpath; do
    rel="${relpath#./}"
    parent="$(dirname "$rel")"
    [[ "$parent" == "." ]] && parent=""
    if [[ "$rel" == *.cfg && "$parent" == "$cfg_root_rel" ]]; then
      dest="$CONFIG_SOT_DIR/$(basename "$rel")"
    else
      dest="$asset_root/$rel"
    fi
    mkdir -p "$(dirname "$dest")"
    [[ -e "$dest" ]] || cp "$src/$rel" "$dest"
  done < <(cd "$src" && find . -type f -print0)
}

# For every *.cfg in configs/, place a relative symlink at each provided
# engine dir. Skips dirs that don't exist; warns on real-file collisions
# (refuses to overwrite a non-symlink); reaps cfg symlinks under each engine
# dir whose target no longer exists.
# No-op when PLUTAINER_USE_RAW_CONFIGS is true (engine path IS the SOT).
# Args: <engine_dir1> [engine_dir2 ...]
link_configs() {
  [[ "${PLUTAINER_USE_RAW_CONFIGS:-}" == "true" ]] && return 0
  [[ -d "$PLUTAINER_CONFIGS_DIR" ]] || return 0

  local engine_dir f base link target_rel
  for engine_dir in "$@"; do
    [[ -n "$engine_dir" ]] || continue
    mkdir -p "$engine_dir"

    # Fan-out: configs/<X>.cfg -> engine_dir/<X>.cfg
    for f in "$PLUTAINER_CONFIGS_DIR"/*.cfg; do
      [[ -e "$f" ]] || continue
      base="$(basename "$f")"
      link="$engine_dir/$base"
      if [[ -e "$link" && ! -L "$link" ]]; then
        echo "[link_configs] WARNING: real file at $link blocks symlink to $f" >&2
        echo "  Move or delete the real file if you want it managed via configs/." >&2
        continue
      fi
      target_rel=$(realpath --relative-to="$engine_dir" "$f")
      ln -sfn "$target_rel" "$link"
    done

    # Reap: drop cfg symlinks here whose source no longer resolves.
    for link in "$engine_dir"/*.cfg; do
      [[ -L "$link" && ! -e "$link" ]] || continue
      echo "[link_configs] reaping dangling: $link" >&2
      rm -f "$link"
    done
  done
}

# If the user has placed a REAL (non-symlink) cfg file at the engine path,
# treat that as authoritative and move it into the SOT location. Engine-path
# real file is the strongest signal of user intent: they manually wrote it
# where the game reads from. Overrides anything already in SOT.
# Runs BEFORE seed_configs so seed (cp -n) doesn't paper over user intent.
# Requires CONFIG_SOT_DIR, ALT_CONFIG_DIR, CONFIG_FILE set.
auto_lift_user_config() {
  local cfg="${CONFIG_FILE:-}"
  [[ -z "$cfg" ]] && return 0
  [[ "${PLUTAINER_USE_RAW_CONFIGS:-}" == "true" ]] && return 0

  local alt_path="$ALT_CONFIG_DIR/$cfg"
  local sot_path="$CONFIG_SOT_DIR/$cfg"

  if [[ -f "$alt_path" && ! -L "$alt_path" ]]; then
    echo "[INFO] Auto-lift: real file at $alt_path — moving to $sot_path (v2 SOT)."
    mkdir -p "$CONFIG_SOT_DIR"
    mv -f "$alt_path" "$sot_path"
  fi
}

# Verify $CONFIG_FILE exists at the SOT location. Returns 1 with a
# case-insensitive find hint if absent. Run AFTER seed_configs + link_configs
# so any gap-fill has had its chance.
# Requires CONFIG_SOT_DIR, ALT_CONFIG_DIR, CONFIG_FILE set.
ensure_config_present() {
  local cfg="$CONFIG_FILE"
  local sot_path="$CONFIG_SOT_DIR/$cfg"

  if [[ -e "$sot_path" ]]; then
    return 0
  fi

  echo "[ERROR] PLUTAINER_CONFIG_FILE='$cfg' but no such file exists." >&2
  echo "  Looked at:" >&2
  echo "    $sot_path" >&2
  echo "    $ALT_CONFIG_DIR/$cfg" >&2
  local match
  match=$(find "$CONFIG_SOT_DIR" "$ALT_CONFIG_DIR" -maxdepth 1 -type f -iname "$cfg" 2>/dev/null | head -1)
  if [[ -n "$match" ]]; then
    echo "  Did you mean: $(basename "$match") ? (filenames are case-sensitive on Linux)" >&2
  else
    echo "  Available cfgs in $CONFIG_SOT_DIR/:" >&2
    if compgen -G "$CONFIG_SOT_DIR/*.cfg" > /dev/null; then
      (cd "$CONFIG_SOT_DIR" && ls -1 *.cfg) | sed 's/^/    /' >&2
    else
      echo "    (none)" >&2
    fi
  fi
  return 1
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

_rcon_missing_warning() {
  echo "[WARN] Could not parse rcon_password from ${CONFIG_PATH}." >&2
  echo "  Healthcheck and rcon-cli will not work until this is set." >&2
  echo "  Expected format in your cfg file:" >&2
  echo "    set rcon_password \"your_password_here\"" >&2
  echo "  Single quotes and unquoted values are accepted; commented (//) lines are ignored." >&2
  echo "  Do NOT set rcon_password via PLUTAINER_EXTRA_ARGS — Plutainer cannot read it back." >&2
}

# Extract the RCON password from the user's config file. Handles:
#   set  rcon_password "value"      (double-quoted, default)
#   seta rcon_password 'value'      (single-quoted)
#   set  rcon_password value        (unquoted; value is first token)
#   rcon_password "value"           (bare; T6/T7 community cfgs do this)
# Strips line comments (//...) before searching. Picks the last uncommented
# match, in case the cfg overrides itself.
# Sets RCON_PASSWORD on success; returns 1 + warning on failure.
extract_rcon_password() {
  RCON_PASSWORD=""
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    echo "[WARN] Config file not found at ${CONFIG_PATH} — cannot extract rcon_password." >&2
    return 1
  fi

  local line
  line=$(sed -e 's|//.*$||' "${CONFIG_PATH}" \
    | grep -iE '^[[:space:]]*(set[a]?[[:space:]]+)?rcon_password[[:space:]]+' \
    | tail -1)

  if [[ -z "$line" ]]; then
    _rcon_missing_warning
    return 1
  fi

  local dq_pat='"([^"]*)"'
  local sq_pat="'([^']*)'"
  if [[ "$line" =~ $dq_pat ]]; then
    RCON_PASSWORD="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ $sq_pat ]]; then
    RCON_PASSWORD="${BASH_REMATCH[1]}"
  else
    # Unquoted: value is the token immediately after 'rcon_password'.
    # Strip optional 'set'/'seta' prefix so $2 is always the value.
    RCON_PASSWORD=$(echo "$line" | awk '{ if ($1 ~ /^[Ss][Ee][Tt][Aa]?$/) print $3; else print $2 }')
  fi

  if [[ -z "$RCON_PASSWORD" ]]; then
    _rcon_missing_warning
    return 1
  fi
}
