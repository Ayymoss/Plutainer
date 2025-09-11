#!/bin/bash
#
# This script checks the server's health by determining the correct game,
# port, and config, and then sending an RCON "status" command.
#
# It is intentionally verbose to aid in manual debugging and to provide
# context in Docker's healthcheck logs.
#

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Step 1: Determine Game Type and Set Environment ---
echo "[INFO] Detecting server type..."
if [[ -n "${PLUTO_GAME}" ]]; then
  echo "       - Plutonium server detected."
  GAME_TYPE="plutonium"
  GAME_NAME="${PLUTO_GAME}"
  BASE_GAME="${PLUTO_GAME%??}"
  CONFIG_FILE="${PLUTO_CONFIG_FILE}"
  CUSTOM_PORT="${PLUTO_PORT}"
  HEALTHCHECK_DISABLED="${PLUTO_HEALTHCHECK}"

elif [[ -n "${IW4X_GAME}" ]]; then
  echo "       - IW4x server detected."
  GAME_TYPE="iw4x"
  GAME_NAME="${IW4X_GAME}"
  BASE_GAME="iw4x" # Specific base game for IW4x
  CONFIG_FILE="${IW4X_CONFIG_FILE}"
  CUSTOM_PORT="${IW4X_PORT}"
  HEALTHCHECK_DISABLED="${IW4X_HEALTHCHECK}"

else
  echo "[FAIL] Health check failed: Could not determine server type. Set PLUTO_GAME or IW4X_GAME." >&2
  exit 1
fi


# --- Step 2: Check if health checks are explicitly disabled ---
if [[ "${HEALTHCHECK_DISABLED}" == "false" ]]; then
  echo "[INFO] Health check is disabled by environment variable."
  exit 0
fi


# --- Step 3: Validate that required variables are set ---
echo "[INFO] Validating required environment variables..."
if [[ -z "${GAME_NAME}" || -z "${CONFIG_FILE}" ]]; then
  echo "[FAIL] Health check failed: Required env vars are missing for the detected game type." >&2
  exit 1
fi
echo "       - Game='${GAME_NAME}'"
echo "       - Config File='${CONFIG_FILE}'"


# --- Step 4: Determine the correct port to check ---
echo "[INFO] Determining server port..."
HEALTHCHECK_PORT=${CUSTOM_PORT}

if [[ -z "${HEALTHCHECK_PORT}" ]]; then
  echo "       - Custom port is not set, determining default for game '${BASE_GAME}'..."
  case "${BASE_GAME}" in
    "iw4x")     HEALTHCHECK_PORT="28960" ;;
    "iw5")      HEALTHCHECK_PORT="27016" ;;
    "t4" | "t5") HEALTHCHECK_PORT="28960" ;;
    "t6")       HEALTHCHECK_PORT="4976"  ;;
    *)
      echo "[FAIL] Health check failed: Could not determine default port for game '${GAME_NAME}'." >&2
      exit 1
      ;;
  esac
  echo "       - Default port set to ${HEALTHCHECK_PORT}."
else
  echo "       - Using custom port: ${HEALTHCHECK_PORT}."
fi


# --- Step 5: Determine the game-specific config file path ---
echo "[INFO] Determining configuration file path..."
case "${GAME_TYPE}" in
  "plutonium")
    case "${BASE_GAME}" in
      "t4") CONFIG_PATH="/home/plutainer/app/gamefiles/main/${CONFIG_FILE}" ;;
      "iw5") CONFIG_PATH="/home/plutainer/app/gamefiles/admin/${CONFIG_FILE}" ;;
      *) CONFIG_PATH="/home/plutainer/app/plutonium/storage/${BASE_GAME}/${CONFIG_FILE}" ;;
    esac
    ;;
  "iw4x")
    CONFIG_PATH="/home/plutainer/app/userraw/${CONFIG_FILE}"
    ;;
esac
echo "       - Expecting config file at: ${CONFIG_PATH}"

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "[FAIL] Health check failed: Config file not found at ${CONFIG_PATH}" >&2
  exit 1
fi


# --- Step 6: Extract RCON password from config ---
echo "[INFO] Extracting RCON password from config..."
RCON_PASSWORD=$(grep -v '^[[:space:]]*//' "${CONFIG_PATH}" | grep -i 'rcon_password' | sed -n 's/.*"\([^"]*\)".*/\1/p' | tail -1)

if [[ -z "${RCON_PASSWORD}" ]]; then
  echo "[FAIL] Health check failed: Could not find 'rcon_password' in ${CONFIG_PATH}" >&2
  exit 1
fi
echo "       - RCON password extracted successfully."


# --- Step 7: Query the server ---
echo "[INFO] Querying server at 127.0.0.1:${HEALTHCHECK_PORT}..."
RESPONSE=$(python3 -c "
import sys
import pyquake3

try:
    port = '${HEALTHCHECK_PORT}'
    password = '${RCON_PASSWORD}'
    server = pyquake3.PyQuake3(f'127.0.0.1:{port}', rcon_password=password)
    print(server.rcon('status'))
except Exception as e:
    print(f'RCON connection failed: {e}', file=sys.stderr)
    sys.exit(1)
")


# --- Step 8: Validate the server's response ---
echo "[INFO] Validating server response..."
if echo "${RESPONSE}" | grep -q "map:"; then
  echo "[OK] Health check passed: Server is responsive on port ${HEALTHCHECK_PORT}."
  exit 0
else
  echo "[FAIL] Health check failed: Server response did not contain 'map:'" >&2
  echo "[FAIL] Received: ${RESPONSE}" >&2
  exit 1
fi
