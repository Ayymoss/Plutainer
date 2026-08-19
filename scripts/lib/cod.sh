#!/bin/bash
#
# The `cod` family: Quake-derived servers Plutainer installs and runs itself —
# Plutonium (T4/T5/T6/IW5), IW4x, Ezz BOIII and CoD4x.
#
# One entry script (games/codentry.sh) serves all ten games; what differs
# between them lives in the table below and in the hook functions beneath it.
# Adding a game should mean a table row and a couple of hooks, not a new entry
# script.
#
# What the family has in common:
#   - the user supplies the game files, mounted read-only at
#     /home/plutainer/gamefiles, and Plutainer mirrors them into the volume
#   - plain-text *.cfg files the engine `+exec`s from a fixed directory, with
#     app/configs/ as the source of truth and symlinks fanned out to the engine
#   - an `rcon_password` cvar, and the Quake3 connectionless query protocol
#   - Wine, with CoD4x the sole exception (native 32-bit Linux binary)
#
# None of that applies to the steam family, which is why the two live in
# separate files.
#

# Decide the config source-of-truth. Default: configs/ (symlink fan-out to
# engine dir). With PLUTAINER_USE_RAW_CONFIGS=true: engine dir IS the SOT
# (no symlinks, cfgs live where the game reads them).
# Requires ENGINE_CONFIG_DIR, which cod_resolve_game sets from the table.
# Sets CONFIG_SOT_DIR, ALT_CONFIG_DIR, CONFIG_PATH.
resolve_config_layout() {
  if [[ "${PLUTAINER_USE_RAW_CONFIGS:-}" == "true" ]]; then
    CONFIG_SOT_DIR="$ENGINE_CONFIG_DIR"
    ALT_CONFIG_DIR="$PLUTAINER_CONFIGS_DIR"
  else
    CONFIG_SOT_DIR="$PLUTAINER_CONFIGS_DIR"
    ALT_CONFIG_DIR="$ENGINE_CONFIG_DIR"
  fi
  CONFIG_PATH="$CONFIG_SOT_DIR/$CONFIG_FILE"
}

# Convenience for callers (healthcheck.sh, rcon-cli) that only need
# CONFIG_PATH set. Runs the chain end-to-end. Reached through the family
# dispatcher resolve_config_path() in lib/core.sh.
cod_resolve_config_path() {
  cod_resolve_game || return 1
  resolve_config_layout
}

# Copy bundled community seed configs into the volume on first run.
# Strategy:
#   - Top-level *.cfg files inside the seed's "config root" subdir
#     (cfg_root_rel within the seed bundle) land in CONFIG_SOT_DIR.
#   - Everything else (assets, mod scripts, nested cfgs, etc) lands under
#     asset_root, preserving the seed's relative path.
# Always idempotent: never overwrites a file that already exists.
#
# Args: <game-key> <asset_root> <cfg_root_rel>
seed_configs() {
  local game="$1" asset_root="$2" cfg_root_rel="${3:-}"
  local src="/home/plutainer/.plutainer/seed-configs/${game}"
  [[ -d "$src" ]] || return 0
  mkdir -p "$asset_root" "$CONFIG_SOT_DIR"

  local rel parent dest
  while IFS= read -r -d '' relpath; do
    rel="${relpath#./}"
    # Provenance metadata for the vendored seed (upstream repo + commit). It
    # belongs to the image, not the user's volume.
    [[ "$rel" == "SOURCE" ]] && continue
    parent="$(dirname "$rel")"
    [[ "$parent" == "." ]] && parent=""
    if [[ "$rel" == *.cfg && "$parent" == "$cfg_root_rel" ]]; then
      dest="$CONFIG_SOT_DIR/$(basename "$rel")"
    else
      dest="$asset_root/$rel"
    fi
    mkdir -p "$(dirname "$dest")"
    [[ -e "$dest" ]] || cp "$src/$rel" "$dest"
  done < <(cd "$src" && find . -type f -print0)
}

# If the user has placed a REAL (non-symlink) cfg file at the engine path,
# treat that as authoritative and move it into the SOT location. Engine-path
# real file is the strongest signal of user intent: they manually wrote it
# where the game reads from. Overrides anything already in SOT.
# Runs BEFORE seed_configs so seed (cp -n) doesn't paper over user intent.
# Requires CONFIG_SOT_DIR, ALT_CONFIG_DIR, CONFIG_FILE set.
auto_lift_user_config() {
  local cfg="${CONFIG_FILE:-}"
  [[ -z "$cfg" ]] && return 0
  [[ "${PLUTAINER_USE_RAW_CONFIGS:-}" == "true" ]] && return 0

  local alt_path="$ALT_CONFIG_DIR/$cfg"
  local sot_path="$CONFIG_SOT_DIR/$cfg"

  if [[ -f "$alt_path" && ! -L "$alt_path" ]]; then
    echo "[INFO] Auto-lift: real file at $alt_path — moving to $sot_path (v2 SOT)."
    mkdir -p "$CONFIG_SOT_DIR"
    mv -f "$alt_path" "$sot_path"
  fi
}

