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

# --- Detect game type from PLUTAINER_GAME ---
if ! detect_game_type; then
  hold_indefinitely "Set PLUTAINER_GAME to one of: t4mp, t4sp, t5mp, t5sp, t6mp, t6zm, iw5mp, iw4x, t7x"
fi

# --- Validate (or initialise) volume layout ---
if ! check_volume_version; then
  hold_indefinitely "Volume layout check failed. See the migration instructions above."
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
