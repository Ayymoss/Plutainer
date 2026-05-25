#!/bin/bash
#
# This entrypoint script is responsible for branding and delegating the
# server startup to the appropriate game-specific script.
#

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

cat >&2 << 'EOF'
========================================================================
[DEPRECATED] You are running ghcr.io/ayymoss/plutainer:v1-final.

This tag is FROZEN. No further updates, fixes, or security patches
will be published for v1. The :latest tag now points at v2, which has
a new volume layout and unified PLUTAINER_* environment variables.

You have two paths:

  Stay on v1
    Pin image: ghcr.io/ayymoss/plutainer:v1-final
    This banner will continue to appear every start until you migrate.

  Migrate to v2 (recommended)
    See: https://github.com/Ayymoss/Plutainer/blob/main/MIGRATION.md

Container will continue starting in 10 seconds...
========================================================================
EOF
sleep 10

if [[ -n "${PLUTO_GAME}" ]]; then
  echo "Plutonium game type detected. Handing off to Plutonium entrypoint..."
  exec /home/plutainer/.plutainer/plutoentry.sh
elif [[ -n "${IW4X_GAME}" ]]; then
  echo "IW4x game type detected. Handing off to IW4x entrypoint..."
  exec /home/plutainer/.plutainer/iw4xentry.sh
elif [[ -n "${ALTER_GAME}" ]]; then
  echo "Alterware game type detected (${ALTER_GAME}). Handing off to Alterware entrypoint..."
  exec /home/plutainer/.plutainer/alterentry.sh
else
  echo "-------------------------------------------------" >&2
  echo "[ERROR] No game type specified." >&2
  echo "  > Please set PLUTO_GAME, IW4X_GAME, or ALTER_GAME environment variable." >&2
  echo "Exiting in 10 seconds..." >&2
  sleep 10
  exit 1
fi
