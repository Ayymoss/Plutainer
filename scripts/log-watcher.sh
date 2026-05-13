#!/bin/bash
#
# Maintains stable symlinks at /home/plutainer/app/logs/<basename> pointing at
# the active game log for that basename. Game logs move around per game/mod
# (e.g. plutonium/storage/t5/mods/<mod>/logs/games_zm.log) and users create
# arbitrarily named logs (e.g. games_koth.log), which makes IW4MAdmin
# configuration brittle. This watcher surfaces every *.log under app/ in one
# predictable flat directory.
#
# Strategy:
#   - Record container boot time.
#   - Poll app/ for every *.log (excluding app/logs/ itself to avoid cycles).
#   - For each basename, the active log is the one with mtime >= boot time and
#     the newest mtime overall. Stale logs from prior sessions keep their old
#     mtime and are ignored. Collisions across mod dirs resolve to the
#     currently-written file (game only writes one at a time).
#   - Symlinks are relative so they resolve the same from host, this
#     container, or any sidecar container mounting the app/ volume.
#   - Only repoint when target changes (idempotent, no fs churn).
#   - Startup heal: dangling symlinks from prior runs (target removed between
#     restarts) are converted to empty stub files. Preserves presence so a
#     sidecar like IW4MAdmin never sees a missing path and doesn't attempt to
#     create a directory in its place.
#   - Atomic repointing via mv -Tf from a temp symlink so readers never catch
#     the link in a missing or half-written state.
#

APP_DIR=/home/plutainer/app
STABLE_DIR="$APP_DIR/logs"
POLL_INTERVAL="${PLUTAINER_LOG_POLL_INTERVAL:-2}"

if [[ "${PLUTAINER_LOG_SYMLINKS}" == "false" ]]; then
  echo "[log-watcher] disabled via PLUTAINER_LOG_SYMLINKS=false"
  exit 0
fi

mkdir -p "$STABLE_DIR"

# Atomically place a symlink at $link -> $rel_target. Works whether $link
# currently does not exist, is a regular file (legacy stub), or is a symlink.
# If $link is a directory (typically created by a sidecar bind-mounting a
# non-existent log file, which makes Docker auto-create a dir on the host),
# strip it first — mv -T refuses to replace a directory. Without this strip,
# mv fails every poll and litters $STABLE_DIR with .XXX temp symlinks.
place_symlink() {
  local link="$1" rel_target="$2"
  local tmp
  if [[ -d "$link" && ! -L "$link" ]]; then
    echo "[log-watcher] stray directory at $link (sidecar bind-mount artifact); removing"
    if ! rmdir -- "$link" 2>/dev/null && ! rm -rf -- "$link" 2>/dev/null; then
      echo "[log-watcher] ERROR: cannot remove $link — likely root-owned with root-owned contents." >&2
      echo "[log-watcher] Fix sidecar volume to mount the logs/ DIRECTORY, not individual log FILES." >&2
      return 1
    fi
  fi
  tmp=$(mktemp -u -p "$STABLE_DIR" ".$(basename "$link").XXXXXX")
  ln -s "$rel_target" "$tmp"
  mv -Tf "$tmp" "$link"
}

# Startup heal:
#   - Dangling symlinks from prior runs → empty stub files so sidecar readers
#     always see a file. If the old target is still valid, leave the symlink
#     alone — IW4MAdmin can keep reading continuously until a fresh target is
#     identified by the poll loop below.
#   - Stray directories (sidecar bind-mount of a non-existent log makes Docker
#     auto-create a dir on the host) → remove. Otherwise place_symlink's
#     mv -Tf fails forever and the namespace silts up with .XXX temp symlinks.
#   - Stray orphan temp symlinks from prior failed place_symlink runs → remove.
if compgen -G "$STABLE_DIR/.*" > /dev/null 2>&1; then
  for entry in "$STABLE_DIR"/.*; do
    base=$(basename "$entry")
    [[ "$base" == "." || "$base" == ".." ]] && continue
    if [[ -L "$entry" && "$base" =~ ^\..+\.[A-Za-z0-9]{6}$ ]]; then
      echo "[log-watcher] removing orphan temp symlink: $base"
      rm -f -- "$entry"
    fi
  done
fi
if compgen -G "$STABLE_DIR/*" > /dev/null; then
  for entry in "$STABLE_DIR"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    if [[ -d "$entry" && ! -L "$entry" ]]; then
      echo "[log-watcher] stray directory at $(basename "$entry") (sidecar bind-mount artifact); removing"
      if ! rmdir -- "$entry" 2>/dev/null && ! rm -rf -- "$entry" 2>/dev/null; then
        echo "[log-watcher] WARN: cannot remove $(basename "$entry") — likely root-owned with root-owned contents. Fix sidecar volume to mount the logs/ DIRECTORY, not individual log FILES." >&2
      fi
      continue
    fi
    if [[ -L "$entry" && ! -e "$entry" ]]; then
      echo "[log-watcher] healing dangling symlink: $(basename "$entry")"
      rm -f "$entry"
      touch "$entry"
    fi
  done
fi

BOOT_TS=$(date +%s)

declare -A CURRENT_TARGET

echo "[log-watcher] started; boot_ts=$BOOT_TS stable_dir=$STABLE_DIR"

while true; do
  declare -A NEWEST_MTIME=()
  declare -A NEWEST_PATH=()

  while IFS= read -r -d '' path; do
    mtime=$(stat -c %Y "$path" 2>/dev/null) || continue
    (( mtime < BOOT_TS )) && continue
    name=$(basename "$path")
    if (( mtime > ${NEWEST_MTIME[$name]:-0} )); then
      NEWEST_MTIME[$name]=$mtime
      NEWEST_PATH[$name]=$path
    fi
  done < <(find "$APP_DIR" -path "$STABLE_DIR" -prune -o -type f -name '*.log' -print0 2>/dev/null)

  for name in "${!NEWEST_PATH[@]}"; do
    path="${NEWEST_PATH[$name]}"
    if [[ "$path" != "${CURRENT_TARGET[$name]:-}" ]]; then
      link="$STABLE_DIR/$name"
      rel_target=$(realpath --relative-to="$STABLE_DIR" "$path")
      place_symlink "$link" "$rel_target"
      CURRENT_TARGET[$name]=$path
      echo "[log-watcher] $name -> $rel_target"
    fi
  done

  unset NEWEST_MTIME NEWEST_PATH
  sleep "$POLL_INTERVAL"
done
