#!/bin/bash
#
# SteamCMD family helpers. Sourced by lib/core.sh.
#
# One entry script (games/steamentry.sh) serves every game in this family; the
# per-game differences live in the table below and in the optional hook
# functions beneath it. Adding a game should mean adding a table row and a
# couple of hooks, not writing a new entry script.
#
# What the family has in common:
#   - no gamefiles mount; SteamCMD installs the dedicated server itself
#   - the install lives in the app volume so it survives container recreation
#   - persistent world/save data is kept OUT of the install directory, so a
#     SteamCMD update can never touch it
#   - app/configs/ is still the source of truth for configuration, exactly as it
#     is for the CoD families; whether that means pointing the server at it or
#     symlinking into the install is per game
#
# What is NOT shared, and is per game: the config format, where the port is set,
# and which admin protocol the server speaks. 7DTD and the Source servers
# disagree on all three, which is the useful thing about having both here — if
# a new game needs a `case` block in steamentry.sh rather than a table row and a
# hook, the abstraction has slipped.
#

STEAM_CMD="/home/plutainer/.plutainer/steamcmd/steamcmd.sh"

# Games this family serves. derive_family() consults this rather than carrying
# its own copy, so adding a game means editing this file and nothing else.
STEAM_GAMES=(7dtd hl2dm l4d2 cs2)

steam_is_known_game() {
  local candidate="$1" game
  for game in "${STEAM_GAMES[@]}"; do
    [[ "$game" == "$candidate" ]] && return 0
  done
  return 1
}

