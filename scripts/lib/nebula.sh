#!/bin/bash
#
# Nebula family helpers. Dyson Sphere Program is a Windows client game rather
# than an anonymously downloadable dedicated-server depot, so the user supplies
# their owned game files and Plutainer overlays BepInEx + Nebula into app/.
#

NEBULA_GAMES=(nebula)

nebula_is_known_game() {
  [[ "$1" == "nebula" ]]
}

nebula_resolve_game() {
  local game="${1:-$GAME_NAME}"
  nebula_is_known_game "$game" || {
    echo "[ERROR] '${game}' is not a known Nebula game." >&2
    return 1
  }

  BASE_GAME="dsp"
  NEBULA_DEFAULT_PORT=8469
  NEBULA_CONFIG_FILE="nebula.cfg"
  NEBULA_QUERY="listener"
  NEBULA_RUNTIME_DIR="$PLUTAINER_NEBULA_DIR/$game"
  NEBULA_GAME_DIR="$NEBULA_RUNTIME_DIR/game"
  NEBULA_DATA_DIR="$PLUTAINER_GAMEDATA_DIR/$game"
  NEBULA_DOCUMENTS_DIR="$NEBULA_DATA_DIR/Dyson Sphere Program"
  NEBULA_SAVE_DIR="$NEBULA_DOCUMENTS_DIR/Save"
  NEBULA_LOG_FILE="$NEBULA_DATA_DIR/server-output.log"
  ENGINE_CONFIG_DIR="$NEBULA_GAME_DIR/BepInEx/config"
}

nebula_resolve_config_path() {
  nebula_resolve_game || return 1
  CONFIG_FILE="${CONFIG_FILE:-$NEBULA_CONFIG_FILE}"
  CONFIG_SOT_DIR="$PLUTAINER_CONFIGS_DIR"
  ALT_CONFIG_DIR="$ENGINE_CONFIG_DIR"
  CONFIG_PATH="$CONFIG_SOT_DIR/$CONFIG_FILE"
}

nebula_validate_source() {
  [[ -d "$PLUTAINER_SOURCE_DIR" ]] || {
    echo "[ERROR] Nebula needs your Dyson Sphere Program files mounted at $PLUTAINER_SOURCE_DIR." >&2
    return 1
  }

  local exe
  exe=$(find "$PLUTAINER_SOURCE_DIR" -maxdepth 1 -type f -iname 'DSPGAME.exe' -print -quit 2>/dev/null)
  [[ -n "$exe" ]] || {
    echo "[ERROR] No DSPGAME.exe was found at $PLUTAINER_SOURCE_DIR." >&2
    echo "  Mount the root of a legally owned Dyson Sphere Program installation, read-only." >&2
    return 1
  }
}

# Mirror every supplied game file into a writable directory, but deliberately
# do not import a host-side BepInEx installation. Plutainer owns that overlay so
# package updates never write through a symlink into the read-only mount.
nebula_stage_game() {
  mkdir -p "$NEBULA_GAME_DIR"

  local entry name
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    case "${name,,}" in
      bepinex) continue ;;
    esac
    link_dir_contents "$PLUTAINER_SOURCE_DIR" "$NEBULA_GAME_DIR" "$name"
  done < <(find "$PLUTAINER_SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    case "${name,,}" in
      winhttp.dll|doorstop_config.ini|steam_appid.txt) continue ;;
    esac
    if [[ -e "$NEBULA_GAME_DIR/$name" && ! -L "$NEBULA_GAME_DIR/$name" ]]; then
      continue
    fi
    ln -sfn "$entry" "$NEBULA_GAME_DIR/$name"
  done < <(find "$PLUTAINER_SOURCE_DIR" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0)

  find "$NEBULA_GAME_DIR" -maxdepth 1 -xtype l -delete 2>/dev/null || true

  NEBULA_EXE=$(find "$NEBULA_GAME_DIR" -maxdepth 1 \( -type f -o -type l \) -iname 'DSPGAME.exe' -print -quit)
  [[ -n "$NEBULA_EXE" ]] || return 1

  # Nebula's official headless instructions use this file when launching the
  # executable directly rather than through the Steam UI.
  printf '1366540\n' > "$NEBULA_GAME_DIR/steam_appid.txt"
}