# Verify $CONFIG_FILE exists at the SOT location. Returns 1 with a
# case-insensitive find hint if absent. Run AFTER seed_configs + link_configs
# so any gap-fill has had its chance.
# Requires CONFIG_SOT_DIR, ALT_CONFIG_DIR, CONFIG_FILE set.
ensure_config_present() {
  local cfg="$CONFIG_FILE"
  local sot_path="$CONFIG_SOT_DIR/$cfg"

  if [[ -e "$sot_path" ]]; then
    return 0
  fi

  echo "[ERROR] PLUTAINER_CONFIG_FILE='$cfg' but no such file exists." >&2
  echo "  Looked at:" >&2
  echo "    $sot_path" >&2
  echo "    $ALT_CONFIG_DIR/$cfg" >&2
  local match
  match=$(find "$CONFIG_SOT_DIR" "$ALT_CONFIG_DIR" -maxdepth 1 -type f -iname "$cfg" 2>/dev/null | head -1)
  if [[ -n "$match" ]]; then
    echo "  Did you mean: $(basename "$match") ? (filenames are case-sensitive on Linux)" >&2
  else
    echo "  Available cfgs in $CONFIG_SOT_DIR/:" >&2
    if compgen -G "$CONFIG_SOT_DIR/*.cfg" > /dev/null; then
      (cd "$CONFIG_SOT_DIR" && ls -1 *.cfg) | sed 's/^/    /' >&2
    else
      echo "    (none)" >&2
    fi
  fi
  return 1
}

_rcon_missing_warning() {
  echo "[WARN] Could not parse rcon_password from ${CONFIG_PATH}." >&2
  echo "  Healthcheck and rcon-cli will not work until this is set." >&2
  echo "  Expected format in your cfg file:" >&2
  echo "    set rcon_password \"your_password_here\"" >&2
  echo "  Single quotes and unquoted values are accepted; commented (//) lines are ignored." >&2
  echo "  Do NOT set rcon_password via PLUTAINER_EXTRA_ARGS — Plutainer cannot read it back." >&2
}

# Extract the RCON password from the user's config file. Handles:
#   set  rcon_password "value"      (double-quoted, default)
#   seta rcon_password 'value'      (single-quoted)
#   set  rcon_password value        (unquoted; value is first token)
#   rcon_password "value"           (bare; T6/T7 community cfgs do this)
# Strips line comments (//...) before searching. Picks the last uncommented
# match, in case the cfg overrides itself.
# Sets RCON_PASSWORD on success; returns 1 + warning on failure.
extract_rcon_password() {
  RCON_PASSWORD=""
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    echo "[WARN] Config file not found at ${CONFIG_PATH} — cannot extract rcon_password." >&2
    return 1
  fi

  local line
  line=$(sed -e 's|//.*$||' "${CONFIG_PATH}" \
    | grep -iE '^[[:space:]]*(set[a]?[[:space:]]+)?rcon_password[[:space:]]+' \
    | tail -1)

  if [[ -z "$line" ]]; then
    _rcon_missing_warning
    return 1
  fi

  local dq_pat='"([^"]*)"'
  local sq_pat="'([^']*)'"
  if [[ "$line" =~ $dq_pat ]]; then
    RCON_PASSWORD="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ $sq_pat ]]; then
    RCON_PASSWORD="${BASH_REMATCH[1]}"
  else
    # Unquoted: value is the token immediately after 'rcon_password'.
    # Strip optional 'set'/'seta' prefix so $2 is always the value.
    RCON_PASSWORD=$(echo "$line" | awk '{ if ($1 ~ /^[Ss][Ee][Tt][Aa]?$/) print $3; else print $2 }')
  fi

  if [[ -z "$RCON_PASSWORD" ]]; then
    _rcon_missing_warning
    return 1
  fi
}

