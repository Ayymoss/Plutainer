#!/usr/bin/env python3
"""Install a Thunderstore package and its dependency graph for Nebula."""

import argparse
import io
import json
import re
import shutil
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path


API_URL = "https://thunderstore.io/api/experimental/package/{namespace}/{name}/"
DOWNLOAD_URL = "https://thunderstore.io/package/download/{namespace}/{name}/{version}/"
VERSION_RE = re.compile(r"^(?P<package>.+)-(?P<version>\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)$")
VERSION_ONLY_RE = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
IDENTIFIER_RE = re.compile(r"^[0-9A-Za-z_-]+$")


class PackageNotFound(RuntimeError):
    pass


def version_key(version):
    return tuple(int(part) for part in version.split("-", 1)[0].split("."))


def split_spec(spec):
    """Return namespace, name and optional version from a package spec.

    User-facing specs use ``namespace-name[:version]`` (or a slash between the
    namespace and name). ``:latest`` and an omitted version both track the
    current active release. Thunderstore manifest dependencies retain their
    native ``namespace-name-version`` form for compatibility.
    """
    spec = spec.strip()
    if not spec:
        raise ValueError("empty Thunderstore package name")

    version = None
    if ":" in spec:
        spec, requested = spec.rsplit(":", 1)
        requested = requested.strip()
        if not requested or requested.lower() == "latest":
            version = None
        elif VERSION_ONLY_RE.fullmatch(requested):
            version = requested
        else:
            raise ValueError(
                f"invalid version '{requested}'; use latest or a semantic version"
            )
    else:
        match = VERSION_RE.match(spec)
        if match:
            spec = match.group("package")
            version = match.group("version")

    if "/" in spec:
        namespace, name = spec.split("/", 1)
    elif "-" in spec:
        namespace, name = spec.split("-", 1)
    else:
        raise ValueError(
            f"'{spec}' is not a package name; use namespace-name or namespace/name"
        )

    if not IDENTIFIER_RE.fullmatch(namespace) or not IDENTIFIER_RE.fullmatch(name):
        raise ValueError(f"invalid Thunderstore package name '{spec}'")
    return namespace, name, version


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Plutainer/2"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise PackageNotFound(f"Thunderstore package endpoint not found: {url}") from error
        raise RuntimeError(f"could not download {url}: HTTP {error.code}") from error
    except (OSError, urllib.error.URLError) as error:
        raise RuntimeError(f"could not download {url}: {error}") from error


def latest_metadata(namespace, name):
    payload = json.loads(fetch(API_URL.format(namespace=namespace, name=name)))
    latest = payload.get("latest") or {}
    version = latest.get("version_number")
    if not version or not latest.get("is_active", True):
        raise RuntimeError(f"Thunderstore has no active release for {namespace}-{name}")
    return latest


def safe_members(archive, destination, preserve_existing_prefix=None):
    root = destination.resolve()
    for member in archive.infolist():
        relative = Path(member.filename)
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError(f"unsafe path in package archive: {member.filename}")
        if (
            preserve_existing_prefix
            and relative.parts[: len(preserve_existing_prefix)] == preserve_existing_prefix
            and (destination / relative).exists()
        ):
            continue
        target = (destination / relative).resolve()
        if target != root and root not in target.parents:
            raise RuntimeError(f"unsafe path in package archive: {member.filename}")
        yield member


