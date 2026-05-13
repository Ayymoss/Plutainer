#!/bin/bash
#
# Shared game configuration library.
# Sourced by entrypoint scripts, healthcheck, and rcon-cli.
#
# Volume layout (v2):
#   /home/plutainer/app/
#     configs/                         # User-facing config files (flat).
#                                      # Real files. Engine paths symlink here.
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

# Map old-prefix env vars (PLUTO_*, IW4X_*, ALTER_*) to canonical PLUTAINER_*
# names. Only sets PLUTAINER_<SUFFIX> if it is currently unset. Emits a single
# deprecation warning per old name that's actually being used.
shim_env_vars() {
  local suffix prefix old new
  for suffix in GAME CONFIG_FILE PORT SERVER_NAME MOD AUTO_UPDATE HEALTHCHECK SKIP_SEED EXTRA_ARGS; do
    new="PLUTAINER_$suffix"
    [[ -n "${!new:-}" ]] && continue
    for prefix in PLUTO IW4X ALTER; do
      old="${prefix}_${suffix}"
      if [[ -n "${!old:-}" ]]; then
        printf -v "$new" '%s' "${!old}"
        export "$new"
        echo "[DEPRECATED] ${old} is renamed to ${new}; old name still accepted for now." >&2
        break
      fi
    done
  done
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
# HEALTHCHECK_FLAG from PLUTAINER_* (applying back-compat shims first).
detect_game_type() {
  shim_env_vars

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
# from. Entrypoints place symlinks here that point back into PLUTAINER_CONFIGS_DIR.
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

# Set CONFIG_PATH to the user-facing real config file in configs/.
# Requires CONFIG_FILE to be set.
resolve_config_path() {
  CONFIG_PATH="$PLUTAINER_CONFIGS_DIR/${CONFIG_FILE}"
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
#     (cfg_root_rel within the seed bundle) are placed flat in app/configs/
#     so the user can edit them all in one directory.
#   - Everything else (assets, mod scripts, nested cfgs, etc) is placed under
#     asset_root, preserving the seed's relative path.
# Always idempotent: never overwrites a file that already exists.
# Args: <game-key> <asset_root> <cfg_root_rel>
#   game-key:     subdir under .plutainer/seed-configs/ to read from
#   asset_root:   destination for non-flat-cfg assets (typically runtime/...)
#   cfg_root_rel: path within the seed (and within asset_root) where the
#                 engine reads top-level cfg files. Use "" if the seed root
#                 IS the engine config dir.
seed_configs() {
  local game="$1" asset_root="$2" cfg_root_rel="${3:-}"
  local src="/home/plutainer/.plutainer/seed-configs/${game}"
  [[ -d "$src" ]] || return 0
  mkdir -p "$asset_root" "$PLUTAINER_CONFIGS_DIR"

  local rel parent dest
  while IFS= read -r -d '' relpath; do
    rel="${relpath#./}"
    parent="$(dirname "$rel")"
    [[ "$parent" == "." ]] && parent=""
    if [[ "$rel" == *.cfg && "$parent" == "$cfg_root_rel" ]]; then
      dest="$PLUTAINER_CONFIGS_DIR/$(basename "$rel")"
    else
      dest="$asset_root/$rel"
    fi
    mkdir -p "$(dirname "$dest")"
    [[ -e "$dest" ]] || cp "$src/$rel" "$dest"
  done < <(cd "$src" && find . -type f -print0)
}

# Place a symlink in <engine_config_dir>/<basename> for every *.cfg file in
# app/configs/. Symlinks are relative so they resolve the same on host or in
# sidecar containers. Removes dangling cfg symlinks that point into configs/
# but whose source has been deleted.
# Args: <engine_config_dir>
link_configs() {
  local engine_config_dir="$1"
  [[ -d "$PLUTAINER_CONFIGS_DIR" ]] || return 0
  mkdir -p "$engine_config_dir"

  local f base link target_rel
  for f in "$PLUTAINER_CONFIGS_DIR"/*.cfg; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    link="$engine_config_dir/$base"
    target_rel=$(realpath --relative-to="$engine_config_dir" "$f")
    ln -sfn "$target_rel" "$link"
  done

  for link in "$engine_config_dir"/*.cfg; do
    [[ -L "$link" && ! -e "$link" ]] || continue
    echo "[link_configs] reaping dangling: $link" >&2
    rm -f "$link"
  done
}

# Check that the mounted app/ volume is v2-shaped. On a fresh volume,
# initialise it. On a v1 volume, refuse to start with explicit migration
# instructions. On a v2 volume, just ensure the expected dirs exist.
check_volume_version() {
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
    cat >&2 <<'EOF'
========================================================================
[ERROR] v1 volume layout detected. This image (Plutainer v2) uses a new
layout that places user-editable configs in a single, predictable
directory.

  v1 layout:                          v2 layout:
    app/gamefiles/                      app/configs/        (your cfgs)
    app/plutonium/                      app/runtime/gamefiles/
    app/logs/                           app/runtime/plutonium/
                                        app/logs/

To migrate this volume, stop the container and run the bundled migration
tool against your bind mount:

  docker run --rm \
    -v <YOUR_APP_VOLUME>:/home/plutainer/app \
    --entrypoint /home/plutainer/.plutainer/migrate-v1-to-v2.sh \
    ghcr.io/ayymoss/plutainer:main

(For a docker-compose deployment, <YOUR_APP_VOLUME> is the path bound to
/home/plutainer/app — e.g. ./t6zm-1)

The tool moves files in place; configs become symlinks back into the new
app/configs/ tree. No data is deleted. Re-run with --dry-run to preview.

Refusing to start to avoid corrupting your data.
========================================================================
EOF
    return 1
  fi

  # Fresh volume — initialise v2.
  mkdir -p "$PLUTAINER_CONFIGS_DIR" "$PLUTAINER_APP_DIR/logs" "$PLUTAINER_RUNTIME_DIR"
  echo "$PLUTAINER_VOLUME_VERSION" > "$marker"
  echo "[INFO] Initialised fresh v2 volume at $PLUTAINER_APP_DIR"
}

# Extract the RCON password from the user's config file in configs/.
# Sets RCON_PASSWORD. Requires CONFIG_PATH to be set.
extract_rcon_password() {
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    echo "[ERROR] Config file not found at ${CONFIG_PATH}" >&2
    return 1
  fi
  RCON_PASSWORD=$(grep -v '^[[:space:]]*//' "${CONFIG_PATH}" | grep -i 'rcon_password' | sed -n 's/.*"\([^"]*\)".*/\1/p' | tail -1)
  if [[ -z "${RCON_PASSWORD}" ]]; then
    echo "[ERROR] Could not find 'rcon_password' in ${CONFIG_PATH}" >&2
    return 1
  fi
}