# Build the `+rconWhitelistAdd` launch args that let an admin tool in another
# container reach RCON, and populate RCON_WHITELIST_ARGS with them.
#
# T5 and T6 gate *unauthenticated* queries — `getinfo` and `getstatus` — on the
# RCON whitelist, not just RCON commands, and an empty whitelist does NOT mean
# "everyone" for those (it does for RCON commands). Since IW4MAdmin's T5/T6
# parsers open with `getinfo`, a sidecar admin container can complete the RCON
# handshake and still fail to attach. Measured on T6 zombies, off-loopback:
#
#   whitelist state          RCON      getinfo
#   upstream placeholders    blocked   blocked
#   empty                    works     blocked
#   gateway whitelisted      works     works
#
# Traffic from a container on another Docker network arrives from this
# container's own bridge gateway, whose address is assigned at run time and so
# cannot be baked into a config file — hence detecting it here. Passed as a
# launch arg rather than written into the user's cfg, so nothing is mutated and
# the value tracks the network on every start.
#
# T4 and IW5 do not gate queries this way and are left alone: adding an entry
# makes their whitelist non-empty, which would newly restrict RCON to the
# listed addresses for no benefit. iw4x and boiii have no such command at all.
#
# Adding entries does mean T5/T6 RCON becomes "whitelisted + loopback only",
# which is the same posture upstream's placeholder entries intended (and what
# a working IW4MAdmin deployment ends up doing by hand). An admin tool on
# another machine needs its address in PLUTAINER_RCON_WHITELIST.
resolve_rcon_whitelist_args() {
  RCON_WHITELIST_ARGS=()

  case "${BASE_GAME:-}" in
    t5|t6) ;;
    *) return 0 ;;
  esac

  local -a addresses=()

  if [[ "${PLUTAINER_RCON_WHITELIST_GATEWAY:-true}" != "false" ]]; then
    local gateway
    gateway=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
    if [[ -n "$gateway" ]]; then
      addresses+=("$gateway")
    else
      echo "[WARN] Could not determine the container's default gateway; RCON from a sidecar admin tool may be refused." >&2
    fi
  fi

  # Extra hosts (an admin tool on another machine, say). Comma or space separated.
  if [[ -n "${PLUTAINER_RCON_WHITELIST:-}" ]]; then
    local entry
    for entry in ${PLUTAINER_RCON_WHITELIST//,/ }; do
      [[ -n "$entry" ]] && addresses+=("$entry")
    done
  fi

  [[ ${#addresses[@]} -gt 0 ]] || return 0

  local address
  for address in "${addresses[@]}"; do
    RCON_WHITELIST_ARGS+=(+rconWhitelistAdd "$address")
  done

  echo "[INFO] RCON whitelist: ${addresses[*]} (loopback is always permitted)."
}

# Write PLUTAINER_RCON_PASSWORD into the source-of-truth config file.
#
# Opt-in only. Unset (or set to the empty string, which is what an unfilled
# compose variable looks like) means "leave the config alone" — it never nulls
# out a password the user already put there by hand. There is deliberately no
# default value: a shipped placeholder would be a known credential on a UDP
# port that anyone can find by scanning for `getstatus` responders.
#
# Rewrites the value in place, keeping the rest of the line (upstream seeds put
# an explanatory // comment after it), or appends a line if the config has none.
apply_rcon_password() {
  local desired="${PLUTAINER_RCON_PASSWORD:-}"
  [[ -n "$desired" ]] || return 0

  local target="${CONFIG_SOT_DIR}/${CONFIG_FILE}"
  if [[ ! -f "$target" ]]; then
    echo "[WARN] PLUTAINER_RCON_PASSWORD is set but ${target} does not exist — skipping." >&2
    return 0
  fi

  # Python rather than sed: the password is arbitrary user input and would need
  # escaping against sed's replacement metacharacters (& \ and the delimiter).
  local result
  result=$(RCON_TARGET="$target" RCON_DESIRED="$desired" python3 - <<'PY'
import os
import re
import sys

path = os.environ['RCON_TARGET']
desired = os.environ['RCON_DESIRED']

with open(path, 'r', encoding='utf-8', errors='surrogateescape') as fh:
    lines = fh.read().split('\n')

# Same forms extract_rcon_password() reads back, so a value written here is
# always one it can find again.
pattern = re.compile(
    r'^(?P<lead>\s*(?:set[a]?\s+)?rcon_password\s+)'
    r'(?P<value>"[^"]*"|\'[^\']*\'|\S+)'
    r'(?P<rest>.*)$',
    re.IGNORECASE,
)

replacement = '"%s"' % desired.replace('"', '')
changed = False
matched = False

for i, line in enumerate(lines):
    # Ignore fully commented lines; a commented-out password is not in effect.
    if line.lstrip().startswith('//'):
        continue
    m = pattern.match(line)
    if not m:
        continue
    matched = True
    if m.group('value') == replacement:
        continue
    lines[i] = m.group('lead') + replacement + m.group('rest')
    changed = True

if not matched:
    if lines and lines[-1] == '':
        lines.pop()
    lines.extend([
        '',
        '// Added by Plutainer from PLUTAINER_RCON_PASSWORD.',
        'set rcon_password %s' % replacement,
        '',
    ])
    changed = True

if changed:
    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as fh:
        fh.write('\n'.join(lines))

print('changed' if changed else 'unchanged')
PY
  ) || {
    echo "[WARN] Could not apply PLUTAINER_RCON_PASSWORD to ${target}." >&2
    return 0
  }

  if [[ "$result" == "changed" ]]; then
    echo "[INFO] rcon_password set from PLUTAINER_RCON_PASSWORD (${#desired} chars) in ${CONFIG_FILE}."
  else
    echo "[INFO] rcon_password in ${CONFIG_FILE} already matches PLUTAINER_RCON_PASSWORD."
  fi

  if [[ "$desired" == *'"'* ]]; then
    echo "[WARN] PLUTAINER_RCON_PASSWORD contained double quotes; they were stripped before writing." >&2
  fi
}


# Every Quake-derived engine here answers RCON on its own game port, over the
# same connectionless UDP protocol used for status queries.
cod_resolve_admin_endpoint() {
  ADMIN_PROTOCOL="quake3"

  if [[ -n "${CUSTOM_PORT:-}" ]]; then
    ADMIN_PORT="$CUSTOM_PORT"
  else
    resolve_default_port || return 1
    ADMIN_PORT="$DEFAULT_PORT"
  fi

  cod_resolve_config_path || return 1
  # A missing or unreadable password is not fatal here: rcon-cli reports it in
  # terms the user can act on, and extract_rcon_password has already explained
  # the accepted forms.
  extract_rcon_password || true
  ADMIN_PASSWORD="${RCON_PASSWORD:-}"
}

# ---------------------------------------------------------------------------
# Game table
# ---------------------------------------------------------------------------
#
# Fields set by cod_resolve_game:
#
#   COD_ENGINE            plutonium | iw4x | ezz | cod4x
#   BASE_GAME             t4 | t5 | t6 | iw5 | iw4x | boiii | cod4x
#   COD_DEFAULT_PORT      port when PLUTAINER_PORT is unset
#   COD_SEED_KEY          seed-configs/<key>, empty for no seed bundle
#   COD_SEED_ASSET_ROOT   where non-cfg seed files land
#   COD_SEED_CFG_ROOT     subdir within the bundle whose top-level *.cfg lift
#   COD_LABEL             name used in log lines
#
# ENGINE_CONFIG_DIR and MOD_CONFIG_DIR are set here too, since they are per-game
# facts rather than logic.
#
# Games this family serves. derive_family() consults this, so adding a game is
# a change to this file and nothing else.
COD_GAMES=(t4mp t4sp t5mp t5sp t6mp t6zm iw5mp iw4x boiii cod4x)

cod_is_known_game() {
  local candidate="$1" game
  for game in "${COD_GAMES[@]}"; do
    [[ "$game" == "$candidate" ]] && return 0
  done
  return 1
}

cod_resolve_game() {
  local game="${1:-$GAME_NAME}"

  COD_SEED_KEY=""
  COD_SEED_ASSET_ROOT=""
  COD_SEED_CFG_ROOT=""

  case "$game" in
    t4mp|t4sp)
      COD_ENGINE="plutonium"; BASE_GAME="t4";  COD_DEFAULT_PORT=28960
      COD_LABEL="Plutonium T4 (World at War)"
      COD_SEED_KEY="t4";  COD_SEED_ASSET_ROOT="$PLUTAINER_GAMEFILES_DIR/main"
      ENGINE_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/main"
      ;;
    t5mp|t5sp)
      COD_ENGINE="plutonium"; BASE_GAME="t5";  COD_DEFAULT_PORT=28960
      COD_LABEL="Plutonium T5 (Black Ops)"
      COD_SEED_KEY="t5";  COD_SEED_ASSET_ROOT="$PLUTAINER_PLUTONIUM_DIR/storage/t5"
      ENGINE_CONFIG_DIR="$PLUTAINER_PLUTONIUM_DIR/storage/t5"
      ;;
    t6mp|t6zm)
      COD_ENGINE="plutonium"; BASE_GAME="t6";  COD_DEFAULT_PORT=4976
      COD_LABEL="Plutonium T6 (Black Ops II)"
      COD_SEED_KEY="t6";  COD_SEED_ASSET_ROOT="$PLUTAINER_PLUTONIUM_DIR/storage/t6"
      ENGINE_CONFIG_DIR="$PLUTAINER_PLUTONIUM_DIR/storage/t6"
      ;;
    iw5mp)
      COD_ENGINE="plutonium"; BASE_GAME="iw5"; COD_DEFAULT_PORT=27016
      COD_LABEL="Plutonium IW5 (Modern Warfare 3)"
      COD_SEED_KEY="iw5"; COD_SEED_ASSET_ROOT="$PLUTAINER_GAMEFILES_DIR/admin"
      ENGINE_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/admin"
      ;;
    iw4x)
      COD_ENGINE="iw4x";      BASE_GAME="iw4x"; COD_DEFAULT_PORT=28960
      COD_LABEL="IW4x (Modern Warfare 2)"
      COD_SEED_KEY="iw4x"; COD_SEED_ASSET_ROOT="$PLUTAINER_GAMEFILES_DIR"
      COD_SEED_CFG_ROOT="userraw"
      ENGINE_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/userraw"
      ;;
    boiii)
      COD_ENGINE="ezz";       BASE_GAME="boiii"; COD_DEFAULT_PORT=27017
      COD_LABEL="Ezz BOIII (Black Ops III)"
      COD_SEED_KEY="boiii"; COD_SEED_ASSET_ROOT="$PLUTAINER_GAMEFILES_DIR"
      COD_SEED_CFG_ROOT="zone"
      ENGINE_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/zone"
      ;;
    cod4x)
      COD_ENGINE="cod4x";     BASE_GAME="cod4x"; COD_DEFAULT_PORT=28960
      COD_LABEL="CoD4x (Modern Warfare)"
      COD_SEED_KEY="cod4x"; COD_SEED_ASSET_ROOT="$PLUTAINER_GAMEFILES_DIR"
      COD_SEED_CFG_ROOT="main"
      ENGINE_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/main"
      ;;
    *)
      echo "[ERROR] '${game}' is not a known Call of Duty game." >&2
      return 1
      ;;
  esac

  cod_resolve_mod_config_dir
}

