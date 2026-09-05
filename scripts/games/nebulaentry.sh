#!/bin/bash
# Dyson Sphere Program + Nebula multiplayer family entrypoint.
set -euo pipefail

PLUTAINER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUTAINER_ROOT/lib/core.sh"

detect_game_type     || hold_indefinitely "Could not detect the configured game."
check_volume_version || hold_indefinitely "check_volume_version failed."
nebula_resolve_game  || hold_indefinitely "Unknown Nebula game '${GAME_NAME}'."
resolve_active_port  || hold_indefinitely "Could not resolve the server port."
nebula_validate_source || hold_indefinitely "Dyson Sphere Program game files are missing."

echo "[INFO] ${GAME_NAME}: Dyson Sphere Program with Nebula"
echo "[INFO]   source  : $PLUTAINER_SOURCE_DIR (read-only)"
echo "[INFO]   runtime : $NEBULA_GAME_DIR"
echo "[INFO]   saves   : $NEBULA_SAVE_DIR"
echo "[INFO]   configs : $PLUTAINER_CONFIGS_DIR"
echo "[INFO]   port    : $ACTIVE_PORT/tcp"

mkdir -p "$NEBULA_DATA_DIR" "$PLUTAINER_APP_DIR/logs"
nebula_stage_game || hold_indefinitely "Could not stage the Dyson Sphere Program files."
nebula_apply_steam_api || hold_indefinitely "Could not prepare DSP for headless Steam-free startup."
nebula_install_mods
nebula_prepare_storage || hold_indefinitely "Could not prepare Nebula's persistent config/save storage."
nebula_configure

CONFIG_FILE="${CONFIG_FILE:-$NEBULA_CONFIG_FILE}"
CONFIG_PATH="$PLUTAINER_CONFIGS_DIR/$CONFIG_FILE"
[[ -f "$CONFIG_PATH" ]] || hold_indefinitely \
  "PLUTAINER_CONFIG_FILE='${CONFIG_FILE}', but $CONFIG_PATH does not exist."

# Unity's file logger is not known to reopen in append mode after truncation.
export PLUTAINER_LOG_ROTATE="${PLUTAINER_LOG_ROTATE:-false}"
export PLUTAINER_LOG_PRUNE_DIRS="${PLUTAINER_LOG_PRUNE_DIRS:-$NEBULA_GAME_DIR}"
if [[ "${PLUTAINER_LOG_SYMLINKS:-true}" != "false" ]]; then
  "$PLUTAINER_ROOT/log-watcher.sh" &
fi

declare -a NEBULA_LAUNCH_ARGS=(
  -batchmode
  -nographics
  -nebula-server
  -logFile "$NEBULA_LOG_FILE"
)

if [[ -n "${PLUTAINER_NEBULA_SAVE:-}" ]]; then
  NEBULA_LAUNCH_ARGS+=( -load "$PLUTAINER_NEBULA_SAVE" )
elif [[ "${PLUTAINER_NEBULA_NEW_GAME:-false}" == "true" ]]; then
  NEBULA_LAUNCH_ARGS+=( -newgame-cfg )
elif find "$NEBULA_SAVE_DIR" -maxdepth 1 -type f -name '*.dsv' -print -quit | grep -q .; then
  NEBULA_LAUNCH_ARGS+=( -load-latest )
else
  echo "[INFO] No save exists yet; creating one from nebulaGameDescSettings.cfg."
  NEBULA_LAUNCH_ARGS+=( -newgame-cfg )
fi

if [[ -n "${PLUTAINER_NEBULA_UPS:-}" ]]; then
  NEBULA_LAUNCH_ARGS+=( -ups "$PLUTAINER_NEBULA_UPS" )
fi
if [[ -n "${PLUTAINER_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  NEBULA_LAUNCH_ARGS+=( ${PLUTAINER_EXTRA_ARGS} )
fi

# Doorstop's winhttp proxy is how BepInEx is injected into this Unity game.
export WINEDLLOVERRIDES="winhttp=n,b;mscoree,mshtml="

# Wine still needs an X display driver even though Unity uses its null graphics
# device. Start Xvfb directly rather than through xvfb-run: Wine must remain the
# tracked child so the graceful wrapper can deliver Nebula's Ctrl+C/SIGINT save
# signal to it instead of to an intermediate shell script.
export DISPLAY=:99
Xvfb "$DISPLAY" -screen 0 640x480x24 -nolisten tcp &
XVFB_PID=$!
cleanup_nebula_xvfb() {
  kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup_nebula_xvfb EXIT
for _ in {1..50}; do
  [[ -S /tmp/.X11-unix/X99 ]] && break
  kill -0 "$XVFB_PID" 2>/dev/null || hold_indefinitely "Nebula's virtual display failed to start."
  sleep 0.1
done
[[ -S /tmp/.X11-unix/X99 ]] || hold_indefinitely "Nebula's virtual display did not become ready."

echo "[INFO] Starting ${PLUTAINER_SERVER_NAME:-Nebula server}..."
echo "[INFO] Command: wine $NEBULA_EXE ${NEBULA_LAUNCH_ARGS[*]}"
cd "$NEBULA_GAME_DIR"

# Wine can deadlock its console handler after Nebula has finished writing the
# documented _lastexit_ save. Mark the stop instant, wait until both world and
# player-data files have been replaced and settled, then terminate only the
# stuck Wine wrapper. The outer lifecycle helper still reports a clean service
# stop because the application's durable shutdown contract has completed.
NEBULA_STOP_MARKER="$NEBULA_DATA_DIR/.shutdown-request"
plutainer_graceful_stop_prepare() {
  : > "$NEBULA_STOP_MARKER"
}

plutainer_graceful_stop_finish() {
  local game_pid="$1"
  local world="$NEBULA_SAVE_DIR/_lastexit_.dsv"
  local players="$NEBULA_SAVE_DIR/_lastexit_.server"
  local previous_signature=""
  local stable_polls=0
  local signature

  for _ in {1..60}; do
    kill -0 "$game_pid" 2>/dev/null || return 0
    if [[ -f "$world" && -f "$players" && "$world" -nt "$NEBULA_STOP_MARKER" && "$players" -nt "$NEBULA_STOP_MARKER" ]]; then
      signature="$(stat -c '%s:%Y' "$world")|$(stat -c '%s:%Y' "$players")"
      if [[ "$signature" == "$previous_signature" ]]; then
        (( stable_polls += 1 ))
      else
        stable_polls=0
        previous_signature="$signature"
      fi
      if (( stable_polls >= 2 )); then
        echo "[INFO] Nebula shutdown save is complete; terminating the Wine wrapper."
        kill -TERM "$game_pid" 2>/dev/null || true
        sleep 3
        kill -KILL "$game_pid" 2>/dev/null || true
        return 0
      fi
    fi
    sleep 1
  done

  echo "[WARN] Nebula did not produce a settled shutdown save within 60s; Docker's stop timeout remains the safety limit." >&2
}

# Nebula documents Ctrl+C as its save-and-exit path. The wrapper catches the
# service's SIGTERM and forwards SIGINT to Wine, then waits for the save.
launch_game_graceful_signal INT wine "$NEBULA_EXE" "${NEBULA_LAUNCH_ARGS[@]}"
