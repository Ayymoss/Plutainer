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

if [[ -n "${PLUTO_GAME}" ]]; then
  echo "Plutonium game type detected. Handing off to Plutonium entrypoint..."
  exec /home/plutainer/.plutainer/plutoentry.sh
elif [[ -n "${IW4X_GAME}" ]]; then
  echo "IW4x game type detected. Handing off to IW4x entrypoint..."
  exec /home/plutainer/.plutainer/iw4xentry.sh
else
  echo "-------------------------------------------------" >&2
  echo "FATAL: No game type specified." >&2
  echo "  > Please set either the 'PLUTO_GAME' or 'IW4X_GAME' environment variable." >&2
  echo "Exiting in 10 seconds..." >&2
  sleep 10
  exit 1
fi
