#!/bin/bash
#
# Filesystem helpers shared by every family. Sourced by lib/core.sh.
#
# These are about symlink hygiene, not about any one engine: mirroring a
# read-only mount into a writable tree, and fanning configs out of app/configs/
# into wherever a server insists on reading them. The CoD entry scripts were the
# first users; the SteamCMD family needs the same behaviour for Source games,
# which keep their cfg inside the SteamCMD-owned install directory.
#

# Symlink specific named entries from a source dir into a destination dir.
# Skips (with a warning) any names that don't exist — avoids the dangling
# symlink trap that bash brace expansion `{a,b,c}` creates when files are
# missing. Existing dest entries are replaced (ln -sf).
# Usage: link_files <source_dir> <dest_dir> <name1> [name2 ...]
link_files() {
  local src="$1" dest="$2"
  shift 2
  local name
  for name in "$@"; do
    if [[ -e "$src/$name" ]]; then
      ln -sf "$src/$name" "$dest/"
    else
      echo "[WARN] missing $src/$name — skipping symlink" >&2
    fi
  done
}

# Create <dest_root>/<name> as a REAL directory and symlink the *contents* of
# <src_root>/<name> into it. Use this instead of link_files wherever we must
# write into a directory that also carries read-only host game files:
#   - the engine config dir, where link_configs fans out cfg symlinks;
#   - any dir an updater writes into (e.g. iw4x-launcher's zone/patch/*.ff).
# Symlinking the directory itself would make the whole path read-only, and
# `ln -sf src/name dest/` would nest the link *inside* an existing dir as
# dest/name/name. Idempotent, and replaces a directory symlink left behind by
# an older image version.
# Usage: link_dir_contents <source_root> <dest_root> <name>
link_dir_contents() {
  local src_root="$1" dest_root="$2" name="$3"
  local dest="$dest_root/$name"

  # Build the destination path one component at a time, replacing a symlink at
  # ANY level. `name` may be nested (e.g. zone/english), and an older image
  # symlinked the parent (`zone`) itself — plain `mkdir -p` would silently
  # follow that link into the read-only mount instead of replacing it.
  local -a comps
  local acc="" comp
  IFS='/' read -ra comps <<< "$name"
  for comp in "${comps[@]}"; do
    [[ -n "$comp" ]] || continue
    acc="${acc:+$acc/}$comp"
    if [[ -L "$dest_root/$acc" ]]; then
      echo "[INFO] Replacing directory symlink $dest_root/$acc with a real directory."
      rm -f "$dest_root/$acc"
    fi
    mkdir -p "$dest_root/$acc"
  done

  local src="$src_root/$name"
  if [[ ! -d "$src" ]]; then
    echo "[WARN] missing $src — nothing to link into $dest" >&2
    return 0
  fi

  # Mirror the source's directory skeleton as REAL dirs, then symlink only leaf
  # entries. Symlinking a subdirectory would inherit the read-only mount and
  # block writes one level down — e.g. iw4x-launcher extracting into
  # zone/patch/ dies with "failed to extract file" when zone/patch is a link.
  # find walks parents before children, so a replaced dir is always created
  # before anything nested inside it. `mkdir -p` alone is not enough: it
  # succeeds silently on an existing symlink-to-a-dir, which would leave a
  # read-only link from an older image in place.
  local rel
  while IFS= read -r -d '' rel; do
    if [[ -L "$dest/$rel" ]]; then
      echo "[INFO] Replacing directory symlink $dest/$rel with a real directory."
      rm -f "$dest/$rel"
    fi
    mkdir -p "$dest/$rel"
  done < <(cd "$src" && find . -mindepth 1 -type d -printf '%P\0')

  # Never clobber a real file already at the destination: an updater may have
  # written a newer copy there, and that must win over the host's version.
  while IFS= read -r -d '' rel; do
    if [[ -e "$dest/$rel" && ! -L "$dest/$rel" ]]; then
      continue
    fi
    ln -sfn "$src/$rel" "$dest/$rel"
  done < <(cd "$src" && find . \( -type f -o -type l \) -printf '%P\0')

  # Reap symlinks whose target no longer exists in the mount. Without this,
  # trimming the gamefiles mount leaves the volume full of dangling links that
  # persist for the life of the volume — the engine then sees entries it cannot
  # open, and the layout stops reflecting what is actually mounted. Only
  # symlinks are removed, so a real file written here by an updater is safe.
  find "$dest" -xtype l -delete 2>/dev/null || true
}

# For every *.cfg in configs/, place a relative symlink at each provided
# engine dir. Skips dirs that don't exist; warns on real-file collisions
# (refuses to overwrite a non-symlink); reaps cfg symlinks under each engine
# dir whose target no longer exists.
# No-op when PLUTAINER_USE_RAW_CONFIGS is true (engine path IS the SOT).
# Args: <engine_dir1> [engine_dir2 ...]
link_configs() {
  [[ "${PLUTAINER_USE_RAW_CONFIGS:-}" == "true" ]] && return 0
  [[ -d "$PLUTAINER_CONFIGS_DIR" ]] || return 0

  local engine_dir f base link target_rel
  for engine_dir in "$@"; do
    [[ -n "$engine_dir" ]] || continue
    mkdir -p "$engine_dir"

    # Fan-out: configs/<X>.cfg -> engine_dir/<X>.cfg
    for f in "$PLUTAINER_CONFIGS_DIR"/*.cfg; do
      [[ -e "$f" ]] || continue
      base="$(basename "$f")"
      link="$engine_dir/$base"
      if [[ -e "$link" && ! -L "$link" ]]; then
        echo "[link_configs] WARNING: real file at $link blocks symlink to $f" >&2
        echo "  Move or delete the real file if you want it managed via configs/." >&2
        continue
      fi
      target_rel=$(realpath --relative-to="$engine_dir" "$f")
      ln -sfn "$target_rel" "$link"
    done

    # Reap: drop cfg symlinks here whose source no longer resolves.
    for link in "$engine_dir"/*.cfg; do
      [[ -L "$link" && ! -e "$link" ]] || continue
      echo "[link_configs] reaping dangling: $link" >&2
      rm -f "$link"
    done
  done
}
