#!/bin/bash
#
# Entry script for the `steam` family — every game SteamCMD installs. Nothing in
# here is specific to one of them: the per-game facts live in the table in
# lib/steam.sh, and the per-engine steps are hooks it defines.
#
# Deliberately the same shape as games/codentry.sh, so the project reads the
# same way throughout: resolve the game, put the server on disk, seed a config
# on first run, apply the generic PLUTAINER_* settings, validate, launch.
#
# What differs from the cod family, and why:
#   - No gamefiles mount. SteamCMD installs the dedicated server itself, into
#     the app volume, so it survives container recreation.
#   - No Wine. Everything here is a native Linux binary.
#   - Whether configs are symlinked into the install is per game, not per
#     family: 7DTD is pointed at app/configs/ with a flag and needs no links,
#     while Source games exec their cfg from inside the SteamCMD-owned install
#     and do. That is what the `stage` hook is for.
#
set -euo pipefail

PLUTAINER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUTAINER_ROOT/lib/core.sh"

detect_game_type     || hold_indefinitely "Could not detect the configured game."
check_volume_version || hold_indefinitely "check_volume_version failed."

# Capability check, not an architecture check — the same pattern the iw4x and
# cod4x hooks use. If a future image ships SteamCMD for another architecture,
# this starts working with no code change.
[[ -x "$STEAM_CMD" ]] || hold_indefinitely \
  "SteamCMD is not present in this image, so ${GAME_NAME} cannot run here. SteamCMD ships x86_64 binaries only, so this game needs the linux/amd64 image."

# Hook lookup order, most specific first.
declare -a STEAM_HOOKS=("$GAME_NAME" "$STEAM_ENGINE")

plutainer_require_hooks steam "$(IFS=,; echo "${STEAM_HOOKS[*]}")" seed launch_args \
  || hold_indefinitely "Plutainer is missing an implementation for ${GAME_NAME}."

steam_resolve_config_path || hold_indefinitely "Unknown SteamCMD game '${GAME_NAME}'."
resolve_active_port       || hold_indefinitely "Could not resolve the server port."

echo "[INFO] ${GAME_NAME}: Steam app ${STEAM_APP_ID} (${STEAM_ENGINE})"
echo "[INFO]   install : $STEAM_INSTALL_DIR"
echo "[INFO]   data    : $STEAM_DATA_DIR"
echo "[INFO]   config  : $CONFIG_PATH"
if (( STEAM_UDP_SPAN > 1 )); then
  echo "[INFO]   port    : $ACTIVE_PORT (publish UDP $ACTIVE_PORT-$(( ACTIVE_PORT + STEAM_UDP_SPAN - 1 )))"
else
  echo "[INFO]   port    : $ACTIVE_PORT"
fi

mkdir -p "$PLUTAINER_CONFIGS_DIR" "$PLUTAINER_APP_DIR/logs" "$STEAM_DATA_DIR"

# --- Install / update -------------------------------------------------------
steam_install_or_update

# --- Config -----------------------------------------------------------------
plutainer_hook steam seed "${STEAM_HOOKS[@]}"
steam_ensure_config_present || hold_indefinitely "${GAME_NAME} configuration is missing."
plutainer_hook steam configure "${STEAM_HOOKS[@]}" || true
plutainer_hook steam stage     "${STEAM_HOOKS[@]}" || true

# --- Logs -------------------------------------------------------------------
#
# Rotation is off for this family, on purpose. log-watcher.sh rotates by
# copy-truncate, which is only safe because the CoD engines open their logs with
# O_APPEND — after truncation their next write lands at offset 0. A Unity
# dedicated server's -logfile writer holds its own offset instead, so truncating
# leaves a sparse hole and the file's apparent size snaps straight back over the
# limit, re-triggering rotation on every poll.
#
# Not yet measured against a running 7DTD; until it is, not rotating is the safe
# failure (an unbounded log, which is what the game does unmanaged) rather than
# a rotation loop copying gigabytes every two seconds. The fix, when there is a
# host to test it on, is to own the stream instead: -logfile - writes to stdout,
# and teeing that through an append-mode fd makes copy-truncate valid again,
# with the bonus that the server finally shows up in `docker logs`.
export PLUTAINER_LOG_ROTATE="${PLUTAINER_LOG_ROTATE:-false}"

# SteamCMD installs tens of thousands of files; keep the log poller out of them.
export PLUTAINER_LOG_PRUNE_DIRS="${PLUTAINER_LOG_PRUNE_DIRS:-$PLUTAINER_STEAM_DIR}"

if [[ "${PLUTAINER_LOG_SYMLINKS:-true}" != "false" ]]; then
  "$PLUTAINER_ROOT/log-watcher.sh" &
fi

# --- Launch -----------------------------------------------------------------
declare -a STEAM_LAUNCH_ARGS=()
plutainer_hook steam launch_args "${STEAM_HOOKS[@]}"

(( ${#STEAM_LAUNCH_ARGS[@]} )) || hold_indefinitely \
  "No launch arguments were built for ${GAME_NAME}. This is a bug in Plutainer."

if [[ -n "${PLUTAINER_EXTRA_ARGS:-}" ]]; then
  # Intentionally word-split, matching every other entry script: users pass
  # multiple flags in one variable.
  # shellcheck disable=SC2206
  STEAM_LAUNCH_ARGS+=( ${PLUTAINER_EXTRA_ARGS} )
fi

echo "[INFO] Starting ${PLUTAINER_SERVER_NAME:-$GAME_NAME}..."
echo "[INFO] Command: $STEAM_SERVER_PATH ${STEAM_LAUNCH_ARGS[*]}"

# Some servers must be started from a particular directory (CS2's cs2.sh
# resolves the Steam Runtime relative to cwd). Defaults to the install root.
cd "$STEAM_INSTALL_DIR/${STEAM_WORKDIR:-}"

# Unity servers load their own bundled .so files from the install root.
export LD_LIBRARY_PATH="$STEAM_INSTALL_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# launch_game_graceful, not launch_game: these games have world state to flush.
# It only ever sees a signal if the compose file asks for one — see the note on
# stop_signal in lib/core.sh.
launch_game_graceful "$STEAM_SERVER_PATH" "${STEAM_LAUNCH_ARGS[@]}"
