#!/bin/bash
#
# Refresh the vendored community config seeds under seed-configs/.
#
# The images used to wget these six repos at build time. That made every build
# depend on six third-party repos still existing, unpinned, at the exact moment
# of the build — and because the RUN command string never changed, BuildKit
# reused the layer indefinitely, so upstream edits were invisible until the
# cache was evicted and nobody could tell which revision an image shipped.
#
# Now the files are vendored and COPYed. This script is the only thing that
# changes them: it pins each repo to a resolved commit SHA, records that SHA in
# seed-configs/<game>/SOURCE, and leaves the result as a reviewable diff.
#
# Usage:
#   tools/refresh-seeds.sh              # refresh every game
#   tools/refresh-seeds.sh t6 iw4x      # refresh only these
#   GITHUB_TOKEN=ghp_... tools/refresh-seeds.sh    # avoid API rate limits
#
# cod4x is not handled here — see the note under SEEDS below.
#
# Needs: bash, curl, tar, python3 (JSON parsing only).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED_ROOT="$REPO_ROOT/seed-configs"

# game|owner/repo|branch|src-subpath[:dest-subdir][,...]
#
# src-subpath is relative to the archive root and its *contents* are copied to
# seed-configs/<game>/<dest-subdir>. Omit dest-subdir to land at the game root.
# The layouts differ per repo because each community author picked their own.
SEEDS=(
  "t4|xerxes-at/T4ServerConfigs|main|main"
  "t5|xerxes-at/T5ServerConfig|master|localappdata/Plutonium/storage/t5"
  "t6|xerxes-at/T6ServerConfigs|master|localappdata/Plutonium/storage/t6"
  "iw5|xerxes-at/IW5ServerConfig|master|admin"
  "t7x|Dss0/t7-server-config|main|zone:zone,t7x:t7x"
  "iw4x|iw4x/iw4-server-configs|main|userraw:userraw"
)

# cod4x is deliberately absent: its seed is a single server.cfg maintained in
# this repo (seed-configs/cod4x/main/server.cfg), not tracked from an upstream
# repo. Wiring one file into the fetch/pin/prune machinery buys nothing —
# there is no upstream to drift from.

# Upstream ships sv_maprotation commented out here, unlike every other seed, so
# a first run would boot with +map_rotate and nothing to load. This used to be a
# RUN in both Dockerfiles; it belongs with the vendored file instead, so what is
# committed is what ships. partyserver*.cfg run lobby mode off playlists and are
# deliberately left alone.
IW4X_ROTATION_TARGETS=(server.cfg serverlan.cfg)
IW4X_ROTATION='set sv_maprotation "map mp_afghan map mp_rust map mp_terminal map mp_highrise map mp_favela map mp_quarry map mp_boneyard map mp_checkpoint map mp_subbase map mp_underpass map mp_derail map mp_estate map mp_invasion map mp_rundown map mp_brecourt map mp_nightshift"'

log() { printf '[seeds] %s\n' "$*"; }
die() { printf '[seeds] ERROR: %s\n' "$*" >&2; exit 1; }

