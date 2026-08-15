#!/bin/bash
#
# 7 Days to Die dedicated server entrypoint.
# The official Linux server is installed into the persistent app volume with
# SteamCMD; no separately mounted game files are required.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/game-config.sh"

detect_game_type || hold_indefinitely "Could not detect the configured game."

if [[ "$(uname -m)" != "x86_64" ]]; then
  hold_indefinitely "7 Days to Die is amd64-only: its official Linux dedicated server is an x86_64 binary."
fi

STEAMCMD="/home/plutainer/.plutainer/steamcmd/steamcmd.sh"
SERVER_DIR="$PLUTAINER_RUNTIME_DIR/7dtd"
DATA_DIR="$PLUTAINER_RUNTIME_DIR/7dtd-data"
SERVER_BINARY="$SERVER_DIR/7DaysToDieServer.x86_64"

mkdir -p "$SERVER_DIR" "$DATA_DIR" "$PLUTAINER_CONFIGS_DIR" "$PLUTAINER_APP_DIR/logs"

if [[ ! -x "$STEAMCMD" ]]; then
  hold_indefinitely "SteamCMD is unavailable in this image. 7 Days to Die requires the linux/amd64 image."
fi

if [[ "${PLUTAINER_AUTO_UPDATE:-true}" != "false" ]]; then
  echo "[INFO] Installing/updating 7 Days to Die Dedicated Server (Steam app 294420)..."
  steam_args=(
    +force_install_dir "$SERVER_DIR"
    +login anonymous
    +app_update 294420
  )
  if [[ -n "${PLUTAINER_7DTD_BETA:-}" ]]; then
    steam_args+=( -beta "$PLUTAINER_7DTD_BETA" )
  fi
  steam_args+=( +quit )
  "$STEAMCMD" "${steam_args[@]}" || hold_indefinitely "SteamCMD could not install/update 7 Days to Die. See the output above."
elif [[ ! -x "$SERVER_BINARY" ]]; then
  hold_indefinitely "PLUTAINER_AUTO_UPDATE=false, but no 7 Days to Die server is installed at $SERVER_BINARY."
else
  echo "[INFO] Auto-update disabled; using the existing 7 Days to Die installation."
fi

if [[ ! -x "$SERVER_BINARY" ]]; then
  hold_indefinitely "SteamCMD completed, but $SERVER_BINARY is missing or not executable."
fi

# The Steam depot provides the authoritative config template. Copy it only on
# first run so image/game updates never overwrite the user's settings.
CONFIG_FILE="${PLUTAINER_CONFIG_FILE:-serverconfig.xml}"
CONFIG_PATH="$PLUTAINER_CONFIGS_DIR/$CONFIG_FILE"
if [[ ! -e "$CONFIG_PATH" && "$CONFIG_FILE" == "serverconfig.xml" && "${PLUTAINER_SKIP_SEED:-false}" != "true" && -f "$SERVER_DIR/serverconfig.xml" ]]; then
  cp "$SERVER_DIR/serverconfig.xml" "$CONFIG_PATH"
  echo "[INFO] Created $CONFIG_PATH from the current Steam server template."
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "[ERROR] PLUTAINER_CONFIG_FILE='$CONFIG_FILE' but no such file exists at $CONFIG_PATH." >&2
  echo "[ERROR] Put an XML server config in $PLUTAINER_CONFIGS_DIR, or use the default serverconfig.xml." >&2
  hold_indefinitely "7 Days to Die configuration is missing."
fi

# PLUTAINER_PORT and PLUTAINER_SERVER_NAME live in XML for 7DTD rather than in
# command-line cvars. Apply them without reserializing the document, preserving
# the stock template's comments and formatting.
if [[ -n "${CUSTOM_PORT:-}" || -n "${PLUTAINER_SERVER_NAME:-}" ]]; then
  set +e
  CONFIG_TARGET="$CONFIG_PATH" \
  CONFIG_PORT="${CUSTOM_PORT:-}" \
  CONFIG_SERVER_NAME="${PLUTAINER_SERVER_NAME:-}" \
  python3 - <<'PY'
import os
import re
import sys
from xml.sax.saxutils import escape

path = os.environ["CONFIG_TARGET"]
port = os.environ["CONFIG_PORT"]
server_name = os.environ["CONFIG_SERVER_NAME"]

if port:
    try:
        port_value = int(port)
    except ValueError:
        print(f"[ERROR] PLUTAINER_PORT must be an integer, got {port!r}.", file=sys.stderr)
        sys.exit(1)
    if not 1 <= port_value <= 65535:
        print(f"[ERROR] PLUTAINER_PORT must be between 1 and 65535, got {port_value}.", file=sys.stderr)
        sys.exit(1)

with open(path, "r", encoding="utf-8") as fh:
    text = fh.read()

updated = text

def set_property(name, desired):
    global updated
    pattern = re.compile(
        rf'(<property\s+name=["\']{re.escape(name)}["\']\s+value=["\'])'
        r'[^"\']*'
        r'(["\'])',
        re.IGNORECASE,
    )
    if not pattern.search(updated):
        print(f"[ERROR] The XML config has no {name} property.", file=sys.stderr)
        sys.exit(1)
    encoded = escape(str(desired), {'"': '&quot;', "'": '&apos;'})
    updated = pattern.sub(rf"\g<1>{encoded}\g<2>", updated, count=1)

if port:
    set_property("ServerPort", port_value)
if server_name:
    set_property("ServerName", server_name)

if updated != text:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(updated)
    applied = []
    if port:
        applied.append(f"ServerPort={port_value}")
    if server_name:
        applied.append(f"ServerName={server_name!r}")
    print(f"[INFO] Set {', '.join(applied)} in {os.path.basename(path)}.")
PY
  port_config_rc=$?
  set -e
  if [[ $port_config_rc -ne 0 ]]; then
    hold_indefinitely "Could not apply Plutainer settings to the 7 Days to Die XML config."
  fi
fi

if [[ "${PLUTAINER_LOG_SYMLINKS:-true}" != "false" ]]; then
  "$SCRIPT_DIR/log-watcher.sh" &
fi

LOG_FILE="$DATA_DIR/server-output.log"
echo "[INFO] Starting ${PLUTAINER_SERVER_NAME:-7 Days to Die} with config $CONFIG_PATH."
echo "[INFO] Persistent world data: $DATA_DIR"

extra_args=()
if [[ -n "${PLUTAINER_EXTRA_ARGS:-}" ]]; then
  # Match the existing entrypoints' compatibility behaviour: this variable is
  # intentionally shell-tokenised, so users can pass multiple launch flags.
  read -r -a extra_args <<< "$PLUTAINER_EXTRA_ARGS"
fi

# Docker sends SIGTERM to the entrypoint. Forward it to the native Linux server,
# which runs its ServerShutdown path, saves world state, and exits. The shared
# launch wrapper waits for that exit; Docker's stop timeout is the upper bound.
graceful_shutdown_game() {
  local game_pid="$1"
  echo "[INFO] Forwarding SIGTERM to 7DTD process ${game_pid}."
  kill -TERM "$game_pid"
}

cd "$SERVER_DIR"
export LD_LIBRARY_PATH="$SERVER_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
launch_game "$SERVER_BINARY" \
  -logfile "$LOG_FILE" \
  -quit -batchmode -nographics -dedicated \
  -configfile="$CONFIG_PATH" \
  -UserDataFolder="$DATA_DIR" \
  "${extra_args[@]}"
