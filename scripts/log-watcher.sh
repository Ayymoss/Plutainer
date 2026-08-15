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
MAX_SIZE_RAW="${PLUTAINER_LOG_MAX_SIZE:-64M}"
KEEP="${PLUTAINER_LOG_KEEP:-1}"

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

# --- Log rotation -----------------------------------------------------------
#
# Game logs grow without bound, and a large enough one stops the server logging
# at all: CoD4x's writer hands each buffered chunk to fwrite() and, when that
# fwrite fails, prints a warning and drops the data — the ring buffer has
# already been advanced. Nothing retries and nothing reopens the file, so once
# the write starts failing the log is dead for the life of the process. A
# log-driven admin tool (IW4MAdmin reads in-game commands from the log) then
# looks like it has stopped responding, even though RCON still works.
#
# Rotation is copy-truncate, which is safe here because every engine opens its
# game log in append mode — CoD4x is literally fopen(path, "ab"). With O_APPEND
# each write seeks to EOF first, so after truncation writes resume at offset 0.
# Verified on all eleven server types: none returned to its previous size, which
# is what a non-append writer would have done by leaving a sparse hole.
#
# Truncating rather than renaming is deliberate: the engine holds an open handle
# and renaming would leave it writing to the renamed inode, so the path the
# admin tool reads would silently stop updating — the exact failure being fixed.
#
# Worst-case disk per log is MAX_SIZE x (KEEP + 1), so the defaults (64M, keep
# 1) cost at most ~128 MB per server. That matters at scale: a community with
# thirty servers rotating at a gigabyte would be carrying tens of gigabytes of
# logs nobody reads. Live tailing only ever needs the tail, and an admin tool
# keeps its own history in its database.
#
# Set PLUTAINER_LOG_MAX_SIZE=0 to disable, or PLUTAINER_LOG_KEEP=0 to rotate
# without keeping a copy at all.
parse_size() {
  local raw="${1^^}" num unit
  num="${raw%[KMG]}"
  unit="${raw#"$num"}"
  [[ "$num" =~ ^[0-9]+$ ]] || { echo ""; return 1; }
  case "$unit" in
    K) echo $(( num * 1024 )) ;;
    M) echo $(( num * 1024 * 1024 )) ;;
    G) echo $(( num * 1024 * 1024 * 1024 )) ;;
    "") echo "$num" ;;
    *) echo ""; return 1 ;;
  esac
}

MAX_SIZE=$(parse_size "$MAX_SIZE_RAW") || {
  echo "[log-watcher] WARN: cannot parse PLUTAINER_LOG_MAX_SIZE='$MAX_SIZE_RAW'; rotation disabled." >&2
  MAX_SIZE=0
}

rotate_if_oversized() {
  local path="$1" size
  (( MAX_SIZE > 0 )) || return 0

  size=$(stat -c %s "$path" 2>/dev/null) || return 0
  (( size >= MAX_SIZE )) || return 0

  echo "[log-watcher] $(basename "$path") reached ${size}B (limit ${MAX_SIZE}B) — rotating"

  if (( KEEP > 0 )); then
    # Shift older generations down: .2 -> .3, .1 -> .2, ...
    local i
    for (( i = KEEP - 1; i >= 1; i-- )); do
      [[ -f "$path.$i" ]] && mv -f "$path.$i" "$path.$((i + 1))" 2>/dev/null
    done
    if ! cp -f "$path" "$path.1" 2>/dev/null; then
      echo "[log-watcher] WARN: could not copy $path aside; truncating without a backup." >&2
    fi
    # Drop anything beyond the keep count.
    for old in "$path".*; do
      [[ "$old" =~ \.([0-9]+)$ ]] || continue
      (( BASH_REMATCH[1] > KEEP )) && rm -f "$old"
    done
  fi

  # Truncate in place. The engine's next append lands at offset 0.
  : > "$path" || echo "[log-watcher] WARN: could not truncate $path" >&2

  # Immediately write a marker so the file is never observed at zero bytes.
  #
  # This is not cosmetic. IW4MAdmin tracks its read position as a byte offset
  # and treats zero as "no position yet":
  #
  #     if (_previousFileSize == 0) { _previousFileSize = fileSize; }
  #     var fileDiff = fileSize - _previousFileSize;
  #     if (fileDiff < 1 ...) { _previousFileSize = fileSize; return; }
  #
  # After a truncation its offset resets to 0, and the next poll that sees the
  # file grow re-syncs to the new size *instead of reading it* — so the first
  # batch of events written after a rotation is silently dropped. Measured: with
  # a bare truncate, the first map change after rotation was never read and the
  # second was. Leaving one line behind keeps the offset non-zero, so the very
  # next batch is read normally.
  #
  # The text is deliberately plain and semicolon-free: game log parsers key off
  # `say;`/`J;`/`K;` style prefixes, so this parses as nothing and is ignored.
  printf '  0:00 [Plutainer] log rotated - previous %s bytes kept alongside\n' \
    "$size" >> "$path" 2>/dev/null || true
}

# Put one line into a brand-new, empty game log, for the same reason the rotation
# path writes a marker: a reader that treats a zero offset as "no position yet"
# re-syncs on the first growth instead of reading it, so the first batch of
# events after the log is created gets dropped. That is every event of the first
# map on a fresh deployment.
#
# Measured with IW4MAdmin across eleven servers: the eight whose logs already had
# content ingested the first injected event; the three whose logs were empty did
# not, and ingested the next one. Priming removes that asymmetry.
prime_empty_log() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  [[ ! -s "$path" ]] || return 0
  printf '  0:00 [Plutainer] log opened\n' >> "$path" 2>/dev/null || true
}

BOOT_TS=$(date +%s)

declare -A CURRENT_TARGET

echo "[log-watcher] started; boot_ts=$BOOT_TS stable_dir=$STABLE_DIR"
if (( MAX_SIZE > 0 )); then
  echo "[log-watcher] rotating game logs above ${MAX_SIZE_RAW} (keeping ${KEEP})"
else
  echo "[log-watcher] log rotation disabled"
fi

while true; do
  declare -A NEWEST_MTIME=()
  declare -A NEWEST_PATH=()

  while IFS= read -r -d '' path; do
    mtime=$(stat -c %Y "$path" 2>/dev/null) || continue
    (( mtime < BOOT_TS )) && continue
    # Only the live log is worth rotating; stale logs from earlier sessions are
    # already excluded by the boot-time check above.
    rotate_if_oversized "$path"
    prime_empty_log "$path"
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