class Installer:
    def __init__(self, game_dir):
        self.game_dir = game_dir.resolve()
        self.state_dir = self.game_dir / ".plutainer-thunderstore"
        self.state_file = self.state_dir / "packages.json"
        self.state = {}
        self.required = set()
        self.visiting = set()
        self.metadata_cache = {}
        if self.state_file.is_file():
            try:
                loaded = json.loads(self.state_file.read_text(encoding="utf-8"))
                if isinstance(loaded, dict) and isinstance(loaded.get("packages"), dict):
                    self.state = loaded["packages"]
                elif isinstance(loaded, dict):
                    # v1 stored only package -> version. Mark the dependency
                    # list unknown so an exact root is downloaded once to
                    # recover its manifest before managed-package pruning.
                    self.state = {
                        package_id: {"version": version, "dependencies": None}
                        for package_id, version in loaded.items()
                    }
            except (OSError, ValueError):
                self.state = {}

    def install(self, spec, dependency=False):
        namespace, name, version = split_spec(spec)
        namespace, name, resolved_metadata = self.resolve_name(namespace, name)
        package_id = f"{namespace}-{name}"
        self.required.add(package_id)
        follows_latest = version is None
        metadata = None
        if package_id in self.visiting:
            # Thunderstore permits mutually-declared packages (Nebula and its
            # compatibility helper currently form one). The outer install will
            # finish the package after this dependency walk unwinds.
            return

        if follows_latest:
            metadata = resolved_metadata
            version = metadata["version_number"]
        elif dependency:
            # Thunderstore manifests name the minimum dependency version that
            # was current when the parent was published. Mod managers update
            # dependencies independently, so current clients can legitimately
            # have a newer compatible patch (for example NCA 0.5.1 while
            # Nebula 0.9.22 declares 0.5.0). Match that behaviour while keeping
            # an explicitly requested top-level version pinned exactly.
            minimum = version
            metadata = resolved_metadata
            current = metadata["version_number"]
            if version_key(current) < version_key(minimum):
                raise RuntimeError(
                    f"{package_id}: latest {current} is older than required {minimum}"
                )
            version = current

        record = self.state.get(package_id) or {}
        installed = record.get("version")
        stored_dependencies = record.get("dependencies")
        if installed and self.package_present(namespace, name):
            if (
                installed == version
                or (dependency and version_key(installed) >= version_key(version))
            ) and (metadata is not None or isinstance(stored_dependencies, list)):
                print(f"[INFO] Thunderstore: {package_id} {installed} satisfies {version}.")
                # A top-level package following latest can remain at the same
                # version while one of its independently updateable
                # dependencies advances. Re-walk the dependency names from
                # Thunderstore metadata without downloading the unchanged
                # parent archive, matching normal mod-manager updates.
                dependencies = (
                    metadata.get("dependencies", [])
                    if metadata is not None
                    else stored_dependencies
                )
                if record.get("dependencies") != dependencies:
                    record["dependencies"] = dependencies
                    self.state[package_id] = record
                    self.save_state()
                self.visiting.add(package_id)
                try:
                    for child in dependencies:
                        self.install(child, dependency=True)
                finally:
                    self.visiting.remove(package_id)
                return

        self.visiting.add(package_id)
        print(f"[INFO] Thunderstore: downloading {package_id} {version}...")
        data = fetch(DOWNLOAD_URL.format(namespace=namespace, name=name, version=version))
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            try:
                manifest = json.loads(archive.read("manifest.json"))
            except (KeyError, ValueError) as error:
                raise RuntimeError(f"{package_id} {version} has no valid manifest.json") from error

            archive_version = manifest.get("version_number")
            if archive_version != version:
                raise RuntimeError(
                    f"{package_id}: requested {version}, archive reports {archive_version}"
                )

            dependencies = manifest.get("dependencies", [])
            for child in dependencies:
                self.install(child, dependency=True)

            self.extract(namespace, name, archive)

        self.visiting.remove(package_id)
        self.state[package_id] = {
            "version": version,
            "dependencies": dependencies,
        }
        self.save_state()
        print(f"[INFO] Thunderstore: installed {package_id} {version}.")

    def resolve_name(self, namespace, name):
        """Resolve ambiguous full names, including namespaces with hyphens."""
        full_name = f"{namespace}-{name}"
        candidates = [(namespace, name)]
        candidates.extend(
            (full_name[:index], full_name[index + 1 :])
            for index, character in reversed(list(enumerate(full_name)))
            if character == "-"
            and (full_name[:index], full_name[index + 1 :]) not in candidates
        )

        for candidate_namespace, candidate_name in candidates:
            if not (
                IDENTIFIER_RE.fullmatch(candidate_namespace)
                and IDENTIFIER_RE.fullmatch(candidate_name)
            ):
                continue
            cache_key = (candidate_namespace, candidate_name)
            try:
                if cache_key not in self.metadata_cache:
                    self.metadata_cache[cache_key] = latest_metadata(*cache_key)
                return candidate_namespace, candidate_name, self.metadata_cache[cache_key]
            except PackageNotFound:
                continue

        raise ValueError(
            f"Thunderstore package '{full_name}' was not found; "
            "use Owner/Package to disambiguate"
        )

    def prune(self):
        """Remove packages formerly managed as roots/dependencies but no longer used."""
        for package_id in sorted(set(self.state) - self.required):
            if package_id == "xiaoye97-BepInEx":
                continue
            target = self.game_dir / "BepInEx/plugins" / package_id
            if target.is_symlink() or target.is_file():
                target.unlink()
            elif target.exists():
                shutil.rmtree(target)
            del self.state[package_id]
            print(f"[INFO] Thunderstore: removed unused managed package {package_id}.")
        self.save_state()

    def package_present(self, namespace, name):
        if namespace == "xiaoye97" and name == "BepInEx":
            return (self.game_dir / "BepInEx/core/BepInEx.dll").is_file()
        return (self.game_dir / "BepInEx/plugins" / f"{namespace}-{name}").is_dir()

    def extract(self, namespace, name, archive):
        if namespace == "xiaoye97" and name == "BepInEx":
            # BepInEx is the one Thunderstore package whose archive is rooted at
            # the game directory, inside a BepInExPack/ wrapper. Strip that
            # wrapper, and preserve an existing config: after first boot
            # BepInEx/config is a link to the user's app/configs directory.
            names = [Path(member.filename) for member in archive.infolist()]
            wrapped = any(path.parts[:2] == ("BepInExPack", "BepInEx") for path in names)
            for member in archive.infolist():
                relative = Path(member.filename)
                if wrapped:
                    if not relative.parts or relative.parts[0] != "BepInExPack":
                        continue
                    relative = Path(*relative.parts[1:])
                elif not relative.parts or relative.parts[0] not in (
                    "BepInEx",
                    "doorstop_config.ini",
                    "winhttp.dll",
                ):
                    continue
                if not relative.parts:
                    continue
                self.extract_one(archive, member, relative, preserve_config=True)
            return

        plugins = self.game_dir / "BepInEx/plugins"
        target = plugins / f"{namespace}-{name}"
        plugins.mkdir(parents=True, exist_ok=True)
        if target.is_symlink() or target.is_file():
            target.unlink()
        elif target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        archive.extractall(target, members=safe_members(archive, target))

    def extract_one(self, archive, member, relative, preserve_config=False):
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError(f"unsafe path in package archive: {member.filename}")
        target = self.game_dir / relative
        if (
            preserve_config
            and relative.parts[:2] == ("BepInEx", "config")
            and target.exists()
        ):
            return
        root = self.game_dir.resolve()
        resolved = target.resolve()
        if resolved != root and root not in resolved.parents:
            raise RuntimeError(f"unsafe path in package archive: {member.filename}")
        if member.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink():
            target.unlink()
        with archive.open(member) as source, open(target, "wb") as destination:
            shutil.copyfileobj(source, destination)

    def save_state(self):
        self.state_dir.mkdir(parents=True, exist_ok=True)
        temporary = self.state_file.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(
                {"format": 2, "packages": self.state}, indent=2, sort_keys=True
            )
            + "\n",
            encoding="utf-8",
        )
        temporary.replace(self.state_file)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-dir", required=True, type=Path)
    parser.add_argument("package", nargs="+")
    args = parser.parse_args()

    # Validate all user syntax before touching an existing installation.
    roots = []
    seen = set()
    for package in args.package:
        namespace, name, version = split_spec(package)
        root_id = f"{namespace}-{name}"
        if root_id in seen:
            raise ValueError(f"duplicate top-level package '{root_id}'")
        seen.add(root_id)
        roots.append(package)

    args.game_dir.mkdir(parents=True, exist_ok=True)
    installer = Installer(args.game_dir)
    for package in roots:
        installer.install(package)
    installer.prune()


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        print(f"[ERROR] Invalid Thunderstore package setting: {error}", file=sys.stderr)
        sys.exit(2)
    except Exception as error:
        print(f"[ERROR] Thunderstore install failed: {error}", file=sys.stderr)
        sys.exit(1)
