#!/bin/bash
#
# Validate environment, prepare the game-files tree and configs/ symlinks,
# update iw4x via the iw4x-launcher, then launch the iw4x server.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/game-config.sh"

detect_game_type || exit 1
check_volume_version || exit 1
resolve_engine_config_dir || exit 1

SOURCE_DIR="$PLUTAINER_SOURCE_DIR"
DEST_DIR="$PLUTAINER_GAMEFILES_DIR"
mkdir -p "$DEST_DIR"

# --- Step 1: Link Game Files ---
echo "Linking files for iw4x..."
link_files "$SOURCE_DIR" "$DEST_DIR" main zone binkw32.dll localization.txt mss32.dll

# --- Step 2: Update iw4x ---
IW4X_CACHE_LOC="$DEST_DIR/launcher/cache.json"
if [[ -f "$IW4X_CACHE_LOC" && "${PLUTAINER_AUTO_UPDATE:-}" == "false" ]]; then
  echo "Skipping iw4x update because PLUTAINER_AUTO_UPDATE is set to 'false'."
else
  if [[ -f "$IW4X_CACHE_LOC" ]]; then
    echo "Checking for iw4x updates..."
  else
    echo "First container run detected. Downloading iw4x initial files..."
  fi
  /home/plutainer/.plutainer/iw4x-launcher --path "$DEST_DIR" --skip-launch --no-self-update
fi

cd "$DEST_DIR"

# --- Step 3: Fan-out configs/ → engine config dir ---
# No seed_configs call: iw4x has no bundled community seed.
link_configs "$ENGINE_CONFIG_DIR"

# --- Step 4: Validate Required Environment Variables ---
MISSING_VAR=false
PLUTAINER_SERVER_NAME="${PLUTAINER_SERVER_NAME:-IW4x Docker Server}"

if [[ "${PLUTAINER_GAME}" != "iw4x" ]]; then
  echo "[ERROR] PLUTAINER_GAME must be 'iw4x' for the iw4x entrypoint." >&2
  MISSING_VAR=true
fi
if [[ -z "${PLUTAINER_CONFIG_FILE:-}" ]]; then
  echo "[ERROR] PLUTAINER_CONFIG_FILE is not set." >&2
  echo "  > Filename of your server config (e.g. 'server.cfg')." >&2
  MISSING_VAR=true
fi

if [[ "$MISSING_VAR" == "true" ]]; then
  echo "-------------------------------------------------" >&2
  echo "Configuration error. Halting startup." >&2
  sleep 10
  exit 1
fi

# --- Step 5: Resolve port ---
if [[ -z "${PLUTAINER_PORT:-}" ]]; then
  echo "PLUTAINER_PORT not set, using default for iw4x..."
  resolve_default_port "iw4x" || { sleep 10; exit 1; }
  PLUTAINER_PORT="${DEFAULT_PORT}"
  echo "Default port set to ${PLUTAINER_PORT}"
fi

# --- Step 6: Build Server Command Arguments ---
declare -a CMD_ARGS=(
    -dedicated
    -stdout
    +set sv_lanonly "0"
    +set net_port "${PLUTAINER_PORT}"
    +exec "${PLUTAINER_CONFIG_FILE}"
    +set logfile "1"
    +set party_enable "0"
)

if [[ -n "${PLUTAINER_MOD:-}" ]]; then
    CMD_ARGS+=(+set fs_game "${PLUTAINER_MOD}")
fi
if [[ -n "${IW4X_NET_LOG_IP:-}" ]]; then
    CMD_ARGS+=(+set g_log_add "${IW4X_NET_LOG_IP}")
fi
if [[ -n "${PLUTAINER_EXTRA_ARGS:-}" ]]; then
    CMD_ARGS+=(${PLUTAINER_EXTRA_ARGS})
fi

CMD_ARGS+=(+map_rotate)

# --- Step 7: Launch ---
/home/plutainer/.plutainer/log-watcher.sh &

echo "Starting iw4x Server: ${PLUTAINER_SERVER_NAME}"
echo "EXECUTING: wine iw4x.exe ${CMD_ARGS[*]}"
exec wine iw4x.exe "${CMD_ARGS[@]}"
