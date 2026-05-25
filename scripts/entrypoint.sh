#!/bin/bash
#
# Top-level entrypoint. Detects the game family, validates the volume
# version, then delegates to the appropriate game-specific entry script.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/game-config.sh"

# --- Branding ---
cat << "EOF"

 ____  _       _        _
|  _ \| |_   _| |_ __ _(_)_ __   ___ _ __
| |_) | | | | | __/ _` | | '_ \ / _ \ '__|
|  __/| | |_| | || (_| | | | | |  __/ |
|_|   |_|\__,_|\__\__,_|_|_| |_|\___|_|

EOF

echo
echo "Brought to you by Ayymoss"
echo

# --- v1 deployment detection (combined env + volume) ---
# Order matters: run BOTH detectors before deciding to hold, so the user sees
# every reason for refusal in a single block instead of fixing one thing,
# restarting, and hitting the next refusal.
HAS_LEGACY_ENV=false
HAS_V1_VOLUME=false

detect_legacy_env_vars || HAS_LEGACY_ENV=true

# check_volume_version handles fresh-init and v2 marker validation as side
# effects. It sets V1_VOLUME_DETECTED=true when v1 dirs are present without
# a marker (without printing); any other return-1 path means a real volume
# state error (e.g. unknown future-version marker), which already printed.
VOLUME_CHECK_RC=0
check_volume_version || VOLUME_CHECK_RC=$?
if [[ "${V1_VOLUME_DETECTED:-false}" == "true" ]]; then
  HAS_V1_VOLUME=true
elif [[ $VOLUME_CHECK_RC -ne 0 ]]; then
  # Non-v1 volume error (already printed its own message).
  hold_indefinitely "Volume layout check failed. See above."
fi

if [[ "$HAS_LEGACY_ENV" == "true" || "$HAS_V1_VOLUME" == "true" ]]; then
  print_v1_migration_block "$HAS_LEGACY_ENV" "$HAS_V1_VOLUME"
  hold_indefinitely "v1 deployment detected. Pick one of the paths above, then restart."
fi

# --- Detect game type from PLUTAINER_GAME ---
if ! detect_game_type; then
  hold_indefinitely "Set PLUTAINER_GAME to one of: t4mp, t4sp, t5mp, t5sp, t6mp, t6zm, iw5mp, iw4x, t7x"
fi

# --- Dispatch to game-specific entrypoint ---
case "$GAME_TYPE" in
  plutonium)
    echo "Plutonium game detected (${GAME_NAME}). Handing off to Plutonium entrypoint..."
    exec "$SCRIPT_DIR/plutoentry.sh"
    ;;
  iw4x)
    echo "IW4x game detected. Handing off to IW4x entrypoint..."
    exec "$SCRIPT_DIR/iw4xentry.sh"
    ;;
  alterware)
    echo "Alterware game detected (${GAME_NAME}). Handing off to Alterware entrypoint..."
    exec "$SCRIPT_DIR/alterentry.sh"
    ;;
esac