# Per-game table. Fields set by steam_resolve_game:
#
#   STEAM_ENGINE          engine family, used as the hook fallback. Games
#                         sharing an engine share their hooks; a game overrides
#                         only what genuinely differs (CS2 is srcds for config
#                         handling but has its own launch arguments).
#   STEAM_APP_ID          Steam application ID of the DEDICATED SERVER
#   STEAM_SERVER_BINARY   executable, relative to the install dir
#   STEAM_GAME_DIR        mod/game directory inside the install, holding cfg/
#   STEAM_WORKDIR         optional, cwd to launch from, relative to the install
#                         dir. Empty means the install dir itself.
#   STEAM_DEFAULT_MAP     map to boot into (srcds only)
#   STEAM_INSTALL_PLATFORMS
#                         optional, space separated. Run app_update once per
#                         platform, in order, forcing SteamCMD's platform type
#                         each time. Empty (the normal case) means one plain
#                         app_update. See the l4d2 row for why this exists.
#   STEAM_DEFAULT_PORT    game port when PLUTAINER_PORT is unset
#   STEAM_UDP_SPAN        how many consecutive UDP ports the game occupies
#   STEAM_CONFIG_FILE     default PLUTAINER_CONFIG_FILE
#   STEAM_QUERY           a2s | tcp   — how healthcheck.sh probes it
#   STEAM_ADMIN           telnet | source-rcon | none — what rcon-cli speaks
#
# Returns 1 for a game that is not in the table.
steam_resolve_game() {
  local game="${1:-$GAME_NAME}"

  # Optional fields, cleared first so a value never leaks in from a previous
  # call for a different game.
  STEAM_GAME_DIR=""
  STEAM_DEFAULT_MAP=""
  STEAM_INSTALL_PLATFORMS=""
  STEAM_WORKDIR=""
  STEAM_ENGINE=""

  case "$game" in
    7dtd)
      STEAM_ENGINE="unity"
      STEAM_APP_ID=294420
      STEAM_SERVER_BINARY="7DaysToDieServer.x86_64"
      STEAM_DEFAULT_PORT=26900
      STEAM_UDP_SPAN=4
      STEAM_CONFIG_FILE="serverconfig.xml"
      STEAM_QUERY="a2s"
      STEAM_ADMIN="telnet"
      ;;
    cs2)
      # Source 2, and the reason launch args are a hook rather than a family
      # constant: no srcds_run wrapper, a different directory layout, and RCON
      # has to be switched on at the command line.
      #
      # Launched through the shipped `cs2.sh` rather than the raw binary under
      # bin/linuxsteamrt64/: that wrapper sets up the Steam Runtime library
      # paths the binary is linked against.
      STEAM_ENGINE="srcds"
      STEAM_APP_ID=730
      STEAM_SERVER_BINARY="game/cs2.sh"
      STEAM_WORKDIR="game"
      STEAM_GAME_DIR="game/csgo"
      STEAM_DEFAULT_PORT=27015
      STEAM_UDP_SPAN=1
      STEAM_CONFIG_FILE="server.cfg"
      STEAM_QUERY="a2s"
      STEAM_ADMIN="source-rcon"
      STEAM_DEFAULT_MAP="de_dust2"
      ;;
    l4d2)
      # Two-phase install, and it is not optional. Valve restricted anonymous
      # Linux installs of this app: every depot including the 9.5 GB *content*
      # one is flagged `windows`, so a plain `app_update` on Linux dies with
      # "Invalid platform" (ValveSoftware/steam-for-linux#11522, still open, and
      # it takes LinuxGSM down with it). Pulling the content as Windows and then
      # re-running as Linux overlays the native binaries depot on top, which
      # yields a working native Linux server with no Wine and no Steam account.
      STEAM_ENGINE="srcds"
      STEAM_APP_ID=222860
      STEAM_SERVER_BINARY="srcds_run"
      STEAM_GAME_DIR="left4dead2"
      STEAM_INSTALL_PLATFORMS="windows linux"
      STEAM_DEFAULT_PORT=27015
      STEAM_UDP_SPAN=1
      STEAM_CONFIG_FILE="server.cfg"
      STEAM_QUERY="a2s"
      STEAM_ADMIN="source-rcon"
      STEAM_DEFAULT_MAP="c2m1_highway"
      ;;
    hl2dm)
      # Source engine (srcds). Present as much to keep the family honest as for
      # its own sake: it disagrees with 7DTD about nearly everything the table
      # exists to capture — the config is a plain cfg the engine execs from
      # inside the SteamCMD-owned install, the port is a launch flag rather than
      # a config value, and administration is Valve's RCON rather than telnet.
      # Everything here applies unchanged to the other srcds games.
      STEAM_ENGINE="srcds"
      STEAM_APP_ID=232370
      STEAM_SERVER_BINARY="srcds_run"
      STEAM_GAME_DIR="hl2mp"
      STEAM_DEFAULT_PORT=27015
      STEAM_UDP_SPAN=1
      STEAM_CONFIG_FILE="server.cfg"
      STEAM_QUERY="a2s"
      STEAM_ADMIN="source-rcon"
      STEAM_DEFAULT_MAP="dm_lockdown"
      ;;
    *)
      echo "[ERROR] '${game}' is not a known SteamCMD game." >&2
      return 1
      ;;
  esac

  # Explicit override, for testing an app ID or branch the table does not carry.
  STEAM_APP_ID="${PLUTAINER_STEAM_APP_ID:-$STEAM_APP_ID}"

  # These games have no engine/base distinction worth making — the tag is the
  # game — but BASE_GAME is part of the shared vocabulary, so it is set.
  BASE_GAME="$game"

  STEAM_INSTALL_DIR="$PLUTAINER_STEAM_DIR/$game"
  STEAM_DATA_DIR="$PLUTAINER_GAMEDATA_DIR/$game"
  STEAM_SERVER_PATH="$STEAM_INSTALL_DIR/$STEAM_SERVER_BINARY"
  STEAM_LOG_FILE="$STEAM_DATA_DIR/server-output.log"

  # SteamCMD games are pointed at app/configs/ directly rather than having cfgs
  # fanned out to an engine directory.
  ENGINE_CONFIG_DIR="$PLUTAINER_CONFIGS_DIR"
}

