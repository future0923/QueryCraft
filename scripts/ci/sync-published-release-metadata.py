#!/usr/bin/env python3
"""Use the resource server's canonical URLs in GitHub release metadata."""

import json
import os
from pathlib import Path
import sys
from urllib.request import urlopen


def download(url):
    with urlopen(url, timeout=60) as response:
        return response.read()


def main():
    directory = Path(sys.argv[1])
    base = os.environ.get(
        "QUERYCRAFT_UPDATE_BASE_URL", "https://querycraft.debug-tools.cc"
    ).rstrip("/")
    if not base.startswith("https://"):
        raise ValueError("The resource server must use HTTPS")
    updates = {}
    if os.environ.get("QUERYCRAFT_DEPLOY_CLIENT", "true") == "true":
        path = directory / "appcast.xml"
        import importlib.util
        import tempfile
        spec = importlib.util.spec_from_file_location("update_archives", Path(__file__).resolve().parents[1] / "update-archives.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.validate_feed(directory, path, base)
        data = download(base + "/appcast.xml")
        with tempfile.TemporaryDirectory() as temporary:
            remote = Path(temporary) / "appcast.xml"
            remote.write_bytes(data)
            module.validate_feed(directory, remote, base, canonical=True)
        updates[path] = data
    if os.environ.get("QUERYCRAFT_DEPLOY_DRIVERS", "true") == "true":
        all_databases = ("mysql", "postgresql", "doris", "redis", "elasticsearch", "kafka")
        requested = os.environ.get("QUERYCRAFT_DEPLOY_DRIVER_TYPES", "").strip()
        databases = all_databases if not requested or requested == "none" else tuple(
            item.strip() for item in requested.split(",") if item.strip()
        )
        unknown = set(databases) - set(all_databases)
        if unknown:
            raise ValueError(f"Invalid driver selection: {', '.join(sorted(unknown))}")
        for database in databases:
            for architecture in ("x86_64", "arm64"):
                path = directory / f"{database}-{architecture}.json"
                expected = json.loads(path.read_text())
                catalog = json.loads(download(base + "/drivers/" + path.name))
                if (catalog["schemaVersion"] != 2
                    or catalog["databaseType"] != database
                    or catalog["architecture"] != architecture):
                    raise ValueError(f"Invalid published catalog: {path.name}")
                actual = next(
                    release for release in catalog["releases"]
                    if all(release.get(key) == value for key, value in expected.items()
                           if key != "downloadURL")
                )
                if not actual["downloadURL"].startswith(base + "/drivers/"):
                    raise ValueError(f"Invalid published download URL: {path.name}")
                updates[path] = (json.dumps(actual, indent=2) + "\n").encode()
    for path, data in updates.items():
        path.write_bytes(data)
    print(f"Synchronized {len(updates)} published metadata files")


if __name__ == "__main__":
    main()
