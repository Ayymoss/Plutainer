#!/usr/bin/env python3
"""Mirror Ezz BOIII's data/ set into its appdata directory.

BOIII only fetches data/ through its client updater, which a dedicated server
never runs. Without it a server is not merely missing extras: dvar names come
back as hashes in every status reply (so no map is visible to the health check
or to IW4MAdmin), and the launcher-UI file the server is gated on is absent.

The manifest is BOIII's own update manifest, a list of [path, size, sha1].
Only files whose size or sha1 differ are downloaded, so a re-run is cheap.
"""

import hashlib
import json
import sys
import urllib.request
from pathlib import Path


MANIFEST_URL = "https://r2.ezz.lol/boiii.json"
FILE_URL = "https://r2.ezz.lol/boiii/{path}"
# The bucket answers 403 to urllib's default User-Agent.
HEADERS = {"User-Agent": "Plutainer"}


def fetch(url):
    request = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def sha1_of(path):
    return hashlib.sha1(path.read_bytes()).hexdigest().upper()


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <appdata dir>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])

    manifest = json.loads(fetch(MANIFEST_URL))
    entries = [entry for entry in manifest if entry[0].startswith("data/")]

    fetched = 0
    for name, size, sha1 in entries:
        dest = root / name
        if dest.is_file() and dest.stat().st_size == size and sha1_of(dest) == sha1.upper():
            continue
        body = fetch(FILE_URL.format(path=name))
        if len(body) != size or hashlib.sha1(body).hexdigest().upper() != sha1.upper():
            print(f"[ERROR] {name} does not match BOIII's manifest", file=sys.stderr)
            return 1
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_name(dest.name + ".part")
        tmp.write_bytes(body)
        tmp.replace(dest)
        fetched += 1

    print(f"BOIII data: {len(entries)} files, {fetched} updated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