# Config path for a SteamCMD game. These do not use the engine-dir symlink
# fan-out: the server is pointed straight at configs/ with a command-line flag,
# so configs/ IS the only location and there is nothing to link. That also makes
# PLUTAINER_USE_RAW_CONFIGS meaningless here.
steam_resolve_config_path() {
  steam_resolve_game || return 1
  CONFIG_FILE="${CONFIG_FILE:-$STEAM_CONFIG_FILE}"
  CONFIG_SOT_DIR="$PLUTAINER_CONFIGS_DIR"
  ALT_CONFIG_DIR="$PLUTAINER_CONFIGS_DIR"
  ENGINE_CONFIG_DIR="$PLUTAINER_CONFIGS_DIR"
  CONFIG_PATH="$CONFIG_SOT_DIR/$CONFIG_FILE"
}

# Install or update the dedicated server through SteamCMD.
#
# Anonymous login only. Every dedicated server in this family is free to
# download without an account, and a game that needs credentials does not belong
# here without a rethink — we are not asking anyone to put a Steam password in a
# compose file.
# How many times to attempt the install. See the comment in
# steam_install_or_update for why more than one is needed.
STEAM_UPDATE_ATTEMPTS="${PLUTAINER_STEAM_ATTEMPTS:-3}"

steam_install_or_update() {
  mkdir -p "$STEAM_INSTALL_DIR" "$STEAM_DATA_DIR"

  if [[ ! -x "$STEAM_CMD" ]]; then
    hold_indefinitely "SteamCMD is not present in this image, so ${GAME_NAME} cannot be installed. SteamCMD games need the linux/amd64 image."
  fi

  if [[ "${PLUTAINER_AUTO_UPDATE:-true}" == "false" ]]; then
    if [[ ! -x "$STEAM_SERVER_PATH" ]]; then
      hold_indefinitely "PLUTAINER_AUTO_UPDATE=false, but no server is installed at ${STEAM_SERVER_PATH}. Allow one update through to install it."
    fi
    echo "[INFO] Auto-update disabled; using the existing ${GAME_NAME} installation."
    return 0
  fi

  echo "[INFO] Installing/updating ${GAME_NAME} (Steam app ${STEAM_APP_ID})..."

  # SteamCMD applies these positionally: +force_install_dir must precede +login,
  # and each +app_update takes the platform type in effect at that point.
  # +@bClientTryRequestManifestWithoutCode works around SteamPipe returning
  # HTTP 401 for manifests on some apps (CS2 in particular). Harmless elsewhere.
  local -a args=( +force_install_dir "$STEAM_INSTALL_DIR"
                  +@bClientTryRequestManifestWithoutCode 1
                  +login anonymous )
  local -a update=( +app_update "$STEAM_APP_ID" )
  if [[ -n "${PLUTAINER_STEAM_BETA:-}" ]]; then
    update+=( -beta "$PLUTAINER_STEAM_BETA" )
    [[ -n "${PLUTAINER_STEAM_BETA_PASSWORD:-}" ]] && update+=( -betapassword "$PLUTAINER_STEAM_BETA_PASSWORD" )
    echo "[INFO] Steam branch: ${PLUTAINER_STEAM_BETA}"
  fi

  if [[ -n "$STEAM_INSTALL_PLATFORMS" ]]; then
    # Multi-phase: one app_update per platform, in table order, each preceded by
    # a platform-type switch. The last phase validates, which is what pulls the
    # native files over the ones fetched under the earlier platform.
    echo "[INFO] Multi-phase install (platforms: ${STEAM_INSTALL_PLATFORMS})."
    local platform last
    last="${STEAM_INSTALL_PLATFORMS##* }"
    for platform in $STEAM_INSTALL_PLATFORMS; do
      args+=( "+@sSteamCmdForcePlatformType" "$platform" "${update[@]}" )
      [[ "$platform" == "$last" ]] && args+=( validate )
    done
  else
    args+=( "${update[@]}" )
    [[ "${PLUTAINER_STEAM_VALIDATE:-false}" == "true" ]] && args+=( validate )
  fi

  args+=( +quit )

  # Retried, because SteamCMD's first contact is unreliable in a fresh container.
  # Its first run downloads its own client and re-execs, and an +app_update
  # issued before that has settled fails with the unhelpful message
  #
  #     ERROR! Failed to install app '<id>' (Missing configuration)
  #
  # Measured on both 7DTD and HL2:DM in fresh containers: the attempt
  # immediately afterwards succeeded, with no other change. Pre-bootstrapping
  # with `steamcmd.sh +quit` first — either here or at image build time — was
  # tried and did not reliably prevent it.
  #
  # Nothing is lost by retrying: app_update is idempotent, and a genuinely
  # broken install (bad app ID, no Linux depot) fails identically every time and
  # still ends in the refusal below.
  local attempt
  for (( attempt = 1; attempt <= STEAM_UPDATE_ATTEMPTS; attempt++ )); do
    if "$STEAM_CMD" "${args[@]}"; then
      break
    fi
    if (( attempt < STEAM_UPDATE_ATTEMPTS )); then
      echo "[WARN] SteamCMD attempt ${attempt}/${STEAM_UPDATE_ATTEMPTS} failed; retrying in 5s." >&2
      # Stale appmanifest data makes SteamPipe answer HTTP 401 for files it
      # thinks we already have, which then fails identically on every retry.
      # Dropping it costs a re-check, not a re-download of intact files.
      rm -rf "$STEAM_INSTALL_DIR/steamapps"
      sleep 5
      continue
    fi

    # An update failure with a working install on disk is survivable: the server
    # that is already there still runs. A first run has nothing to fall back to.
    if [[ -x "$STEAM_SERVER_PATH" ]]; then
      echo "[WARN] SteamCMD failed; starting the existing installation instead." >&2
      return 0
    fi
    hold_indefinitely "SteamCMD could not install ${GAME_NAME} (app ${STEAM_APP_ID}) after ${STEAM_UPDATE_ATTEMPTS} attempts. See the output above."
  done

  [[ -x "$STEAM_SERVER_PATH" ]] || \
    hold_indefinitely "SteamCMD reported success but ${STEAM_SERVER_PATH} is missing or not executable."
}

