#!/usr/bin/env python3
"""Use the resource server's canonical URLs in GitHub release metadata."""

import json
import os
from pathlib import Path
import sys
from urllib.request import urlopen
import xml.etree.ElementTree as ET


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
        ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
        expected = ET.parse(path).find("./channel/item")
        data = download(base + "/appcast.xml")
        actual = next(
            item for item in ET.fromstring(data).findall("./channel/item")
            if all(item.findtext(key, namespaces=ns)
                   == expected.findtext(key, namespaces=ns)
                   for key in ("s:version", "s:shortVersionString"))
        )
        for key in ("length", "{" + ns["s"] + "}edSignature"):
            if not expected.find("enclosure").get(key) or (
                actual.find("enclosure").get(key) != expected.find("enclosure").get(key)
            ):
                raise ValueError("Published update archive metadata does not match")
        updates[path] = data
    if os.environ.get("QUERYCRAFT_DEPLOY_DRIVERS", "true") == "true":
        for database in ("mysql", "postgresql", "doris", "redis", "elasticsearch", "kafka"):
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
