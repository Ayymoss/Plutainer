#!/bin/bash
#
# Liveness check. Call of Duty servers use the Quake3 UDP status protocol;
# 7 Days to Die uses a process plus TCP-listener check.
#
# Uses the unauthenticated `getstatus` query rather than RCON `status`. Both are
# handled by the same connectionless-packet path inside the same server frame
# loop, and both report the map from the same `mapname`/`sv_mapname` cvar, so a
# soft-crash that stops the loop (or drops the map) fails this check exactly as
# it failed the RCON one — no reply at all, or a reply with no map. What RCON
# added was a credential dependency: a server with an empty `rcon_password`
# (which is what every bundled seed config ships) could never report healthy,
# no matter how well it was running.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/game-config.sh"

# --- Step 1: Detect Game Type ---
echo "[INFO] Detecting server type..."
detect_game_type || exit 1
echo "       - ${GAME_TYPE} server detected (${GAME_NAME})."

# --- Step 2: Check if health checks are explicitly disabled ---
if [[ "${HEALTHCHECK_FLAG}" == "false" ]]; then
  echo "[INFO] Health check is disabled by environment variable."
  exit 0
fi

# 7DTD is not a Quake-derived engine and does not answer getstatus/getinfo.
# Its game port has a TCP listener, so require both the dedicated process and
# a successful loopback connection. This catches a dead process and a server
# that is still starting or has failed before binding its game socket.
if [[ "$GAME_TYPE" == "7dtd" ]]; then
  HEALTHCHECK_PORT=${CUSTOM_PORT}
  if [[ -z "$HEALTHCHECK_PORT" ]]; then
    config_path="$PLUTAINER_CONFIGS_DIR/${PLUTAINER_CONFIG_FILE:-serverconfig.xml}"
    if [[ -f "$config_path" ]]; then
      HEALTHCHECK_PORT=$(python3 - "$config_path" <<'PY'
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    text = fh.read()
match = re.search(
    r'<property\s+name=["\']ServerPort["\']\s+value=["\'](\d+)["\']',
    text,
    re.IGNORECASE,
)
print(match.group(1) if match else "")
PY
      )
    fi
    if [[ -z "$HEALTHCHECK_PORT" ]]; then
      resolve_default_port || exit 1
      HEALTHCHECK_PORT="$DEFAULT_PORT"
    fi
  fi

  pgrep -f '[/]7DaysToDieServer.x86_64' >/dev/null || {
    echo "[ERROR] 7 Days to Die server process is not running." >&2
    exit 1
  }

  python3 - "$HEALTHCHECK_PORT" <<'PY'
import socket
import sys

port = int(sys.argv[1])
with socket.create_connection(("127.0.0.1", port), timeout=5):
    pass
print(f"[OK] 7 Days to Die is accepting TCP connections on port {port}.")
PY
  exit $?
fi

# --- Step 3: Determine the correct port to check ---
echo "[INFO] Determining server port..."
HEALTHCHECK_PORT=${CUSTOM_PORT}
if [[ -z "${HEALTHCHECK_PORT}" ]]; then
  echo "       - Custom port is not set, determining default for game '${BASE_GAME}'..."
  resolve_default_port || exit 1
  HEALTHCHECK_PORT="${DEFAULT_PORT}"
  echo "       - Default port set to ${HEALTHCHECK_PORT}."
else
  echo "       - Using custom port: ${HEALTHCHECK_PORT}."
fi

# --- Step 4: Query the server ---
echo "[INFO] Querying server at 127.0.0.1:${HEALTHCHECK_PORT}..."
RESPONSE=$(python3 -c "
import sys
import pyquake3

# Engines disagree on the key's case: iw4x/t4/t5/t6 answer 'mapname', t7x
# answers 'MapName'. Match case-insensitively rather than guessing per game.
MAP_KEYS = ('mapname', 'sv_mapname')

# getstatus first, getinfo second, and the order matters both ways:
#   * IW5 (MW3) does not answer getstatus at all — only getinfo.
#   * T7x answers both, but its infoResponse advertises the lobby's map while
#     statusResponse reports the map actually running, so preferring getinfo
#     would report the wrong map on a healthy server.
QUERIES = ('getstatus', 'getinfo')

server = pyquake3.PyQuake3('127.0.0.1:${HEALTHCHECK_PORT}')

problems = []
for query in QUERIES:
    try:
        values = server.query_values(query)
    except Exception as e:
        problems.append('%s: %s' % (query, e))
        continue

    for key, value in values.items():
        if key.strip().lower() in MAP_KEYS and (value or '').strip():
            print('map: %s (via %s)' % (value.strip(), query))
            sys.exit(0)

    problems.append('%s: replied without a map name' % query)

print('; '.join(problems), file=sys.stderr)
sys.exit(1)
") || {
  echo "[ERROR] Server did not report a loaded map on port ${HEALTHCHECK_PORT}." >&2
  exit 1
}

# --- Step 5: Validate the server's response ---
echo "[INFO] Validating server response..."
if echo "${RESPONSE}" | grep -q "map:"; then
  echo "[OK] Health check passed: Server is responsive on port ${HEALTHCHECK_PORT} (${RESPONSE})."
  exit 0
else
  echo "[ERROR] Server response did not contain 'map:'" >&2
  echo "[ERROR] Received: ${RESPONSE}" >&2
  exit 1
fi