# Copy the installed server's own config template into configs/, first run only,
# so a game update can never overwrite what the user has edited. Idempotent.
# Args: <template path, relative to the install dir>
steam_seed_config() {
  local template="$STEAM_INSTALL_DIR/$1"

  [[ "${PLUTAINER_SKIP_SEED:-false}" == "true" ]] && return 0
  [[ -e "$CONFIG_PATH" ]] && return 0
  [[ "$CONFIG_FILE" == "$STEAM_CONFIG_FILE" ]] || return 0
  [[ -f "$template" ]] || return 0

  mkdir -p "$CONFIG_SOT_DIR"
  cp "$template" "$CONFIG_PATH"
  echo "[INFO] Seeded ${CONFIG_PATH} from the installed server's own template."
}

# Same, for a game whose depot ships no config at all. Falls back to the seed
# bundle vendored in the image (seed-configs/<game>/), which is how the CoD
# families get theirs.
steam_seed_config_from_image() {
  local src="/home/plutainer/.plutainer/seed-configs/${GAME_NAME}/${CONFIG_FILE}"

  [[ "${PLUTAINER_SKIP_SEED:-false}" == "true" ]] && return 0
  [[ -e "$CONFIG_PATH" ]] && return 0
  [[ -f "$src" ]] || return 0

  mkdir -p "$CONFIG_SOT_DIR"
  cp "$src" "$CONFIG_PATH"
  echo "[INFO] Seeded ${CONFIG_PATH} from the bundled ${GAME_NAME} config."
}

