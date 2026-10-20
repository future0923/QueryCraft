#!/usr/bin/env python3
"""Check the native MCP release against all six current and previous drivers."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
KINDS = ['mysql', 'postgresql', 'doris', 'redis', 'elasticsearch', 'kafka']


def identity(record):
    return tuple(map(int, record['version'].split('.'))), int(record['build'])


def extract_driver(blob, record, destination):
    assert len(blob) == record['downloadSize'], 'Driver size mismatch'
    assert hashlib.sha256(blob).hexdigest() == record['sha256'], 'Driver digest mismatch'
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix='.zip') as archive:
        archive.write(blob)
        archive.flush()
        subprocess.run(['ditto', '-x', '-k', archive.name, str(destination)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifacts', type=Path)
    args = parser.parse_args()
    artifacts = args.artifacts.resolve()
    arch = platform.machine()
    assert arch in ['arm64', 'x86_64'], arch
    with tempfile.TemporaryDirectory(prefix='qc-release-runtime-') as temporary:
        work = Path(temporary)
        previous = work / 'previous'
        current = work / 'current'
        previous.mkdir()
        for kind in KINDS:
            url = f'https://querycraft.debug-tools.cc/drivers/{kind}-{arch}.json'
            with urllib.request.urlopen(url, timeout=60) as response:
                catalog = json.load(response)
            records = catalog.get('releases', [catalog])
            record = max((r for r in records if r['driverAPIVersion'] == 5
                          and arch in r['supportedArchitectures']), key=identity)
            with urllib.request.urlopen(record['downloadURL'], timeout=120) as response:
                blob = response.read()
            extract_driver(blob, record, previous)
        shutil.copytree(previous, current)
        for kind in KINDS:
            manifests = list(artifacts.rglob(f'{kind}-{arch}.json'))
            assert len(manifests) <= 1, manifests
            if not manifests:
                continue
            record = json.loads(manifests[0].read_text())
            assert record['databaseType'] == kind and arch in record['supportedArchitectures']
            archives = list(artifacts.rglob(Path(record['downloadURL']).name))
            assert len(archives) == 1, archives
            replacement = work / kind
            extract_driver(archives[0].read_bytes(), record, replacement)
            bundles = list(replacement.glob('*.querycraftdriver'))
            assert len(bundles) == 1, bundles
            target = current / bundles[0].name
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(bundles[0], target, symlinks=True)
        archives = list(artifacts.rglob(f'querycraft-mcp-*-{arch}.zip'))
        assert len(archives) == 1, archives
        subprocess.run(['ditto', '-x', '-k', str(archives[0]), str(work / 'mcp')], check=True)
        apps = list((work / 'mcp').rglob('QueryCraft MCP.app'))
        assert len(apps) == 1, apps
        subprocess.run([sys.executable, str(ROOT / 'scripts/test-mcp-package.py'), str(apps[0]),
                        '--drivers-dir', str(current), '--previous-drivers-dir', str(previous)], check=True)
        print(f'PASS {arch}: packaged MCP and six drivers, including independent MySQL/Doris upgrades')


if __name__ == '__main__':
    main()