# DSP is a desktop Steam title rather than a dedicated-server depot and calls
# SteamAPI_Init even in Nebula's headless mode. A full Steam client would put
# account credentials and Steam Guard inside the server container. Instead we
# overlay the pinned API-compatible DLL bundled in the image into the writable
# runtime tree. The user's original DLL remains untouched in the read-only
# gamefiles mount and is linked back on the next stage if this image stops
# providing the overlay.
nebula_apply_steam_api() {
  local source="$PLUTAINER_ROOT/nebula/steam-api/steam_api64.dll"
  local target="$NEBULA_GAME_DIR/DSPGAME_Data/Plugins/x86_64/steam_api64.dll"

  [[ -s "$source" ]] || {
    echo "[ERROR] The bundled Nebula Steam API compatibility DLL is missing." >&2
    return 1
  }
  [[ -d "$(dirname "$target")" ]] || {
    echo "[ERROR] DSP's x86_64 plugin directory is missing from the supplied game files." >&2
    return 1
  }

  rm -f "$target"
  cp "$source" "$target"
  mkdir -p "$(dirname "$target")/steam_settings"
  : > "$(dirname "$target")/steam_settings/disable_networking.txt"
  echo "[INFO] Applied the bundled headless Steam API compatibility layer to the writable runtime."
}