# Set a `cvar "value"` line in a Source-style cfg, rewriting an existing line or
# appending one. Same contract as the CoD families' apply_rcon_password: opt-in,
# never destructive, and python rather than sed because the value is arbitrary
# user input that would otherwise need escaping against replacement metachars.
# Args: <path> <cvar> <value>
steam_cfg_set_cvar() {
  [[ -n "${3:-}" ]] || return 0
  CFG_PATH="$1" CFG_NAME="$2" CFG_VALUE="$3" python3 - <<'PY'
import os
import re

path = os.environ["CFG_PATH"]
name = os.environ["CFG_NAME"]
value = os.environ["CFG_VALUE"].replace('"', '')

with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
    lines = fh.read().split("\n")

original = list(lines)
pattern = re.compile(r"^(\s*)" + re.escape(name) + r"\s+(\S.*)$", re.IGNORECASE)
replacement = '%s "%s"' % (name, value)
matched = False

for i, line in enumerate(lines):
    if line.lstrip().startswith("//"):
        continue
    m = pattern.match(line)
    if not m:
        continue
    matched = True
    lines[i] = m.group(1) + replacement

if not matched:
    if lines and lines[-1] == "":
        lines.pop()
    lines.extend(["", "// Added by Plutainer.", replacement, ""])

# Only touch the file when something actually changes. This runs on every start,
# and rewriting an identical file would move its mtime for no reason.
if lines != original:
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write("\n".join(lines))
    print("[INFO] Set %s in %s." % (name, os.path.basename(path)))
PY
}

# Refuse to start with the same shape of message the CoD families give: say what
# was looked for, then list what is actually there.
steam_ensure_config_present() {
  [[ -f "$CONFIG_PATH" ]] && return 0

  echo "[ERROR] PLUTAINER_CONFIG_FILE='${CONFIG_FILE}' but no such file exists." >&2
  echo "  Looked at:" >&2
  echo "    $CONFIG_PATH" >&2
  local match
  match=$(find "$CONFIG_SOT_DIR" -maxdepth 1 -type f -iname "$CONFIG_FILE" 2>/dev/null | head -1)
  if [[ -n "$match" ]]; then
    echo "  Did you mean: $(basename "$match") ? (filenames are case-sensitive on Linux)" >&2
  else
    echo "  Available configs in $CONFIG_SOT_DIR/:" >&2
    if compgen -G "$CONFIG_SOT_DIR/*" > /dev/null; then
      (cd "$CONFIG_SOT_DIR" && ls -1) | sed 's/^/    /' >&2
    else
      echo "    (none)" >&2
    fi
  fi
  return 1
}

# Set <property name="X" value="Y"/> in an XML config, in place.
#
# Deliberately a regex rewrite rather than parse-and-reserialise: the stock 7DTD
# template is ~200 lines of hand-formatted XML documenting every setting inline,
# and reserialising would throw all of that away on first start.
# Args: <path> <property-name> <value>
steam_xml_set_property() {
  XML_PATH="$1" XML_NAME="$2" XML_VALUE="$3" python3 - <<'PY'
import os
import re
import sys
from xml.sax.saxutils import escape

path = os.environ["XML_PATH"]
name = os.environ["XML_NAME"]
value = os.environ["XML_VALUE"]

with open(path, "r", encoding="utf-8") as fh:
    text = fh.read()

Q = r'''["']'''
NQ = r'''[^"']'''
pattern = re.compile(
    r"(<property\s+name=" + Q + re.escape(name) + Q + r"\s+value=" + Q + r")" + NQ + r"*(" + Q + r")",
    re.IGNORECASE,
)
if not pattern.search(text):
    print("[ERROR] No '%s' property in %s." % (name, os.path.basename(path)), file=sys.stderr)
    sys.exit(1)

updated = pattern.sub(
    lambda m: m.group(1) + escape(value, {'"': "&quot;", "'": "&apos;"}) + m.group(2),
    text,
    count=1,
)
if updated != text:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(updated)
    print("[INFO] Set %s=%s in %s." % (name, value, os.path.basename(path)))
PY
}

# Read a property back out of an XML config. Prints the value, or nothing.
# Args: <path> <property-name>
steam_xml_get_property() {
  [[ -f "$1" ]] || return 0
  XML_PATH="$1" XML_NAME="$2" python3 - <<'PY'
import os
import re

with open(os.environ["XML_PATH"], "r", encoding="utf-8") as fh:
    text = fh.read()

Q = r'''["']'''
NQ = r'''[^"']'''
m = re.search(
    r"<property\s+name=" + Q + re.escape(os.environ["XML_NAME"]) + Q + r"\s+value=" + Q +
    r"(" + NQ + r"*)" + Q,
    text,
    re.IGNORECASE,
)
print(m.group(1) if m else "")
PY
}

