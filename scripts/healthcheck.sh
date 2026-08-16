#!/bin/bash
#
# Liveness check. Healthy means the server named a map it is running — not
# merely that a process exists or that a socket accepted a connection.
#
# Two protocols cover every family, chosen so the bar is the same for all of
# them:
#
#   Quake3   Call of Duty engines. Unauthenticated `getstatus`, falling back to
#            `getinfo`. Preferred over RCON `status` because both are handled by
#            the same connectionless path in the same server frame loop and both
#            read the map from the same cvar, so their failure detection is
#            identical — while RCON additionally depends on rcon_password, which
#            every bundled seed ships empty. A perfectly healthy first-run
#            server could never have reported healthy.
#
#   A2S      SteamCMD games. Valve's A2S_INFO, the query behind the Steam server
#            browser. Also unauthenticated, and it also reports a map, so
#            "healthy" keeps meaning "actually serving" rather than degrading to
#            "a TCP connect succeeded".
#
#   TCP      Last resort, for a game that speaks neither. It only proves
#            something is listening, so it is a genuinely weaker check and no
#            game currently selects it.
#
# Which one a game uses comes from its family table (STEAM_QUERY), not from a
# branch here.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/core.sh"

# --- Step 1: Detect Game Type ---
echo "[INFO] Detecting server type..."
detect_game_type || exit 1
echo "       - ${GAME_TYPE} server detected (${GAME_NAME})."

# --- Step 2: Check if health checks are explicitly disabled ---
if [[ "${HEALTHCHECK_FLAG}" == "false" ]]; then
  echo "[INFO] Health check is disabled by environment variable."
  exit 0
fi

# --- Step 3: Determine the correct port to check ---
resolve_active_port || exit 1
HEALTHCHECK_PORT="$ACTIVE_PORT"
echo "[INFO] Server port: ${HEALTHCHECK_PORT}"


# --- Step 4: Query the server ---
echo "[INFO] Querying server at 127.0.0.1:${HEALTHCHECK_PORT}..."

# The cod family is always Quake3; the steam family names its query in the
# table, because those games share no engine.
HEALTHCHECK_QUERY="quake3"
[[ "${GAME_TYPE}" == "steam" ]] && HEALTHCHECK_QUERY="${STEAM_QUERY}"

if [[ "${HEALTHCHECK_QUERY}" == "a2s" ]]; then
  QUERY_HOSTS="$(plutainer_query_hosts)"
  RESPONSE=$(python3 -c "
import sys
sys.path.insert(0, '${SCRIPT_DIR}')
from protocols import a2s

# Source servers answer only on the container's own address, not on loopback.
# See plutainer_query_hosts() in lib/core.sh.
problems = []
for host in '${QUERY_HOSTS}'.split():
    try:
        info = a2s.query_info(host, ${HEALTHCHECK_PORT}, timeout=2.0, retries=1)
    except Exception as e:
        problems.append('%s: %s' % (host, e))
        continue

    game_map = (info.get('map') or '').strip()
    if not game_map:
        problems.append('%s: answered A2S but named no map' % host)
        continue

    print('map: %s (%d/%d players, via A2S on %s)'
          % (game_map, info['players'], info['max_players'], host))
    sys.exit(0)

print('; '.join(problems), file=sys.stderr)
sys.exit(1)
") || {
    echo "[ERROR] Server did not report a loaded map on port ${HEALTHCHECK_PORT}." >&2
    exit 1
  }

elif [[ "${HEALTHCHECK_QUERY}" == "tcp" ]]; then
  QUERY_HOSTS="$(plutainer_query_hosts)"
  RESPONSE=$(python3 -c "
import socket
import sys

for host in '${QUERY_HOSTS}'.split():
    try:
        with socket.create_connection((host, ${HEALTHCHECK_PORT}), timeout=3):
            pass
    except Exception:
        continue
    # Deliberately not called 'map:' — this check cannot know one, and saying so
    # keeps it honest against the other two.
    print('accepting connections on %s' % host)
    sys.exit(0)

print('nothing accepted a connection', file=sys.stderr)
sys.exit(1)
") || {
    echo "[ERROR] Nothing is listening on port ${HEALTHCHECK_PORT}." >&2
    exit 1
  }

elif [[ "${HEALTHCHECK_QUERY}" == "quake3" ]]; then
  RESPONSE=$(python3 -c "
import sys
sys.path.insert(0, '${SCRIPT_DIR}')
from protocols import quake3

# Engines disagree on the key's case: iw4x/t4/t5/t6 answer 'mapname', t7x
# answers 'MapName'. Match case-insensitively rather than guessing per game.
MAP_KEYS = ('mapname', 'sv_mapname')

# getstatus first, getinfo second, and the order matters both ways:
#   * IW5 (MW3) does not answer getstatus at all — only getinfo.
#   * T7x answers both, but its infoResponse advertises the lobby's map while
#     statusResponse reports the map actually running, so preferring getinfo
#     would report the wrong map on a healthy server.
QUERIES = ('getstatus', 'getinfo')

server = quake3.Quake3Server('127.0.0.1:${HEALTHCHECK_PORT}')

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

else
  echo "[ERROR] Unknown health check query '${HEALTHCHECK_QUERY}' for ${GAME_NAME}." >&2
  echo "[ERROR] This is a bug in Plutainer's game table, not a configuration problem." >&2
  exit 1
fi

# --- Step 5: Report ---
echo "[OK] Health check passed: ${GAME_NAME} is responsive on port ${HEALTHCHECK_PORT} (${RESPONSE})."
exit 0
