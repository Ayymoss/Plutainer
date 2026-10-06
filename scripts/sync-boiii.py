#!/usr/bin/env python3
"""Install Ezz BOIII's binary and data/ set from one of its update channels.

BOIII only fetches data/ through its client updater, which a dedicated server
never runs. Without it a server is not merely missing extras: dvar names come
back as hashes in every status reply (so no map is visible to the health check
or to IW4MAdmin), and the launcher-UI file the server is gated on is absent.

The manifests are BOIII's own update manifests, a list of [path, size, sha1].
`stable` is what GitHub's latest release ships (same boiii.exe, byte for byte);
`beta` is built from upstream's beta branch whenever they cut one for testing.
Only files whose size or sha1 differ are downloaded, so a re-run is cheap.

The binary is matched on sha1 rather than on a timestamp, because a timestamp
cannot go backwards: the beta exe is usually newer than the stable one, so a
server switched back to stable would otherwise keep running the beta.

The two channels do not ship the same data/ files (beta adds a ZM GSC, among
others), so after a switch data/ is pruned to exactly the active manifest. That
is what BOIII's own updater does on every start it is allowed to run
(file_updater::cleanup_data_directory), so nothing kept there would survive a
stable server anyway. Nothing is kept beside data/ either: the same updater
deletes every file in the appdata root it does not recognise.
"""

import argparse
import hashlib
import json
import sys
import urllib.request
from pathlib import Path


CHANNELS = {
    "stable": ("https://r2.ezz.lol/boiii.json", "https://r2.ezz.lol/boiii/{path}"),
    "beta": ("https://r2.ezz.lol/boiii-beta.json", "https://r2.ezz.lol/boiii/beta/{path}"),
}
EXE = "boiii.exe"
# The bucket answers 403 to urllib's default User-Agent.
HEADERS = {"User-Agent": "Plutainer"}


def fetch(url):
    request = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def sha1_of(path):
    return hashlib.sha1(path.read_bytes()).hexdigest().upper()


def matches(path, size, sha1):
    return path.is_file() and path.stat().st_size == size and sha1_of(path) == sha1.upper()


def install(url, dest, name, size, sha1):
    body = fetch(url)
    if len(body) != size or hashlib.sha1(body).hexdigest().upper() != sha1.upper():
        raise ValueError(f"{name} does not match BOIII's manifest")
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".part")
    tmp.write_bytes(body)
    tmp.replace(dest)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("appdata", type=Path, help="BOIII's appdata directory; data/ goes here")
    parser.add_argument("--channel", choices=CHANNELS, default="stable")
    parser.add_argument("--exe-dir", type=Path,
                        help="also install boiii.exe into this directory")
    args = parser.parse_args()

    manifest_url, file_url = CHANNELS[args.channel]
    try:
        manifest = json.loads(fetch(manifest_url))
        if args.exe_dir:
            exe = next((e for e in manifest if e[0] == EXE), None)
            if exe is None:
                raise ValueError(f"the {args.channel} manifest lists no {EXE}")
            dest = args.exe_dir / EXE
            if matches(dest, exe[1], exe[2]):
                print(f"BOIII {args.channel}: {EXE} is current ({exe[2][:12]}).")
            else:
                install(file_url.format(path=EXE), dest, *exe)
                print(f"BOIII {args.channel}: installed {EXE} ({exe[2][:12]}).")

        entries = [e for e in manifest if e[0].startswith("data/")]
        fetched = 0
        for name, size, sha1 in entries:
            dest = args.appdata / name
            if not matches(dest, size, sha1):
                install(file_url.format(path=name), dest, name, size, sha1)
                fetched += 1
    except (ValueError, OSError) as error:
        # OSError covers urllib's network errors too.
        print(f"[ERROR] BOIII {args.channel}: {error}", file=sys.stderr)
        return 1

    data = args.appdata / "data"
    listed = {args.appdata / name for name, _, _ in entries}
    removed = 0
    for path in sorted(data.rglob("*"), reverse=True):
        if path.is_dir() and not path.is_symlink():
            # Deepest first, so an emptied ui_scripts/<name>/ goes too; it
            # would otherwise still look like a script to load.
            try:
                path.rmdir()
            except OSError:
                pass
        elif path not in listed:
            try:
                path.unlink()
            except OSError as error:
                print(f"[ERROR] BOIII {args.channel}: {error}", file=sys.stderr)
                return 1
            removed += 1

    print(f"BOIII {args.channel} data: {len(entries)} files, {fetched} updated, {removed} removed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