# ---------------------------------------------------------------------------
# Per-game hooks
#
# Resolved most-specific-first by games/steamentry.sh via plutainer_hook:
#     steam_<hook>_<game>  ->  steam_<hook>_<engine>
#
# So games sharing an engine share their implementations, and a game overrides
# only what genuinely differs — CS2 uses the srcds config handling but supplies
# its own launch arguments.
#
# Hooks, in the order steamentry.sh calls them:
#   seed          place the first-run config in app/configs/
#   configure     apply PLUTAINER_SERVER_NAME / PORT / RCON_PASSWORD
#   stage         put things where the server insists on finding them
#   launch_args   populate STEAM_LAUNCH_ARGS
#
# ACTIVE_PORT is resolved before any hook runs.
# ---------------------------------------------------------------------------

# --- 7 Days to Die ---------------------------------------------------------

steam_seed_unity() {
  steam_seed_config "serverconfig.xml"
}

# 7DTD reads its port and server name from the XML rather than the command line,
# so Plutainer's generic env vars have to be written into the file.
steam_configure_7dtd() {
  if [[ -n "${CUSTOM_PORT:-}" ]]; then
    steam_xml_set_property "$CONFIG_PATH" ServerPort "$ACTIVE_PORT" || \
      hold_indefinitely "Could not set ServerPort in ${CONFIG_FILE}."
  fi
  if [[ -n "${PLUTAINER_SERVER_NAME:-}" ]]; then
    steam_xml_set_property "$CONFIG_PATH" ServerName "$PLUTAINER_SERVER_NAME" || \
      hold_indefinitely "Could not set ServerName in ${CONFIG_FILE}."
  fi
  # 7DTD's telnet console is what rcon-cli talks to, so a password set through
  # the generic env var goes there.
  if [[ -n "${PLUTAINER_RCON_PASSWORD:-}" ]]; then
    steam_xml_set_property "$CONFIG_PATH" TelnetEnabled "true" || true
    steam_xml_set_property "$CONFIG_PATH" TelnetPassword "$PLUTAINER_RCON_PASSWORD" || true
  fi
}

steam_launch_args_7dtd() {
  STEAM_LAUNCH_ARGS=(
    -logfile "$STEAM_LOG_FILE"
    -quit -batchmode -nographics -dedicated
    "-configfile=$CONFIG_PATH"
    "-UserDataFolder=$STEAM_DATA_DIR"
  )
}

# --- Source dedicated servers (srcds) --------------------------------------
#
# Written against Half-Life 2: Deathmatch, but nothing below is specific to it
# beyond STEAM_GAME_DIR and the starting map: the same three hooks serve any
# srcds game. Adding one means a table row, not more code.
#
# Left 4 Dead 2 needs a two-phase install; see its table row and
# steam_install_or_update. Everything below is shared by every srcds game.

steam_seed_srcds() {
  steam_seed_config_from_image
}

steam_configure_srcds() {
  # Source takes its port on the command line, so only the cvars are written.
  steam_cfg_set_cvar "$CONFIG_PATH" hostname "${PLUTAINER_SERVER_NAME:-}"
  steam_cfg_set_cvar "$CONFIG_PATH" rcon_password "${PLUTAINER_RCON_PASSWORD:-}"
}

# srcds loads the Steam client library from a fixed path under $HOME rather than
# from its own install, and SteamCMD does not put it there. Without these links
# the server starts, binds its ports, and then never finishes initialising:
#
#     dlopen failed trying to load: ~/.steam/sdk32/steamclient.so
#     [S_API FAIL] Tried to access Steam interface SteamUtils010 before
#     SteamAPI_Init succeeded.
#
# It answers nothing on its game port in that state, so the health check reports
# it unhealthy — correctly. $HOME is in the image, not the volume, so this is
# redone on every start; it is idempotent.
steam_link_steamclient() {
  local steam_root home_dir bits
  steam_root="$(dirname "$STEAM_CMD")"
  home_dir="${HOME:-/home/plutainer}"

  for bits in 32 64; do
    local src="$steam_root/linux${bits}/steamclient.so"
    [[ -f "$src" ]] || continue
    mkdir -p "$home_dir/.steam/sdk${bits}"
    ln -sfn "$src" "$home_dir/.steam/sdk${bits}/steamclient.so"
  done
}