# Where the game looks for cfg files inside the active mod (fs_game), if
# PLUTAINER_MOD is set. Empty when no mod, or when the family has no such
# concept — on Black Ops III the MOD is a Steam Workshop ID, not a path.
cod_resolve_mod_config_dir() {
  MOD_CONFIG_DIR=""
  [[ -z "${PLUTAINER_MOD:-}" ]] && return 0
  case "$COD_ENGINE" in
    plutonium)
      case "$BASE_GAME" in
        t4|iw5) MOD_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/$PLUTAINER_MOD" ;;
        *)      MOD_CONFIG_DIR="$PLUTAINER_PLUTONIUM_DIR/storage/$BASE_GAME/$PLUTAINER_MOD" ;;
      esac
      ;;
    iw4x)  MOD_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/$PLUTAINER_MOD" ;;
    cod4x) MOD_CONFIG_DIR="$PLUTAINER_GAMEFILES_DIR/$PLUTAINER_MOD" ;;
  esac
}

# ---------------------------------------------------------------------------
# Hooks
#
# Resolved most-specific-first by games/codentry.sh:
#     cod_<hook>_<game>  ->  cod_<hook>_<base game>  ->  cod_<hook>_<engine>
#
#   stage    put the game files where the engine expects them
#   update   fetch/refresh the server binaries
#   launch   populate COD_LAUNCH_CMD with the command and its arguments
#   validate optional; extra per-engine environment checks
# ---------------------------------------------------------------------------

