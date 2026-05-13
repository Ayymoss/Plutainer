#!/bin/bash
#
# Validate environment, prepare the game-files tree and configs/ symlinks,
# fetch t7x.exe, then launch the Alterware (T7x) server.
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
echo "Linking files for t7x (Black Ops III)..."
link_files "$SOURCE_DIR" "$DEST_DIR" \
  codlogo.bmp machinecfg steam_api64.dll steamclient64.dll tier0_s64.dll vstdlib_s64.dll

# T7x detects dedicated server mode by checking which executables exist:
#   is_server = has_flag("dedicated") || (!has_client && has_server)
# Under Wine, flag detection via GetCommandLineW() can be unreliable, so we
# only symlink the server binary to guarantee the fallback path fires.
if [[ -f "$SOURCE_DIR/BlackOps3_UnrankedDedicatedServer.exe" ]]; then
  ln -sf "$SOURCE_DIR/BlackOps3_UnrankedDedicatedServer.exe" "$DEST_DIR"/
elif [[ -f "$SOURCE_DIR/BlackOps3.exe" ]]; then
  echo "[WARN] BlackOps3_UnrankedDedicatedServer.exe not found, falling back to BlackOps3.exe" >&2
  ln -sf "$SOURCE_DIR/BlackOps3.exe" "$DEST_DIR"/
fi

# Create zone/ as a real directory with symlinked contents so configs can be
# placed alongside the read-only game data (same approach as T4's main/).
mkdir -p "$DEST_DIR/zone"
# Guard the glob: bash leaves unmatched `*` literal, so an empty/missing
# source zone/ would create a bogus symlink named `*`.
if compgen -G "$SOURCE_DIR/zone/*" > /dev/null; then
  ln -sf "$SOURCE_DIR"/zone/* "$DEST_DIR"/zone/
fi

# --- Step 2: Download/Update T7x ---
# wget -N: timestamping. Only downloads when upstream is newer than local.
ALTER_EXE_LOC="$DEST_DIR/t7x.exe"
if [[ -f "$ALTER_EXE_LOC" && "${PLUTAINER_AUTO_UPDATE:-}" == "false" ]]; then
  echo "Skipping T7x update because PLUTAINER_AUTO_UPDATE is set to 'false'."
else
  if [[ -f "$ALTER_EXE_LOC" ]]; then
    echo "Checking for T7x updates..."
  else
    echo "First container run detected. Downloading T7x... This may take a moment."
  fi
  wget -q -N -P "$DEST_DIR" https://master.bo3.eu/t7x/t7x.exe
fi

cd "$DEST_DIR"

# --- Step 3a: Auto-lift any user-placed real cfg from engine path ---
auto_lift_user_config

# --- Step 3b: Seed default configs from bundled community repo ---
# t7x seed bundle has two top-level dirs: `zone/` (configs) and `t7x/` (lobby
# scripts). cfg_root_rel="zone" lifts top-level `zone/*.cfg` files into
# CONFIG_SOT_DIR; everything else stays under runtime/gamefiles/.
if [[ "${PLUTAINER_SKIP_SEED:-}" != "true" ]]; then
  seed_configs t7x "$DEST_DIR" "zone"
fi

# --- Step 4: Fan-out configs/ → engine config dir ---
# (Alterware MOD is a Steam Workshop ID, not a filesystem path — no MOD dir.)
link_configs "$ENGINE_CONFIG_DIR"

# --- Step 5: Validate environment + ensure config file exists ---
PLUTAINER_SERVER_NAME="${PLUTAINER_SERVER_NAME:-T7x Docker Server}"

if [[ "${PLUTAINER_GAME}" != "t7x" ]]; then
  hold_indefinitely "PLUTAINER_GAME must be 't7x' for the Alterware entrypoint."
fi
if [[ -z "${PLUTAINER_CONFIG_FILE:-}" ]]; then
  hold_indefinitely "PLUTAINER_CONFIG_FILE is not set. Specify the filename of your server config (e.g. 'server_zm.cfg')."
fi
if ! ensure_config_present; then
  hold_indefinitely "Config file not found. See [ERROR] above."
fi

# --- Step 6: Resolve port ---
if [[ -z "${PLUTAINER_PORT:-}" ]]; then
  echo "PLUTAINER_PORT not set, using default for t7x..."
  resolve_default_port "t7x" || hold_indefinitely "Could not resolve default port."
  PLUTAINER_PORT="${DEFAULT_PORT}"
  echo "Default port set to ${PLUTAINER_PORT}"
fi

# --- Step 7: Build Server Command Arguments ---
declare -a CMD_ARGS=(
    -dedicated
    +set fs_game "${PLUTAINER_MOD:-}"
    +set net_port "${PLUTAINER_PORT}"
    +set logfile "2"
    +exec "${PLUTAINER_CONFIG_FILE}"
)

if [[ -n "${PLUTAINER_EXTRA_ARGS:-}" ]]; then
    CMD_ARGS+=(${PLUTAINER_EXTRA_ARGS})
fi

# --- Step 8: Launch (with 30s crash throttle) ---
# T7x requires a display even in dedicated/headless mode, so start a virtual
# framebuffer for Wine before launching.
echo "Starting virtual display..."
rm -f /tmp/.X99-lock
Xvfb :99 -screen 0 320x240x24 &
sleep 1

/home/plutainer/.plutainer/log-watcher.sh &

echo "Starting T7x Server: ${PLUTAINER_SERVER_NAME}"
echo "EXECUTING: wine t7x.exe ${CMD_ARGS[*]}"
launch_game wine t7x.exe "${CMD_ARGS[@]}"
