#!/bin/bash
#
# Migrate a v1 Plutainer volume to the v2 layout.
#
# v1: app/{gamefiles,plutonium,logs}
# v2: app/{configs,runtime/{gamefiles,plutonium},logs,.plutainer-version}
#
# Run via:
#   docker run --rm \
#     -v <your_app_volume>:/home/plutainer/app \
#     --entrypoint /home/plutainer/.plutainer/migrate-v1-to-v2.sh \
#     ghcr.io/ayymoss/plutainer:v2
#
# Add --dry-run as the first argument to preview without making changes.
#
# Effects:
#   1. mkdir runtime/, configs/
#   2. mv app/gamefiles -> app/runtime/gamefiles  (if present)
#   3. mv app/plutonium -> app/runtime/plutonium  (if present)
#   4. For each known engine config dir, move every top-level *.cfg into
#      app/configs/ and leave a relative symlink in its place.
#   5. Wipe app/logs/* (stale symlinks; log-watcher re-creates on next start).
#   6. Write app/.plutainer-version=2
#
set -euo pipefail

APP_DIR="/home/plutainer/app"
CONFIGS_DIR="$APP_DIR/configs"
RUNTIME_DIR="$APP_DIR/runtime"
GAMEFILES_DIR="$RUNTIME_DIR/gamefiles"
PLUTONIUM_DIR="$RUNTIME_DIR/plutonium"
MARKER="$APP_DIR/.plutainer-version"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "[DRY-RUN] no changes will be made"
fi

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  + $*"
  else
    echo "  + $*"
    "$@"
  fi
}

# --- Sanity checks ---
if [[ ! -d "$APP_DIR" ]]; then
  echo "[ERROR] $APP_DIR is not mounted." >&2
  exit 1
fi

if [[ -f "$MARKER" ]]; then
  v="$(cat "$MARKER" 2>/dev/null || echo "")"
  if [[ "$v" == "2" ]]; then
    echo "[INFO] Volume is already v2 (marker present). Nothing to do."
    exit 0
  else
    echo "[ERROR] Unexpected version marker: '$v'. Refusing to migrate." >&2
    exit 1
  fi
fi

if [[ ! -d "$APP_DIR/gamefiles" && ! -d "$APP_DIR/plutonium" ]]; then
  echo "[INFO] No v1 markers found and no version file — treating as fresh volume."
  run mkdir -p "$CONFIGS_DIR" "$APP_DIR/logs" "$RUNTIME_DIR"
  if [[ "$DRY_RUN" != "true" ]]; then echo 2 > "$MARKER"; else echo "  + echo 2 > $MARKER"; fi
  echo "[OK] Initialised fresh v2 volume."
  exit 0
fi

echo "[INFO] v1 layout detected — beginning migration."
echo

# --- Step 1: create runtime/, configs/ ---
echo "--- Creating new directories ---"
run mkdir -p "$RUNTIME_DIR" "$CONFIGS_DIR" "$APP_DIR/logs"
echo

# --- Step 2: move gamefiles, plutonium under runtime/ ---
echo "--- Relocating gamefiles/ and plutonium/ under runtime/ ---"
if [[ -d "$APP_DIR/gamefiles" ]]; then
  run mv "$APP_DIR/gamefiles" "$GAMEFILES_DIR"
fi
if [[ -d "$APP_DIR/plutonium" ]]; then
  run mv "$APP_DIR/plutonium" "$PLUTONIUM_DIR"
fi
echo

# --- Step 3: lift top-level *.cfg from engine config dirs into configs/ ---
echo "--- Lifting top-level *.cfg files into configs/ ---"
# Known engine config dirs in v2 paths (after the move above).
ENGINE_DIRS=(
  "$GAMEFILES_DIR/main"           # plutonium t4
  "$GAMEFILES_DIR/admin"          # plutonium iw5
  "$GAMEFILES_DIR/userraw"        # iw4x
  "$GAMEFILES_DIR/zone"           # alterware t7x
  "$PLUTONIUM_DIR/storage/t5"     # plutonium t5
  "$PLUTONIUM_DIR/storage/t6"     # plutonium t6
)

lift_cfg() {
  local src="$1" base dest rel
  base="$(basename "$src")"
  dest="$CONFIGS_DIR/$base"
  if [[ -e "$dest" ]]; then
    echo "  [SKIP] $base already exists in configs/ — leaving $src untouched"
    return 0
  fi
  run mv "$src" "$dest"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  + ln -sfn ../<relpath>/$base $src"
  else
    rel=$(realpath --relative-to="$(dirname "$src")" "$dest")
    ln -sfn "$rel" "$src"
    echo "  + ln -sfn $rel $src"
  fi
}

shopt -s nullglob
for d in "${ENGINE_DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  found_any=false
  for f in "$d"/*.cfg; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    if [[ "$found_any" == "false" ]]; then
      echo " in $d:"
      found_any=true
    fi
    lift_cfg "$f"
  done
done
shopt -u nullglob
echo

# --- Step 4: clear app/logs/ stale entries ---
echo "--- Clearing stale entries in logs/ (log-watcher will repopulate) ---"
if compgen -G "$APP_DIR/logs/*" > /dev/null; then
  run find "$APP_DIR/logs" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi
echo

# --- Step 5: write marker ---
echo "--- Writing version marker ---"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "  + echo 2 > $MARKER"
else
  echo 2 > "$MARKER"
  echo "  + wrote $MARKER"
fi
echo

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY-RUN] No changes made. Re-run without --dry-run to apply."
else
  echo "[OK] Migration complete. You can now start the v2 container."
fi