# --- Plutonium -------------------------------------------------------------

# Which files each base game needs out of the read-only mount. Everything else
# in the mount is client-side and ignored.
cod_stage_t4() {
  link_files "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" \
    zone binkw32.dll localization.txt cod.bmp codlogo.bmp
  # main/ must stay a real writable dir: cfg symlinks and game logs land there.
  mkdir -p "$PLUTAINER_GAMEFILES_DIR/main"
  link_files "$PLUTAINER_SOURCE_DIR/main" "$PLUTAINER_GAMEFILES_DIR/main" \
    iw_00.iwd iw_14.iwd iw_21.iwd iw_22.iwd iw_24.iwd iw_26.iwd \
    localized_english_iw00.iwd localized_english_iw04.iwd
}

cod_stage_t5() {
  link_files "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" \
    main zone binkw32.dll localization.txt
}

cod_stage_t6() {
  link_files "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" \
    zone binkw32.dll codlogo.bmp
}

cod_stage_iw5() {
  link_files "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" \
    main miles zone binkw32.dll localization.txt mss32.dll
}

cod_update_plutonium() {
  mkdir -p "$PLUTAINER_PLUTONIUM_DIR"
  local marker="$PLUTAINER_PLUTONIUM_DIR/cdn_info.json"

  if [[ -f "$marker" && "${PLUTAINER_AUTO_UPDATE:-}" == "false" ]]; then
    echo "Skipping Plutonium update because PLUTAINER_AUTO_UPDATE is set to 'false'."
    return 0
  fi
  if [[ -f "$marker" ]]; then
    echo "Checking for Plutonium updates..."
  else
    echo "First container run detected. Downloading Plutonium initial files..."
  fi
  /home/plutainer/.plutainer/plutonium-updater --directory "$PLUTAINER_PLUTONIUM_DIR"
}

cod_validate_plutonium() {
  [[ -n "${PLUTO_SERVER_KEY:-}" ]] || hold_indefinitely \
    "PLUTO_SERVER_KEY is not set. Get a server key from https://platform.plutonium.pw/serverkeys"
}