nebula_install_mods() {
  local nebula_version="${PLUTAINER_NEBULA_VERSION:-latest}"
  local package="nebula-NebulaMultiplayerMod:${nebula_version}"

  local -a packages=("$package")
  if [[ -n "${PLUTAINER_NEBULA_MODS:-}" ]]; then
    local -a extra=()
    IFS=',' read -ra extra <<< "$PLUTAINER_NEBULA_MODS"
    local mod
    for mod in "${extra[@]}"; do
      mod="${mod#"${mod%%[![:space:]]*}"}"
      mod="${mod%"${mod##*[![:space:]]}"}"
      [[ -n "$mod" ]] && packages+=("$mod")
    done
  fi

  echo "[INFO] Thunderstore: Nebula request is ${nebula_version}; checking ${#packages[@]} top-level package(s)."

  if [[ "${PLUTAINER_AUTO_UPDATE:-true}" != "false" ]]; then
    local install_status=0
    python3 "$PLUTAINER_ROOT/install-thunderstore.py" \
      --game-dir "$NEBULA_GAME_DIR" "${packages[@]}" || install_status=$?
    if (( install_status != 0 )); then
      if (( install_status == 2 )); then
        hold_indefinitely "Invalid PLUTAINER_NEBULA_VERSION or PLUTAINER_NEBULA_MODS setting."
      fi
      if [[ -f "$NEBULA_GAME_DIR/BepInEx/core/BepInEx.dll" ]] && \
         find "$NEBULA_GAME_DIR/BepInEx/plugins/nebula-NebulaMultiplayerMod" \
           -maxdepth 1 -type f -name 'NebulaWorld.dll' -print -quit 2>/dev/null | grep -q .; then
        echo "[WARN] Nebula update failed; starting the existing mod installation instead." >&2
      else
        hold_indefinitely "Could not install/update Nebula from Thunderstore."
      fi
    fi
  else
    echo "[INFO] Auto-update disabled; using the existing Nebula/BepInEx overlay."
  fi

  [[ -f "$NEBULA_GAME_DIR/BepInEx/core/BepInEx.dll" ]] || \
    hold_indefinitely "BepInEx is not installed. Allow one start with PLUTAINER_AUTO_UPDATE=true."
  find "$NEBULA_GAME_DIR/BepInEx/plugins/nebula-NebulaMultiplayerMod" \
    -maxdepth 1 -type f -name 'NebulaWorld.dll' -print -quit 2>/dev/null | grep -q . || \
    hold_indefinitely "NebulaMultiplayerMod is not installed. Allow one start with PLUTAINER_AUTO_UPDATE=true."
}

nebula_seed_configs() {
  [[ "${PLUTAINER_SKIP_SEED:-false}" == "true" ]] && return 0
  local src name
  for name in nebula.cfg nebulaGameDescSettings.cfg; do
    src="/home/plutainer/.plutainer/seed-configs/nebula/$name"
    [[ -e "$PLUTAINER_CONFIGS_DIR/$name" || ! -f "$src" ]] && continue
    cp "$src" "$PLUTAINER_CONFIGS_DIR/$name"
    echo "[INFO] Seeded $PLUTAINER_CONFIGS_DIR/$name."
  done
}

nebula_prepare_storage() {
  mkdir -p "$PLUTAINER_CONFIGS_DIR" "$NEBULA_SAVE_DIR" "$(dirname "$ENGINE_CONFIG_DIR")"

  # Lift BepInEx's stock config on first install, then make its entire config
  # directory the user-facing app/configs directory. Plugin-generated configs
  # therefore persist automatically without knowing every optional mod name.
  if [[ -d "$ENGINE_CONFIG_DIR" && ! -L "$ENGINE_CONFIG_DIR" ]]; then
    find "$ENGINE_CONFIG_DIR" -maxdepth 1 -type f -name '*.cfg' -exec mv -n -t "$PLUTAINER_CONFIGS_DIR" {} + 2>/dev/null || true
    rmdir "$ENGINE_CONFIG_DIR" 2>/dev/null || {
      echo "[ERROR] Could not replace non-empty $ENGINE_CONFIG_DIR with the app/configs link." >&2
      return 1
    }
  fi
  if [[ ! -e "$ENGINE_CONFIG_DIR" || -L "$ENGINE_CONFIG_DIR" ]]; then
    ln -sfn "$PLUTAINER_CONFIGS_DIR" "$ENGINE_CONFIG_DIR"
  fi

  nebula_seed_configs

  local wine_docs="${WINEPREFIX:-$HOME/.wine}/drive_c/users/${USER:-plutainer}/Documents"
  local wine_dsp="$wine_docs/Dyson Sphere Program"
  mkdir -p "$wine_docs"
  if [[ -d "$wine_dsp" && ! -L "$wine_dsp" ]]; then
    find "$wine_dsp" -mindepth 1 -maxdepth 1 -exec mv -n -t "$NEBULA_DOCUMENTS_DIR" {} + 2>/dev/null || true
    rmdir "$wine_dsp" 2>/dev/null || {
      echo "[WARN] Could not replace non-empty $wine_dsp; saves may not persist in the app volume." >&2
      return 0
    }
  fi
  ln -sfn "$NEBULA_DOCUMENTS_DIR" "$wine_dsp"
}

# Set one BepInEx ConfigFile key without reserialising or discarding comments.
# Args: path, section, key, value
nebula_cfg_set() {
  CFG_PATH="$1" CFG_SECTION="$2" CFG_KEY="$3" CFG_VALUE="$4" python3 - <<'PY'
import os
import re

path = os.environ["CFG_PATH"]
section = os.environ["CFG_SECTION"]
key = os.environ["CFG_KEY"]
value = os.environ["CFG_VALUE"]
value = value.replace("\r", " ").replace("\n", " ")

try:
    with open(path, "r", encoding="utf-8-sig", errors="surrogateescape") as fh:
        lines = fh.read().splitlines()
except FileNotFoundError:
    lines = []

section_re = re.compile(r"^\s*\[" + re.escape(section) + r"\]\s*$", re.I)
key_re = re.compile(r"^(\s*)" + re.escape(key) + r"\s*=.*$", re.I)
start = next((i for i, line in enumerate(lines) if section_re.match(line)), None)

if start is None:
    if lines and lines[-1].strip():
        lines.append("")
    lines.extend([f"[{section}]", f"{key} = {value}"])
else:
    end = next((i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith("[")), len(lines))
    match = next((i for i in range(start + 1, end) if key_re.match(lines[i])), None)
    if match is None:
        lines.insert(end, f"{key} = {value}")
    else:
        indent = key_re.match(lines[match]).group(1)
        lines[match] = f"{indent}{key} = {value}"

updated = "\n".join(lines) + "\n"
try:
    with open(path, "r", encoding="utf-8-sig", errors="surrogateescape") as fh:
        original = fh.read()
except FileNotFoundError:
    original = ""
if updated != original:
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(updated)
    print(f"[INFO] Set {key} in {os.path.basename(path)}.")
PY
}

nebula_configure() {
  nebula_cfg_set "$PLUTAINER_CONFIGS_DIR/nebula.cfg" "Nebula - Settings" HostPort "$ACTIVE_PORT"
  nebula_cfg_set "$PLUTAINER_CONFIGS_DIR/nebula.cfg" "Nebula - Settings" EnableDiscordRPC false

  if [[ -n "${PLUTAINER_NEBULA_SERVER_PASSWORD:-}" ]]; then
    nebula_cfg_set "$PLUTAINER_CONFIGS_DIR/nebula.cfg" "Nebula - Settings" ServerPassword "$PLUTAINER_NEBULA_SERVER_PASSWORD"
  fi
  if [[ -n "${PLUTAINER_NEBULA_REMOTE_PASSWORD:-}" ]]; then
    nebula_cfg_set "$PLUTAINER_CONFIGS_DIR/nebula.cfg" "Nebula - Settings" RemoteAccessEnabled true
    nebula_cfg_set "$PLUTAINER_CONFIGS_DIR/nebula.cfg" "Nebula - Settings" RemoteAccessPassword "$PLUTAINER_NEBULA_REMOTE_PASSWORD"
  fi
  if [[ -n "${PLUTAINER_NEBULA_AUTO_PAUSE:-}" ]]; then
    nebula_cfg_set "$PLUTAINER_CONFIGS_DIR/nebula.cfg" "Nebula - Settings" AutoPauseEnabled "$PLUTAINER_NEBULA_AUTO_PAUSE"
  fi

  # The Thunderstore pack disables this because desktop users normally do not
  # want a second console. In a headless container it is the useful output.
  nebula_cfg_set "$PLUTAINER_CONFIGS_DIR/BepInEx.cfg" "Logging.Console" Enabled true
}

nebula_resolve_admin_endpoint() {
  ADMIN_PROTOCOL="none"
  ADMIN_PORT=""
  ADMIN_PASSWORD=""
}
