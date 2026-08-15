#!/bin/bash
#
# Validate environment, prepare the game-files tree and configs/ symlinks,
# then launch the CoD4x (Call of Duty 4: Modern Warfare) dedicated server.
#
# Unlike every other family here, this one does NOT run under Wine. CoD4x
# publishes a native Linux dedicated server (`cod4x18_dedrun`, 32-bit x86), and
# it is a plain console application — no window, so no display needed either.
# The 32-bit runtime comes from lib32-glibc/lib32-gcc-libs in the image.
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

# The server binary and CoD4x's own assets are staged in the image here.
COD4X_ASSET_DIR="/home/plutainer/.plutainer/cod4x"
COD4X_BINARY="cod4x18_dedrun"

if [[ ! -x "$COD4X_ASSET_DIR/$COD4X_BINARY" ]]; then
  hold_indefinitely "CoD4x is not available in this image (no ${COD4X_BINARY}).
  Upstream publishes a 32-bit x86 Linux binary only, so CoD4x cannot run on this
  architecture. Plutonium, IW4x and Alterware titles are unaffected."
fi

# --- Step 1: Link Game Files ---
# main/ and zone/english/ must stay writable real directories: server.cfg
# symlinks and games_mp.log land in main/, and CoD4x's patch fastfiles are
# placed alongside the stock ones in zone/english/.
echo "Linking files for cod4x (Call of Duty 4: Modern Warfare)..."
link_dir_contents "$SOURCE_DIR" "$DEST_DIR" main
link_dir_contents "$SOURCE_DIR" "$DEST_DIR" zone/english

# --- Step 2: Stage the CoD4x server binary and assets ---
# The binary is copied, not symlinked: CoD4x ships a self-updater that rewrites
# it in place, which would fail against a read-only image layer. Living in the
# volume also means an updated build survives container recreation.
if [[ ! -f "$DEST_DIR/$COD4X_BINARY" ]]; then
  echo "First container run detected. Staging CoD4x server binary..."
  cp "$COD4X_ASSET_DIR/$COD4X_BINARY" "$DEST_DIR/$COD4X_BINARY"
  chmod +x "$DEST_DIR/$COD4X_BINARY"
elif [[ "${PLUTAINER_AUTO_UPDATE:-}" != "false" ]]; then
  # Only refresh when the image ships something newer; never clobber a build the
  # self-updater fetched.
  if [[ "$COD4X_ASSET_DIR/$COD4X_BINARY" -nt "$DEST_DIR/$COD4X_BINARY" ]]; then
    echo "Image ships a newer CoD4x binary — updating."
    cp "$COD4X_ASSET_DIR/$COD4X_BINARY" "$DEST_DIR/$COD4X_BINARY"
    chmod +x "$DEST_DIR/$COD4X_BINARY"
  fi
fi

# CoD4x's own fastfiles and iwd, which a stock CoD4 install does not have. The
# server refuses to load a map without cod4x_patchv2. cp -n: a user-supplied or
# self-updated copy always wins.
cp -n "$COD4X_ASSET_DIR"/zone/english/*.ff "$DEST_DIR/zone/english/" 2>/dev/null || true
cp -n "$COD4X_ASSET_DIR"/main/*.iwd        "$DEST_DIR/main/"         2>/dev/null || true

cd "$DEST_DIR"

# --- Step 3a: Auto-lift any user-placed real cfg from engine path ---
auto_lift_user_config

# --- Step 3b: Seed default configs from the bundled community repo ---
# cfg_root_rel="main" so the seed's top-level main/*.cfg lift into
# CONFIG_SOT_DIR; anything else stays under runtime/gamefiles/.
if [[ "${PLUTAINER_SKIP_SEED:-}" != "true" ]]; then
  seed_configs cod4x "$DEST_DIR" "main"
fi

# --- Step 4: Fan-out configs/ → engine + mod config dirs ---
link_configs "$ENGINE_CONFIG_DIR" "$MOD_CONFIG_DIR"

# --- Step 5: Validate environment + ensure config file exists ---
PLUTAINER_SERVER_NAME="${PLUTAINER_SERVER_NAME:-CoD4x Docker Server}"

if [[ "${PLUTAINER_GAME}" != "cod4x" ]]; then
  hold_indefinitely "PLUTAINER_GAME must be 'cod4x' for the CoD4x entrypoint."
fi
if [[ -z "${PLUTAINER_CONFIG_FILE:-}" ]]; then
  hold_indefinitely "PLUTAINER_CONFIG_FILE is not set. Specify the filename of your server config (e.g. 'server.cfg')."
fi
if ! ensure_config_present; then
  hold_indefinitely "Config file not found. See [ERROR] above."
fi

apply_rcon_password

# --- Step 6: Resolve port ---
if [[ -z "${PLUTAINER_PORT:-}" ]]; then
  echo "PLUTAINER_PORT not set, using default for cod4x..."
  resolve_default_port "cod4x" || hold_indefinitely "Could not resolve default port."
  PLUTAINER_PORT="${DEFAULT_PORT}"
  echo "Default port set to ${PLUTAINER_PORT}"
fi

# --- Step 7: Build Server Command Arguments ---
# `dedicated 2` is a public (master-listed) dedicated server; `1` is LAN.
declare -a CMD_ARGS=(
    +set dedicated "${PLUTAINER_DEDICATED:-2}"
    +set net_port "${PLUTAINER_PORT}"
    +set fs_homepath "${DEST_DIR}"
)

# CoD4x authorises servers against its master. Without a token from
# cod4x.ovh, -1 disables the check so the server still boots; set a real
# token via PLUTAINER_COD4X_AUTH_TOKEN to be listed properly.
if [[ -n "${PLUTAINER_COD4X_AUTH_TOKEN:-}" ]]; then
    CMD_ARGS+=(+set sv_authtoken "${PLUTAINER_COD4X_AUTH_TOKEN}")
else
    CMD_ARGS+=(+set sv_authorizemode "${PLUTAINER_COD4X_AUTHORIZE_MODE:--1}")
fi

if [[ -n "${PLUTAINER_MOD:-}" ]]; then
    CMD_ARGS+=(+set fs_game "${PLUTAINER_MOD}")
fi

CMD_ARGS+=(+exec "${PLUTAINER_CONFIG_FILE}")

if [[ -n "${PLUTAINER_EXTRA_ARGS:-}" ]]; then
    CMD_ARGS+=(${PLUTAINER_EXTRA_ARGS})
fi

if [[ "${PLUTAINER_MAP_ROTATE:-}" != "false" ]]; then
    CMD_ARGS+=(+map_rotate)
fi

# --- Step 8: Launch (with 30s crash throttle) ---
/home/plutainer/.plutainer/log-watcher.sh &

echo "Starting CoD4x Server: ${PLUTAINER_SERVER_NAME}"
echo "EXECUTING: ./${COD4X_BINARY} ${CMD_ARGS[*]}"
launch_game "./${COD4X_BINARY}" "${CMD_ARGS[@]}"