# Make RCON reachable from a container sidecar (IW4MAdmin) out of the box.
#
# Two upstream defaults break that, and both are wrong specifically because we
# are in Docker:
#
#   rcon_localhost_bypass "0"  — t5 ships 0, so even 127.0.0.1 traffic is
#       subject to whitelist and rate-limit checks. rcon-cli runs inside the
#       container over loopback, so this is pure downside here.
#
#   rconWhitelistAdd "..."     — the seeds ship example IPs from somebody
#       else's LAN (192.168.0.7, 10.0.0.12, 172.16.8.7). Per upstream's own
#       comment, an empty whitelist allows every IP, but a non-empty one allows
#       *only* those plus loopback — so these placeholders actively lock out the
#       admin tool the user is trying to connect. Verified against a live t4
#       server: RCON from the Docker gateway is dropped until its exact IP is
#       whitelisted.
#
# Ranges are not an option: `rconWhitelistAdd "172.16.0.0/12"` answers
# `Error: Invalid address` — only single addresses are accepted. Enumerating
# Docker gateways does not work either, since subnets are user-definable and
# their gateways are unpredictable (172.17.0.1, 172.26.10.1, ...).
#
# So the placeholders are commented out, restoring upstream's own
# "no entries = all IPs may send RCON" default. RCON still requires the
# password, which every seed ships empty, so this widens nothing until the
# operator sets one. Re-enable by uncommenting and putting in real addresses.
harden_rcon_for_docker() {
  local game_dir="$1" f
  while IFS= read -r -d '' f; do
    RCON_CFG="$f" python3 - <<'PY'
import os
import re

path = os.environ['RCON_CFG']
with open(path, 'r', encoding='utf-8', errors='surrogateescape') as fh:
    text = fh.read()

original = text

# Blank any placeholder credential an upstream seed ships. A known password
# baked into a published image is worth nothing to the operator and plenty to
# anyone scanning; empty is the correct default for all three.
#
#   rcon_password      — empty disables RCON until the operator sets one
#   g_password         — a join password nobody knows locks players *out*
#   sv_privatePassword — same, for reserved slots
#
# Currently a no-op on the tracked repos (they all ship these empty already);
# it exists so a future upstream edit cannot quietly introduce one.
for cvar in ('rcon_password', 'g_password', 'sv_privatePassword'):
    text = re.sub(
        r'(?im)^(\s*(?:set[a]?\s+)?%s\s+)"[^"]*"' % cvar,
        lambda m: '%s""' % m.group(1),
        text,
    )

# Force localhost bypass on wherever the cvar exists. Quoted or bare.
text = re.sub(
    r'(?im)^(\s*(?:set[a]?\s+)?rcon_localhost_bypass\s+)(["\']?)0\2',
    lambda m: '%s%s1%s' % (m.group(1), m.group(2), m.group(2)),
    text,
)

# Comment out placeholder whitelist entries, once.
def comment_out(match):
    line = match.group(0)
    return '// [Plutainer] ' + line

text = re.sub(r'(?im)^(?!\s*//)\s*rconWhitelistAdd\b.*$', comment_out, text)

if text != original:
    if 'Plutainer] rconWhitelistAdd' in text and '[Plutainer] RCON whitelist' not in text:
        text += (
            '\n'
            '// ---------------------------------------------------------------\n'
            '// [Plutainer] The rconWhitelistAdd lines above were commented out.\n'
            '// Upstream ships example IPs from another network; a non-empty\n'
            '// whitelist permits ONLY those addresses plus loopback, which\n'
            '// silently blocks RCON from a sidecar container (IW4MAdmin) on an\n'
            '// unpredictable Docker gateway address. Empty = all IPs may send\n'
            '// RCON, and the password is still required.\n'
            '// Only single addresses are accepted here — CIDR ranges are\n'
            '// rejected with "Error: Invalid address".\n'
            '// To restrict again, uncomment and use your real admin host IP.\n'
            '// ---------------------------------------------------------------\n'
        )
    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as fh:
        fh.write(text)
    print('patched %s' % os.path.basename(path))
PY
  done < <(find "$game_dir" -type f -name '*.cfg' -print0)
}

api_get() {
  local url="$1"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url"
  else
    curl -fsSL "$url"
  fi
}

resolve_sha() {
  local repo="$1" branch="$2"
  api_get "https://api.github.com/repos/${repo}/commits/${branch}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])'
}

apply_iw4x_rotation() {
  local game_dir="$1" f p
  for f in "${IW4X_ROTATION_TARGETS[@]}"; do
    p="$game_dir/userraw/$f"
    [[ -f "$p" ]] || continue
    # Upstream may enable it themselves one day; don't fight them if so.
    if grep -qE '^[[:space:]]*set[[:space:]]+sv_maprotation' "$p"; then
      log "  $f already has an active sv_maprotation, leaving it alone"
      continue
    fi
    cat >> "$p" <<EOF

// ---------------------------------------------------------------
// Added by Plutainer (tools/refresh-seeds.sh): upstream ships
// sv_maprotation commented out, which leaves +map_rotate with
// nothing to load on a first run.
// Stock MW2 maps only, so this works without the DLC fastfiles.
// Edit freely, or set PLUTAINER_MAP_ROTATE=false to drive map
// selection from a playlist instead.
// ---------------------------------------------------------------
$IW4X_ROTATION
EOF
    log "  appended stock sv_maprotation to $f"
  done
}

