#!/bin/bash
#
# Validate environment, prepare the game-files tree and configs/ symlinks,
# update Plutonium binaries, then launch the requested Plutonium server.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/game-config.sh"

detect_game_type     || hold_indefinitely "detect_game_type failed."
check_volume_version || hold_indefinitely "check_volume_version failed."
resolve_engine_config_dir
resolve_mod_config_dir
resolve_config_layout

SOURCE_DIR="$PLUTAINER_SOURCE_DIR"
DEST_DIR="$PLUTAINER_GAMEFILES_DIR"
mkdir -p "$DEST_DIR"

# --- Step 1: Link Game Files ---
case "$BASE_GAME" in
  iw5)
    echo "Linking files for iw5 (Modern Warfare 3)..."
    link_files "$SOURCE_DIR" "$DEST_DIR" main miles zone binkw32.dll localization.txt mss32.dll
    ;;
  t4)
    echo "Linking files for t4 (World at War)..."
    link_files "$SOURCE_DIR" "$DEST_DIR" zone binkw32.dll localization.txt cod.bmp codlogo.bmp
    mkdir -p "$DEST_DIR/main"
    link_files "$SOURCE_DIR/main" "$DEST_DIR/main" \
      iw_00.iwd iw_14.iwd iw_21.iwd iw_22.iwd iw_24.iwd iw_26.iwd \
      localized_english_iw00.iwd localized_english_iw04.iwd
    ;;
  t5)
    echo "Linking files for t5 (Black Ops)..."
    link_files "$SOURCE_DIR" "$DEST_DIR" main zone binkw32.dll localization.txt
    ;;
  t6)
    echo "Linking files for t6 (Black Ops II)..."
    link_files "$SOURCE_DIR" "$DEST_DIR" zone binkw32.dll codlogo.bmp
    ;;
  *)
    hold_indefinitely "Unknown BASE_GAME value '$BASE_GAME'."
    ;;
esac

# --- Step 2: Update Plutonium ---
mkdir -p "$PLUTAINER_PLUTONIUM_DIR"
PLUTO_CDN_INFO_LOC="$PLUTAINER_PLUTONIUM_DIR/cdn_info.json"
if [[ -f "$PLUTO_CDN_INFO_LOC" && "${PLUTAINER_AUTO_UPDATE:-}" == "false" ]]; then
  echo "Skipping Plutonium update because PLUTAINER_AUTO_UPDATE is set to 'false'."
else
  if [[ -f "$PLUTO_CDN_INFO_LOC" ]]; then
    echo "Checking for Plutonium updates..."
  else
    echo "First container run detected. Downloading Plutonium initial files..."
  fi
  /home/plutainer/.plutainer/plutonium-updater --directory "$PLUTAINER_PLUTONIUM_DIR"
fi

cd "$PLUTAINER_PLUTONIUM_DIR"

# --- Step 3a: Auto-lift any user-placed real cfg from engine path ---
auto_lift_user_config

# --- Step 3b: Seed default configs from bundled community repos ---
if [[ "${PLUTAINER_SKIP_SEED:-}" != "true" ]]; then
  case "$BASE_GAME" in
    t4)    seed_configs t4 "$PLUTAINER_GAMEFILES_DIR/main"           "" ;;
    iw5)   seed_configs iw5 "$PLUTAINER_GAMEFILES_DIR/admin"         "" ;;
    t5|t6) seed_configs "$BASE_GAME" "$PLUTAINER_PLUTONIUM_DIR/storage/$BASE_GAME" "" ;;
  esac
fi

# --- Step 4: Fan-out configs/ → engine + mod config dirs ---
link_configs "$ENGINE_CONFIG_DIR" "$MOD_CONFIG_DIR"

# --- Step 5: Validate environment + ensure config file exists ---
PLUTAINER_SERVER_NAME="${PLUTAINER_SERVER_NAME:-Plutonium Docker Server}"
VALID_GAMES="iw5mp t4mp t4sp t5mp t5sp t6mp t6zm"

if [[ ! " ${VALID_GAMES} " =~ " ${PLUTAINER_GAME} " ]]; then
  hold_indefinitely "Invalid PLUTAINER_GAME for Plutonium: \"${PLUTAINER_GAME}\". Valid: ${VALID_GAMES}"
fi
if [[ -z "${PLUTO_SERVER_KEY:-}" ]]; then
  hold_indefinitely "PLUTO_SERVER_KEY is not set. Get a server key from https://platform.plutonium.pw/serverkeys"
fi
if [[ -z "${PLUTAINER_CONFIG_FILE:-}" ]]; then
  hold_indefinitely "PLUTAINER_CONFIG_FILE is not set. Specify the filename of your server config (e.g. 'dedicated.cfg')."
fi
if ! ensure_config_present; then
  hold_indefinitely "Config file not found. See [ERROR] above."
fi

# --- Step 6: Resolve port ---
if [[ -z "${PLUTAINER_PORT:-}" ]]; then
  echo "PLUTAINER_PORT not set, using default for ${BASE_GAME}..."
  resolve_default_port "${BASE_GAME}" || hold_indefinitely "Could not resolve default port."
  PLUTAINER_PORT="${DEFAULT_PORT}"
  echo "Default port set to ${PLUTAINER_PORT}"
fi

# --- Step 7: Build Server Command Arguments ---
declare -a CMD_ARGS=(
    "${PLUTAINER_GAME}"
    "$PLUTAINER_GAMEFILES_DIR"
    -dedicated
    +set key "${PLUTO_SERVER_KEY}"
    +set net_port "${PLUTAINER_PORT}"
)

if [[ "${BASE_GAME}" == "iw5" ]]; then
    CMD_ARGS+=(+set sv_config "${PLUTAINER_CONFIG_FILE}")
else
    CMD_ARGS+=(+exec "${PLUTAINER_CONFIG_FILE}")
fi

if [[ -n "${PLUTAINER_MOD:-}" ]]; then
    CMD_ARGS+=(+set fs_game "${PLUTAINER_MOD}")
fi
if [[ -n "${PLUTO_MAX_CLIENTS:-}" ]]; then
    CMD_ARGS+=(+set sv_maxclients "${PLUTO_MAX_CLIENTS}")
fi
if [[ -n "${PLUTAINER_EXTRA_ARGS:-}" ]]; then
    CMD_ARGS+=(${PLUTAINER_EXTRA_ARGS})
fi

if [[ "${BASE_GAME}" == "iw5" ]]; then
    CMD_ARGS+=(+start_map_rotate)
else
    CMD_ARGS+=(+map_rotate)
fi

# --- Step 8: Launch (with 30s crash throttle) ---
/home/plutainer/.plutainer/log-watcher.sh &

echo "Starting Plutonium ${PLUTAINER_GAME} Server: ${PLUTAINER_SERVER_NAME}"
echo "EXECUTING: wine bin/plutonium-bootstrapper-win32.exe ${CMD_ARGS[*]}"
launch_game wine bin/plutonium-bootstrapper-win32.exe "${CMD_ARGS[@]}"
