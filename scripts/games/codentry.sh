#!/bin/bash
#
# Entry script for the `cod` family — every Plutonium, IW4x, Alterware and CoD4x
# game. Nothing in here is specific to one of them: the per-game facts live in
# the table in lib/cod.sh, and the per-engine steps are hooks it defines.
#
# The order of these steps is load-bearing and was arrived at the hard way:
#
#   stage     mirror the read-only game files into the volume, because the
#             engine needs to write next to them
#   update    fetch the server binaries (Plutonium updater, iw4x-launcher,
#             t7x.exe, or CoD4x's staged binary)
#   auto-lift a real cfg the user left at the engine path is the strongest
#             signal of intent, so it is moved into configs/ BEFORE seeding,
#             or the seed's cp -n would paper over it
#   seed      bundled community configs, first run only
#   link      fan configs/*.cfg out to the engine (and mod) directory
#   validate  refuse with an explanation rather than starting broken
#   launch    with the 30s crash throttle
#
set -euo pipefail

PLUTAINER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUTAINER_ROOT/lib/core.sh"

detect_game_type     || hold_indefinitely "detect_game_type failed."
check_volume_version || hold_indefinitely "check_volume_version failed."

# Hook lookup order, most specific first. A game inherits its engine's
# behaviour and overrides only what genuinely differs.
declare -a COD_HOOKS=("$GAME_NAME" "$BASE_GAME" "$COD_ENGINE")

# Catch a mis-named or missing hook now, with a clear message, rather than
# silently skipping the step later.
plutainer_require_hooks cod "$(IFS=,; echo "${COD_HOOKS[*]}")" stage update launch \
  || hold_indefinitely "Plutainer is missing an implementation for ${GAME_NAME}."

resolve_config_layout
resolve_active_port || hold_indefinitely "Could not resolve the server port."

echo "[INFO] ${COD_LABEL} — ${GAME_NAME}"
echo "[INFO]   gamefiles : $PLUTAINER_GAMEFILES_DIR"
echo "[INFO]   config    : $CONFIG_PATH"
echo "[INFO]   port      : $ACTIVE_PORT"

mkdir -p "$PLUTAINER_GAMEFILES_DIR" "$PLUTAINER_CONFIGS_DIR" "$PLUTAINER_APP_DIR/logs"

# --- Game files -------------------------------------------------------------
echo "[INFO] Linking game files..."
plutainer_hook cod stage "${COD_HOOKS[@]}"

# --- Server binaries --------------------------------------------------------
plutainer_hook cod update "${COD_HOOKS[@]}"

# --- Configs ----------------------------------------------------------------
auto_lift_user_config

if [[ "${PLUTAINER_SKIP_SEED:-}" != "true" && -n "$COD_SEED_KEY" ]]; then
  seed_configs "$COD_SEED_KEY" "$COD_SEED_ASSET_ROOT" "$COD_SEED_CFG_ROOT"
fi

link_configs "$ENGINE_CONFIG_DIR" "$MOD_CONFIG_DIR"

# --- Validate ---------------------------------------------------------------
[[ -n "${PLUTAINER_CONFIG_FILE:-}" ]] || hold_indefinitely \
  "PLUTAINER_CONFIG_FILE is not set. Name the server config to run (e.g. 'server.cfg')."

# Optional: per-engine environment checks, e.g. Plutonium's server key.
plutainer_hook cod validate "${COD_HOOKS[@]}" || true

ensure_config_present || hold_indefinitely "Config file not found. See [ERROR] above."

# Opt-in; a no-op unless PLUTAINER_RCON_PASSWORD is set to something non-empty.
apply_rcon_password

# --- Launch -----------------------------------------------------------------
declare -a COD_LAUNCH_CMD=()
COD_WORKDIR="$PLUTAINER_GAMEFILES_DIR"
plutainer_hook cod launch "${COD_HOOKS[@]}"

(( ${#COD_LAUNCH_CMD[@]} )) || hold_indefinitely \
  "No launch command was built for ${GAME_NAME}. This is a bug in Plutainer."

if [[ "${PLUTAINER_LOG_SYMLINKS:-true}" != "false" ]]; then
  "$PLUTAINER_ROOT/log-watcher.sh" &
fi

cd "$COD_WORKDIR"

echo "[INFO] Starting ${PLUTAINER_SERVER_NAME:-$COD_LABEL}..."
echo "[INFO] Command: ${COD_LAUNCH_CMD[*]}"
launch_game "${COD_LAUNCH_CMD[@]}"
