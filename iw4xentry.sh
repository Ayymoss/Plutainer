#!/bin/bash
#
# This entrypoint script is responsible for validating the container's
# environment, setting sensible defaults, and launching the specified
# IW4x game server.
#

# --- Step 1: Update IW4x Files ---
mkdir -p /home/plutainer/app
ln -sf /home/plutainer/gamefiles/{main,zone,binkw32.dll,localization.txt,mss32.dll} /home/plutainer/app/

IW4X_CACHE_LOC="/home/plutainer/app/launcher/cache.json"
if [[ ! -f "${IW4X_CACHE_LOC}" ]]; then
  echo "First container run detected. Downloading iw4x (IW4x) initial files... This may take a few minutes."
  /home/plutainer/.plutainer/iw4x-launcher --path /home/plutainer/app --update
else
  if [[ "${IW4X_AUTO_UPDATE}" == "false" ]]; then
    echo "Skipping iw4x update because IW4X_AUTO_UPDATE is set to 'false'."
  else
    echo "Checking for iw4x updates... This may take a few minutes if an update is available."
    /home/plutainer/.plutainer/iw4x-launcher --path /home/plutainer/app --update
  fi
fi

cd /home/plutainer/app

# --- Step 2: Validate Required Environment Variables ---
MISSING_VAR=false
INVALID_VAR=false
VALID_GAMES="iw4x"
IW4X_SERVER_NAME=${IW4X_SERVER_NAME:-"IW4x Docker Server"}

if [[ -z "${IW4X_GAME}" ]]; then
  echo "ERROR: The 'IW4X_GAME' environment variable is not set." >&2
  MISSING_VAR=true
elif [[ ! " ${VALID_GAMES} " =~ " ${IW4X_GAME} " ]]; then
  echo "ERROR: Invalid value for 'IW4X_GAME': \"${IW4X_GAME}\"." >&2
  INVALID_VAR=true
fi

if [[ -z "${IW4X_CONFIG_FILE}" ]]; then
  echo "ERROR: The 'IW4X_CONFIG_FILE' environment variable is not set." >&2
  echo "  > You must specify the name of the server configuration file (e.g., 'server.cfg')." >&2
  MISSING_VAR=true
fi

if [[ "$MISSING_VAR" == "true" || "$INVALID_VAR" == "true" ]]; then
  echo "-------------------------------------------------" >&2
  if [[ "$INVALID_VAR" == "true" ]]; then
      echo "An invalid value was provided. Valid game modes are: ${VALID_GAMES}" >&2
  fi
  echo "One or more configuration errors found. Halting startup." >&2
  echo "Exiting in 10 seconds..." >&2
  sleep 10
  exit 1
fi

# --- Step 3: Set Default Port (If Needed) ---
if [[ -z "${IW4X_PORT}" ]]; then
  echo "Optional IW4X_PORT is not set, defaulting to 28960 for ${IW4X_GAME}..."
  IW4X_PORT="28960"
  echo "Default port set to ${IW4X_PORT}"
fi

# --- Step 4: Build Server Command Arguments ---
declare -a CMD_ARGS=(
    -dedicated
    -stdout
    +set sv_lanonly "0"
    +set net_port "${IW4X_PORT}"
    +exec "${IW4X_CONFIG_FILE}"
    +set logfile "1"
    +set party_enable "0"
)

if [[ -n "${IW4X_MOD}" ]]; then
    CMD_ARGS+=(+set fs_game "${IW4X_MOD}")
fi

if [[ -n "${IW4X_NET_LOG_IP}" ]]; then
    CMD_ARGS+=(+set g_log_add "${IW4X_NET_LOG_IP}")
fi

CMD_ARGS+=(+map_rotate)

# --- Step 5: Launch the iw4x Server ---
echo "Starting ${IW4X_GAME} Server: ${IW4X_SERVER_NAME}"
echo "EXECUTING: wine iw4x.exe ${CMD_ARGS[@]}"
exec wine iw4x.exe "${CMD_ARGS[@]}"