# Source engines exec their cfg from inside the game directory, which SteamCMD
# owns and may replace on update. So unlike 7DTD, srcds games do need the
# symlink fan-out: app/configs/*.cfg stays the source of truth and the install
# gets links pointing back at it.
steam_stage_srcds() {
  steam_link_steamclient
  steam_reclaim_depot_configs "$STEAM_INSTALL_DIR/$STEAM_GAME_DIR/cfg"
  link_configs "$STEAM_INSTALL_DIR/$STEAM_GAME_DIR/cfg"
  steam_redirect_srcds_logs
}

# Move a depot-shipped config out of the way so link_configs can put ours there.
#
# link_configs deliberately refuses to replace a *real* file at the engine path,
# because for the Call of Duty families that file is the strongest signal of
# user intent — they wrote it where the game reads from. Inside a SteamCMD
# install the same signal means the opposite: the directory belongs to Steam, so
# a real file is whatever the depot shipped and will be restored by the next
# update regardless.
#
# CS2 is the case that exposed this. Its depot ships a 33-byte
# `game/csgo/cfg/server.cfg` reading "// Defaults in server_default.cfg", so
# link_configs skipped it with a warning and the server ran on stock settings —
# hostname, bots and logging all ignored — while app/configs/server.cfg sat
# there looking correct.
#
# The displaced file is kept once as <name>.depot-original for reference.
# Args: <engine cfg dir>
steam_reclaim_depot_configs() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0

  local f base target
  for f in "$PLUTAINER_CONFIGS_DIR"/*.cfg; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    target="$dir/$base"

    # Only a real file blocks us; a symlink is already ours to replace.
    [[ -e "$target" && ! -L "$target" ]] || continue

    if [[ -e "$target.depot-original" ]]; then
      rm -f "$target"
    else
      mv -f "$target" "$target.depot-original"
      echo "[INFO] Moved the depot's own ${base} aside as ${base}.depot-original; yours from app/configs/ takes its place."
    fi
  done
}

# `log on` makes srcds write its event log to <install>/<game>/logs/, which is
# the wrong place twice over: SteamCMD owns that tree and may replace it, and
# the log watcher skips the whole install (it is tens of thousands of files, and
# walking it every couple of seconds for one log is not worth it).
#
# Point it at the persistent data directory instead, where the watcher will find
# it and surface it in app/logs/ like every other game's. Existing logs are
# moved rather than dropped.
steam_redirect_srcds_logs() {
  local live="$STEAM_INSTALL_DIR/$STEAM_GAME_DIR/logs"
  local persistent="$STEAM_DATA_DIR/logs"

  mkdir -p "$persistent"

  if [[ -L "$live" ]]; then
    ln -sfn "$persistent" "$live"
    return 0
  fi

  if [[ -d "$live" ]]; then
    find "$live" -maxdepth 1 -type f -exec mv -n -t "$persistent" {} + 2>/dev/null || true
    rmdir "$live" 2>/dev/null || {
      echo "[WARN] ${live} is not empty and could not be replaced; srcds logs will stay inside the install." >&2
      return 0
    }
  fi

  ln -sfn "$persistent" "$live"
}

steam_launch_args_srcds() {
  STEAM_LAUNCH_ARGS=(
    -game "$STEAM_GAME_DIR"
    -console
    # srcds_run is a shell wrapper that relaunches the server on exit. That
    # fights launch_game's crash throttle and hides exit codes from Docker.
    -norestart
    -port "$ACTIVE_PORT"
    +servercfgfile "$CONFIG_FILE"
    +maxplayers "${PLUTAINER_MAX_CLIENTS:-16}"
    +map "${PLUTAINER_START_MAP:-$STEAM_DEFAULT_MAP}"
  )
}

# --- Counter-Strike 2 ------------------------------------------------------
#
# Source 2. STEAM_ENGINE=srcds, so it inherits the seed, configure, stage and
# admin hooks above unchanged; only the launch arguments differ, because there
# is no srcds_run wrapper and RCON has to be switched on explicitly.

steam_launch_args_cs2() {
  STEAM_LAUNCH_ARGS=(
    -dedicated
    -console
    # Without -usercon the server refuses every RCON connection regardless of
    # rcon_password, so rcon-cli would fail for no visible reason.
    -usercon
    -port "$ACTIVE_PORT"
    -maxplayers "${PLUTAINER_MAX_CLIENTS:-10}"
    +game_alias "${PLUTAINER_CS2_GAME_ALIAS:-competitive}"
    +map "${PLUTAINER_START_MAP:-$STEAM_DEFAULT_MAP}"
    # Passed on the command line as well as written into server.cfg: RCON is
    # initialised before the config is exec'd.
    +rcon_password "${PLUTAINER_RCON_PASSWORD:-}"
    +sv_lan "${PLUTAINER_CS2_LAN:-0}"
  )

  # A Game Server Login Token is what puts the server on the public master, the
  # same role CoD4x's masterserver token plays. Without one CS2 runs and is
  # joinable directly but never appears in the browser — and passing an empty
  # +sv_setsteamaccount is worse than omitting it.
  if [[ -n "${PLUTAINER_CS2_GSLT:-}" ]]; then
    STEAM_LAUNCH_ARGS+=( +sv_setsteamaccount "$PLUTAINER_CS2_GSLT" )
  else
    echo "[INFO] No PLUTAINER_CS2_GSLT set — the server runs but stays off the public server list."
  fi
}

# Read a `cvar "value"` out of a Source-style cfg. Prints the value, or nothing.
# Args: <path> <cvar>
steam_cfg_get_cvar() {
  [[ -f "$1" ]] || return 0
  sed -e 's|//.*$||' "$1" \
    | grep -iE "^[[:space:]]*$2[[:space:]]+" \
    | tail -1 \
    | sed -E "s|^[[:space:]]*$2[[:space:]]+||; s|^\"(.*)\"[[:space:]]*$|\1|; s|^'(.*)'[[:space:]]*$|\1|" \
    | sed -E 's|[[:space:]]+$||'
}

# Resolve rcon-cli's endpoint. The protocol comes from the family table; where
# the port and credential live is per game, so it goes through a hook.
steam_resolve_admin_endpoint() {
  steam_resolve_config_path || return 1

  resolve_active_port || return 1

  ADMIN_PROTOCOL="$STEAM_ADMIN"
  ADMIN_PORT="$ACTIVE_PORT"
  ADMIN_PASSWORD=""
  plutainer_hook steam admin "$GAME_NAME" "$STEAM_ENGINE"
}

steam_admin_7dtd() {
  # 7DTD's console is a separate telnet listener, not the game port.
  local enabled port password
  enabled=$(steam_xml_get_property "$CONFIG_PATH" TelnetEnabled)
  port=$(steam_xml_get_property "$CONFIG_PATH" TelnetPort)
  password=$(steam_xml_get_property "$CONFIG_PATH" TelnetPassword)

  if [[ "${enabled,,}" != "true" ]]; then
    ADMIN_PROTOCOL="disabled"
    ADMIN_DISABLED_HINT="Set TelnetEnabled to true in ${CONFIG_FILE} (and give TelnetPassword a value), then restart."
    return 0
  fi

  ADMIN_PORT="${port:-8081}"
  ADMIN_PASSWORD="$password"
}

# Source RCON shares the game port, over TCP.
steam_admin_srcds() {
  ADMIN_PASSWORD=$(steam_cfg_get_cvar "$CONFIG_PATH" rcon_password)
}