refresh_one() {
  local spec="$1"
  local game repo branch paths
  IFS='|' read -r game repo branch paths <<< "$spec"

  log "$game: resolving ${repo}@${branch}"
  local sha
  sha="$(resolve_sha "$repo" "$branch")" || die "could not resolve ${repo}@${branch}"
  [[ -n "$sha" ]] || die "empty SHA for ${repo}@${branch}"

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand tmp now, not at trap time
  trap "rm -rf '$tmp'" RETURN

  log "$game: fetching ${sha:0:12}"
  curl -fsSL "https://github.com/${repo}/archive/${sha}.tar.gz" -o "$tmp/src.tar.gz" \
    || die "download failed for ${repo}@${sha}"
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp/x" --strip-components=1

  local game_dir="$SEED_ROOT/$game"
  rm -rf "$game_dir"
  mkdir -p "$game_dir"

  local entry src dest
  IFS=',' read -ra entries <<< "$paths"
  for entry in "${entries[@]}"; do
    src="${entry%%:*}"
    dest="${entry#*:}"
    [[ "$dest" == "$entry" ]] && dest=""
    [[ -d "$tmp/x/$src" ]] || die "$game: '$src' not found in ${repo}@${sha} (upstream layout changed?)"
    mkdir -p "$game_dir/$dest"
    cp -r "$tmp/x/$src/." "$game_dir/$dest/"
  done

  # Reference dumps are large and are not first-run scaffolding; scripts and
  # readmes are for humans running the game on Windows, not for the volume.
  find "$game_dir" -type d -iname '*REFERENCE*' -exec rm -rf {} + 2>/dev/null || true
  find "$game_dir" -type f \( -iname '*.bat' -o -iname '*.sh' -o -iname 'README*' \) -delete

  [[ "$game" == "iw4x" ]] && apply_iw4x_rotation "$game_dir"

  harden_rcon_for_docker "$game_dir"

  local upstream_license
  upstream_license="$(api_get "https://api.github.com/repos/${repo}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); l=d.get("license") or {}; print(l.get("spdx_id") or "none declared")' \
    2>/dev/null || echo "unknown")"

  cat > "$game_dir/SOURCE" <<EOF
upstream:   https://github.com/${repo}
branch:     ${branch}
commit:     ${sha}
tree:       https://github.com/${repo}/tree/${sha}
subpaths:   ${paths}
license:    ${upstream_license}
fetched:    $(date -u +%Y-%m-%dT%H:%M:%SZ)
fetched-by: tools/refresh-seeds.sh

Vendored copy. Do not hand-edit: run tools/refresh-seeds.sh ${game} instead,
so the recorded commit stays honest about what is in this directory.
EOF

  log "$game: $(find "$game_dir" -type f | wc -l) files, $(du -sh "$game_dir" | cut -f1)"
}

main() {
  command -v curl >/dev/null || die "curl is required"
  command -v python3 >/dev/null || die "python3 is required"

  local wanted=("$@") spec game matched=0
  for spec in "${SEEDS[@]}"; do
    game="${spec%%|*}"
    if [[ ${#wanted[@]} -gt 0 ]]; then
      local found=0 w
      for w in "${wanted[@]}"; do [[ "$w" == "$game" ]] && found=1; done
      [[ $found -eq 1 ]] || continue
    fi
    refresh_one "$spec"
    matched=$((matched + 1))
  done

  [[ $matched -gt 0 ]] || die "no matching games (known: t4 t5 t6 iw5 t7x iw4x)"
  log "done — review with: git -C '$REPO_ROOT' diff --stat seed-configs/"
}

main "$@"