cod_launch_plutonium() {
  COD_WORKDIR="$PLUTAINER_PLUTONIUM_DIR"
  COD_LAUNCH_CMD=(
    wine bin/plutonium-bootstrapper-win32.exe
    "$GAME_NAME"
    "$PLUTAINER_GAMEFILES_DIR"
    -dedicated
    +set key "${PLUTO_SERVER_KEY}"
    +set net_port "$ACTIVE_PORT"
  )

  # IW5 spells both of these differently to the rest of the family.
  if [[ "$BASE_GAME" == "iw5" ]]; then
    COD_LAUNCH_CMD+=(+set sv_config "$CONFIG_FILE")
  else
    COD_LAUNCH_CMD+=(+exec "$CONFIG_FILE")
  fi

  [[ -n "${PLUTAINER_MOD:-}" ]]    && COD_LAUNCH_CMD+=(+set fs_game "$PLUTAINER_MOD")
  [[ -n "${PLUTO_MAX_CLIENTS:-}" ]] && COD_LAUNCH_CMD+=(+set sv_maxclients "$PLUTO_MAX_CLIENTS")

  # Must come after +exec: the cfg's own rconWhitelistAdd lines are additive,
  # and these entries are what let an admin tool in another container query
  # T5/T6 at all. No-op for the other base games.
  resolve_rcon_whitelist_args
  (( ${#RCON_WHITELIST_ARGS[@]} )) && COD_LAUNCH_CMD+=("${RCON_WHITELIST_ARGS[@]}")

  cod_append_extra_args
  cod_append_map_rotate "$([[ "$BASE_GAME" == "iw5" ]] && echo '+start_map_rotate' || echo '+map_rotate')"
}

# --- IW4x ------------------------------------------------------------------

cod_stage_iw4x() {
  link_files "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" \
    main usermaps binkw32.dll localization.txt mss32.dll

  # userraw/ is the engine config dir, so it must be a real writable directory
  # for the cfg fan-out to land in.
  link_dir_contents "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" userraw

  # zone/ is split by how the launcher writes, not by who owns the content.
  #
  # Its rawfiles component unpacks release.zip by writing straight through each
  # destination path, so a symlink there — at the directory OR the leaf —
  # resolves into the read-only mount and aborts the whole run:
  #   [E] failed to extract file: zone/patch/iw4_credits_load.ff
  # That also skips sync_dlc and sync_helper and leaves rawfiles unstamped, so
  # every later start fails identically and client updates never apply. The zip
  # covers all of zone/patch/ and zone/zonebuilder/, so neither may be
  # pre-populated. Nothing is lost: its 56 zone/patch entries are a superset of
  # a full MW2 install's 39, and zone/zonebuilder is the same lone file.
  #
  # Every other component stages downloads and renames into place, which
  # replaces a symlink rather than writing through it — so mirroring these two
  # is safe, and useful, since the reconciler hash-validates existing host
  # fastfiles and skips re-downloading matches.
  link_dir_contents "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" zone/english
  link_dir_contents "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" zone/dlc
}

cod_update_iw4x() {
  # The launcher has no --path flag: it canonicalises /proc/self/exe and uses
  # its own directory as the installation root, ignoring cwd. So run a copy from
  # inside the volume — that way the ~800 MB it fetches lands in the bind mount
  # and survives container recreation instead of filling an image layer. It must
  # be a real copy: a symlink canonicalises straight back to .plutainer and
  # reinstates the ephemeral install root.
  local src="/home/plutainer/.plutainer/iw4x-launcher"
  local launcher="$PLUTAINER_GAMEFILES_DIR/iw4x-launcher"

  # Capability check, deliberately not an architecture check, so this clears
  # itself the moment an image ships a working binary again.
  if [[ ! -x "$src" ]]; then
    hold_indefinitely "iw4x-launcher is missing from this image, so PLUTAINER_GAME=iw4x cannot start.
  This image was built for an architecture upstream does not publish a launcher
  binary for, and building it from source failed. Tracked as iw4x/launcher#76.
  Options: run iw4x on an amd64 host, or use a different PLUTAINER_GAME —
  Plutonium (t4/t5/t6/iw5) and Ezz BOIII are unaffected."
  fi

  if [[ ! -f "$launcher" || "$src" -nt "$launcher" ]]; then
    echo "Staging iw4x-launcher into the game directory..."
    cp -f "$src" "$launcher"
    chmod +x "$launcher"
  fi

  local marker="$PLUTAINER_GAMEFILES_DIR/cache/iw4x.db"
  if [[ -f "$marker" && "${PLUTAINER_AUTO_UPDATE:-}" == "false" ]]; then
    echo "Skipping iw4x update because PLUTAINER_AUTO_UPDATE is set to 'false'."
    return 0
  fi
  if [[ -f "$marker" ]]; then
    echo "Checking for iw4x updates..."
  else
    echo "First container run detected. Downloading iw4x initial files..."
  fi

  # Don't let a GitHub/CDN outage take a working server down: only a first-run
  # failure (no iw4x.exe yet) is fatal.
  if ! "$launcher" --skip-launch --no-self-update; then
    if [[ -f "$PLUTAINER_GAMEFILES_DIR/iw4x.exe" ]]; then
      echo "[WARN] iw4x-launcher failed — starting with the existing install." >&2
    else
      hold_indefinitely "iw4x-launcher failed and no iw4x.exe is present. Check network access to github.com and cdn.iw4x.io, and that the app volume is not mounted 'noexec' (the launcher runs from $PLUTAINER_GAMEFILES_DIR)."
    fi
  fi
}

cod_launch_iw4x() {
  COD_WORKDIR="$PLUTAINER_GAMEFILES_DIR"
  COD_LAUNCH_CMD=(
    wine iw4x.exe
    -dedicated
    -stdout
    +set sv_lanonly "0"
    +set net_port "$ACTIVE_PORT"
    +exec "$CONFIG_FILE"
    +set logfile "1"
    +set party_enable "0"
  )
  [[ -n "${PLUTAINER_MOD:-}" ]]    && COD_LAUNCH_CMD+=(+set fs_game "$PLUTAINER_MOD")
  [[ -n "${IW4X_NET_LOG_IP:-}" ]]  && COD_LAUNCH_CMD+=(+set g_log_add "$IW4X_NET_LOG_IP")
  cod_append_extra_args
  cod_append_map_rotate +map_rotate
}

# --- Ezz BOIII (Black Ops III) ----------------------------------------------

BOIII_BINARY_URL="https://r2.ezz.lol/boiii/boiii.exe"

cod_stage_boiii() {
  link_files "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" \
    codlogo.bmp machinecfg steam_api64.dll steamclient64.dll tier0_s64.dll vstdlib_s64.dll

  # BOIII decides it is a dedicated server by checking which executables exist:
  #   is_server = has_flag("dedicated") || (!has_client && has_server)
  # Under Wine, flag detection via GetCommandLineW() can be unreliable, so only
  # the server binary is linked, guaranteeing the fallback path fires.
  if [[ -f "$PLUTAINER_SOURCE_DIR/BlackOps3_UnrankedDedicatedServer.exe" ]]; then
    ln -sf "$PLUTAINER_SOURCE_DIR/BlackOps3_UnrankedDedicatedServer.exe" "$PLUTAINER_GAMEFILES_DIR"/
  elif [[ -f "$PLUTAINER_SOURCE_DIR/BlackOps3.exe" ]]; then
    echo "[WARN] BlackOps3_UnrankedDedicatedServer.exe not found, falling back to BlackOps3.exe" >&2
    ln -sf "$PLUTAINER_SOURCE_DIR/BlackOps3.exe" "$PLUTAINER_GAMEFILES_DIR"/
  fi

  # zone/ is the engine config dir, so real dir + symlinked contents.
  link_dir_contents "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" zone

  # Workshop maps, if the user mounted any. Optional and usually absent, so it
  # is tested rather than left to link_dir_contents' warning — and mirrored
  # rather than symlinked at the top level so a map can also be dropped
  # straight into the volume.
  if [[ -d "$PLUTAINER_SOURCE_DIR/usermaps" ]]; then
    link_dir_contents "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" usermaps
  fi
}

cod_update_boiii() {
  local exe="$PLUTAINER_GAMEFILES_DIR/boiii.exe"
  if [[ -f "$exe" && "${PLUTAINER_AUTO_UPDATE:-}" == "false" ]]; then
    echo "Skipping BOIII update because PLUTAINER_AUTO_UPDATE is set to 'false'."
    return 0
  fi
  if [[ -f "$exe" ]]; then
    echo "Checking for BOIII updates..."
  else
    echo "First container run detected. Downloading BOIII... This may take a moment."
  fi
  # wget -N is timestamping: it only downloads when upstream is newer. Note that
  # this replaces boiii.exe, so a hand-built binary in the volume needs
  # PLUTAINER_AUTO_UPDATE=false to survive a restart.
  wget -q -N -P "$PLUTAINER_GAMEFILES_DIR" "$BOIII_BINARY_URL"
}

cod_launch_boiii() {
  COD_WORKDIR="$PLUTAINER_GAMEFILES_DIR"

  # `-headless` is what removes the X dependency: BOIII's console component
  # builds a real Win32 console *window* unless it is headless, and under Wine
  # with no display the process hangs on window creation
  # ("nodrv_CreateWindow") and never binds its port. `-quiet-crash` suppresses
  # the crash dialog, which nothing in a container can dismiss. `-watchdog`
  # starts BOIII's own hang detector, which reports a wedged script VM to the
  # log instead of leaving a server that holds its port and answers nothing.
  COD_LAUNCH_CMD=(
    wine boiii.exe
    -headless
    -dedicated
    -quiet-crash
    -watchdog
  )

  # BOIII ships its own updater, which is separate from the download above and
  # runs inside the game. It leaves boiii.exe alone unless asked, but it does
  # replace the data files next to it, so PLUTAINER_AUTO_UPDATE=false turns off
  # both halves rather than only the one Plutainer controls.
  if [[ "${PLUTAINER_AUTO_UPDATE:-}" == "false" ]]; then
    COD_LAUNCH_CMD+=(-noupdate)
  fi

  COD_LAUNCH_CMD+=(
    +set fs_game "${PLUTAINER_MOD:-}"
    +set net_port "$ACTIVE_PORT"
    +set logfile "2"
    +exec "$CONFIG_FILE"
  )
  cod_append_extra_args
  cod_append_map_rotate +map_rotate
}

# --- CoD4x -----------------------------------------------------------------

COD4X_ASSET_DIR="/home/plutainer/.plutainer/cod4x"
COD4X_BINARY="cod4x18_dedrun"

cod_stage_cod4x() {
  # main/ and zone/english/ must stay writable real directories: cfg symlinks
  # and games_mp.log land in main/, and CoD4x's patch fastfiles are placed
  # alongside the stock ones in zone/english/.
  link_dir_contents "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" main
  link_dir_contents "$PLUTAINER_SOURCE_DIR" "$PLUTAINER_GAMEFILES_DIR" zone/english
}

cod_update_cod4x() {
  [[ -x "$COD4X_ASSET_DIR/$COD4X_BINARY" ]] || hold_indefinitely \
    "CoD4x is not available in this image (no ${COD4X_BINARY}).
  Upstream publishes a 32-bit x86 Linux binary only, so CoD4x cannot run on this
  architecture. Plutonium, IW4x and Ezz BOIII titles are unaffected."

  local dest="$PLUTAINER_GAMEFILES_DIR/$COD4X_BINARY"

  # Copied, not symlinked: CoD4x ships a self-updater that rewrites the binary
  # in place, which would fail against a read-only image layer. Living in the
  # volume also means an updated build survives container recreation.
  if [[ ! -f "$dest" ]]; then
    echo "First container run detected. Staging CoD4x server binary..."
    cp "$COD4X_ASSET_DIR/$COD4X_BINARY" "$dest"
    chmod +x "$dest"
  elif [[ "${PLUTAINER_AUTO_UPDATE:-}" != "false" ]]; then
    # Only refresh when the image ships something newer; never clobber a build
    # the self-updater fetched.
    if [[ "$COD4X_ASSET_DIR/$COD4X_BINARY" -nt "$dest" ]]; then
      echo "Image ships a newer CoD4x binary — updating."
      cp "$COD4X_ASSET_DIR/$COD4X_BINARY" "$dest"
      chmod +x "$dest"
    fi
  fi

  # CoD4x's own fastfiles and iwd, which a stock CoD4 install lacks. The server
  # refuses to load a map without cod4x_patchv2. cp -n: a user-supplied or
  # self-updated copy always wins.
  cp -n "$COD4X_ASSET_DIR"/zone/english/*.ff "$PLUTAINER_GAMEFILES_DIR/zone/english/" 2>/dev/null || true
  cp -n "$COD4X_ASSET_DIR"/main/*.iwd        "$PLUTAINER_GAMEFILES_DIR/main/"         2>/dev/null || true
}

cod_launch_cod4x() {
  COD_WORKDIR="$PLUTAINER_GAMEFILES_DIR"
  # `dedicated 2` is a public (master-listed) server; `1` is LAN.
  COD_LAUNCH_CMD=(
    "./$COD4X_BINARY"
    +set dedicated "${PLUTAINER_DEDICATED:-2}"
    +set net_port "$ACTIVE_PORT"
    +set fs_homepath "$PLUTAINER_GAMEFILES_DIR"
  )

  # CoD4x authorises servers against its master. Without a token from cod4x.ovh,
  # -1 disables the check so the server still boots; a real token gets it listed.
  if [[ -n "${PLUTAINER_COD4X_AUTH_TOKEN:-}" ]]; then
    COD_LAUNCH_CMD+=(+set sv_authtoken "$PLUTAINER_COD4X_AUTH_TOKEN")
  else
    COD_LAUNCH_CMD+=(+set sv_authorizemode "${PLUTAINER_COD4X_AUTHORIZE_MODE:--1}")
  fi

  [[ -n "${PLUTAINER_MOD:-}" ]] && COD_LAUNCH_CMD+=(+set fs_game "$PLUTAINER_MOD")
  COD_LAUNCH_CMD+=(+exec "$CONFIG_FILE")
  cod_append_extra_args
  cod_append_map_rotate +map_rotate
}

# --- shared launch-argument helpers ----------------------------------------

# A `-flag` appended after the `+` block is silently eaten by the command
# before it, because the engine's console parser reads everything up to the
# next `+` as arguments to that command. Measured: PLUTAINER_EXTRA_ARGS
# "-prime-first-spawn" produced
#
#   ... +exec server_zm.cfg -prime-first-spawn +map_rotate
#
# so the server ran `exec "server_zm.cfg -prime-first-spawn"`, which fails.
# It then started with no config at all — no rcon password, no map rotation,
# sitting in a default lobby — while the config file on disk was perfectly
# correct, which is about as misleading as a failure gets.
#
# So extras are split: engine flags go in front of the `+` block where the
# engine reads them, console commands stay at the end where they belong. A
# value following a flag travels with it (`-foo bar`), and anything before the
# first `+` in COD_LAUNCH_CMD is the executable and this engine's own flags.
cod_append_extra_args() {
  [[ -n "${PLUTAINER_EXTRA_ARGS:-}" ]] || return 0

  # Intentionally word-split: users pass several arguments in one variable.
  # shellcheck disable=SC2206
  local -a extras=( ${PLUTAINER_EXTRA_ARGS} )
  local -a flag_args=() cmd_args=()
  local arg in_flag=""

  for arg in "${extras[@]}"; do
    case "$arg" in
      -*) in_flag="yes"; flag_args+=("$arg") ;;
      +*) in_flag="";    cmd_args+=("$arg")  ;;
      *)  if [[ -n "$in_flag" ]]; then flag_args+=("$arg"); else cmd_args+=("$arg"); fi ;;
    esac
  done

  if (( ${#flag_args[@]} )); then
    local -a head=() tail=()
    local seen_plus=""
    for arg in "${COD_LAUNCH_CMD[@]}"; do
      if [[ -z "$seen_plus" && "$arg" == +* ]]; then
        seen_plus="yes"
      fi
      if [[ -n "$seen_plus" ]]; then tail+=("$arg"); else head+=("$arg"); fi
    done
    COD_LAUNCH_CMD=( "${head[@]}" "${flag_args[@]}" ${tail[@]+"${tail[@]}"} )
  fi

  (( ${#cmd_args[@]} )) && COD_LAUNCH_CMD+=( "${cmd_args[@]}" )
  return 0
}

# Opt-out. An unconditional map-rotate argument overrides playlist- or
# cfg-driven map selection, which some setups want.
# Args: <the argument this engine uses>
cod_append_map_rotate() {
  [[ "${PLUTAINER_MAP_ROTATE:-true}" == "false" ]] && return 0
  COD_LAUNCH_CMD+=("$1")
}
