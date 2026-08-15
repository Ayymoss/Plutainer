#!/bin/bash
#
# Validate environment, prepare the game-files tree and configs/ symlinks,
# update iw4x via the iw4x-launcher, then launch the iw4x server.
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
echo "Linking files for iw4x..."
link_files "$SOURCE_DIR" "$DEST_DIR" main usermaps binkw32.dll localization.txt mss32.dll

# userraw/ is ENGINE_CONFIG_DIR, so it must be a real writable dir for
# link_configs to fan cfg symlinks into.
link_dir_contents "$SOURCE_DIR" "$DEST_DIR" userraw

# zone/ is split by how the launcher writes, not by who owns the content.
#
# Its rawfiles component unpacks release.zip by writing straight through each
# destination path, so a symlink there — at the directory OR the leaf — resolves
# into the read-only mount and aborts the whole run:
#   [E] failed to extract file: zone/patch/iw4_credits_load.ff
# That kills sync_dlc and sync_helper too and leaves rawfiles unstamped, so
# every later start fails identically and client updates never apply. The zip
# covers all of zone/patch/ and zone/zonebuilder/, so we must not pre-populate
# either. Nothing is lost: its 56 zone/patch entries are a strict superset of a
# full MW2 install's 39, and zone/zonebuilder is the same lone
# zonebuilder_minigun.ff it ships.
#
# Every other component downloads to a staging dir and renames into place,
# which *replaces* a symlink rather than writing through it. So mirroring
# zone/dlc is safe even though the launcher does write there (its cdn manifest
# says iw3/zone/dlc/... but it strips the prefix). It is also worth doing: the
# reconciler validates the host's existing fastfiles by hash and skips
# re-downloading the ones that already match.
link_dir_contents "$SOURCE_DIR" "$DEST_DIR" zone/english
link_dir_contents "$SOURCE_DIR" "$DEST_DIR" zone/dlc

# --- Step 2: Update iw4x ---
# The launcher has no --path flag: it canonicalises /proc/self/exe and uses its
# own directory as the installation root, ignoring our cwd. So run a copy from
# inside the volume — that way the ~800MB it fetches (iw4x.exe, iw4x.dll,
# iw4x/*.iwd, zone/patch/*.ff, iw3/zone/dlc/*.ff, steam.exe) lands in the bind
# mount and survives container recreation instead of filling the image layer.
# It must be a real copy: a symlink would canonicalise straight back to
# /home/plutainer/.plutainer and reinstate the ephemeral install root.
IW4X_LAUNCHER_SRC="/home/plutainer/.plutainer/iw4x-launcher"
IW4X_LAUNCHER="$DEST_DIR/iw4x-launcher"

# Capability check, deliberately not an architecture check, so this clears
# itself the moment an image ships a working binary again. The arm64 image
# builds the launcher from source because upstream publishes x86_64 binaries
# only, and that build is allowed to fail rather than taking the other six
# games down with it (see Dockerfile.arm64).
if [[ ! -x "$IW4X_LAUNCHER_SRC" ]]; then
  hold_indefinitely "iw4x-launcher is missing from this image, so PLUTAINER_GAME=iw4x cannot start.
  This image was built for an architecture upstream does not publish a launcher
  binary for, and building it from source failed. Tracked as iw4x/launcher#76.
  Options: run iw4x on an amd64 host, or use a different PLUTAINER_GAME —
  Plutonium (t4/t5/t6/iw5) and Alterware (t7x) are unaffected."
fi
if [[ ! -f "$IW4X_LAUNCHER" || "$IW4X_LAUNCHER_SRC" -nt "$IW4X_LAUNCHER" ]]; then
  echo "Staging iw4x-launcher into the game directory..."
  cp -f "$IW4X_LAUNCHER_SRC" "$IW4X_LAUNCHER"
  chmod +x "$IW4X_LAUNCHER"
fi

IW4X_CACHE_LOC="$DEST_DIR/cache/iw4x.db"
if [[ -f "$IW4X_CACHE_LOC" && "${PLUTAINER_AUTO_UPDATE:-}" == "false" ]]; then
  echo "Skipping iw4x update because PLUTAINER_AUTO_UPDATE is set to 'false'."
else
  if [[ -f "$IW4X_CACHE_LOC" ]]; then
    echo "Checking for iw4x updates..."
  else
    echo "First container run detected. Downloading iw4x initial files..."
  fi
  # Don't let a GitHub/CDN outage take a working server down: only a first-run
  # failure (no iw4x.exe yet) is fatal.
  if ! "$IW4X_LAUNCHER" --skip-launch --no-self-update; then
    if [[ -f "$DEST_DIR/iw4x.exe" ]]; then
      echo "[WARN] iw4x-launcher failed — starting with the existing install." >&2
    else
      hold_indefinitely "iw4x-launcher failed and no iw4x.exe is present. Check network access to github.com and cdn.iw4x.io, and that the app volume is not mounted 'noexec' (the launcher runs from $DEST_DIR)."
    fi
  fi
fi

cd "$DEST_DIR"

# --- Step 3a: Auto-lift any user-placed real cfg from engine path ---
auto_lift_user_config

# --- Step 3b: Seed default configs from bundled community repo ---
# The iw4x seed bundle has a single top-level dir, `userraw/`. cfg_root_rel
# lifts its top-level *.cfg (server, serverlan, partyserver, partyserverlan)
# into CONFIG_SOT_DIR; the playlist *.info files stay under
# runtime/gamefiles/userraw/ where the engine expects them.
if [[ "${PLUTAINER_SKIP_SEED:-}" != "true" ]]; then
  seed_configs iw4x "$DEST_DIR" "userraw"
fi

# --- Step 3c: Fan-out configs/ → engine + mod config dirs ---
link_configs "$ENGINE_CONFIG_DIR" "$MOD_CONFIG_DIR"

# --- Step 4: Validate environment + ensure config file exists ---
PLUTAINER_SERVER_NAME="${PLUTAINER_SERVER_NAME:-IW4x Docker Server}"

if [[ "${PLUTAINER_GAME}" != "iw4x" ]]; then
  hold_indefinitely "PLUTAINER_GAME must be 'iw4x' for the iw4x entrypoint."
fi
if [[ -z "${PLUTAINER_CONFIG_FILE:-}" ]]; then
  hold_indefinitely "PLUTAINER_CONFIG_FILE is not set. Specify the filename of your server config (e.g. 'server.cfg')."
fi
if ! ensure_config_present; then
  hold_indefinitely "Config file not found. See [ERROR] above."
fi

# Opt-in; a no-op unless PLUTAINER_RCON_PASSWORD is set to something non-empty.
apply_rcon_password

# --- Step 5: Resolve port ---
if [[ -z "${PLUTAINER_PORT:-}" ]]; then
  echo "PLUTAINER_PORT not set, using default for iw4x..."
  resolve_default_port "iw4x" || hold_indefinitely "Could not resolve default port."
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

# Opt-out: an unconditional +map_rotate overrides playlist-driven map selection.
if [[ "${PLUTAINER_MAP_ROTATE:-true}" != "false" ]]; then
    CMD_ARGS+=(+map_rotate)
fi

# --- Step 7: Launch (with 30s crash throttle) ---
/home/plutainer/.plutainer/log-watcher.sh &

echo "Starting iw4x Server: ${PLUTAINER_SERVER_NAME}"
echo "EXECUTING: wine iw4x.exe ${CMD_ARGS[*]}"
launch_game wine iw4x.exe "${CMD_ARGS[@]}"
