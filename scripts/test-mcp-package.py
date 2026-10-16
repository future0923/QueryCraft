#!/usr/bin/env python3
"""Verify a relocated MCP bundle, protocol transports and optional isolated driver loading."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True, timeout=90, **kwargs)

def verify(app, drivers=None, previous_drivers=None):
    run(['codesign', '--verify', '--deep', '--strict', app])
    with tempfile.TemporaryDirectory(prefix='querycraft-mcp-relocated-') as temporary:
        root = Path(temporary)
        relocated = root / 'Moved App With Spaces.app'
        shutil.copytree(app, relocated, symlinks=True)
        binary = relocated / 'Contents/MacOS/querycraft-mcp'
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('DYLD_', 'SWIFT_','PACKAGE_RESOURCE_'))}
        result = run([binary, '--self-test'], cwd=root, env=dict(env, DYLD_PRINT_LIBRARIES='1'))
        assert 'MCP handshake OK' in result.stdout
        for line in result.stderr.splitlines():
            if line.startswith('dyld[') and '> /' in line:
                path = line.split('> ', 1)[1]
                assert path.startswith(('/System/', '/usr/lib/', str(root), str(root.resolve()))), path
        helper = relocated / 'Contents/Helpers/QueryCraft Credentials.app/Contents/MacOS/QueryCraftCredentials'
        rejected = subprocess.run([str(helper)], input='', capture_output=True, text=True, timeout=10, env=env)
        assert rejected.returncode == 77, 'Credential helper accepted an unrelated caller'
        shared = relocated / 'Contents/Helpers/QueryCraft Shared Credentials.app/Contents/MacOS/QueryCraftCredentials'
        rejected = subprocess.run([str(shared)], input='', capture_output=True, text=True, timeout=10, env=env)
        assert rejected.returncode == 77, 'Shared credential helper accepted an unrelated caller'
        assert run([binary, '--credential-protocol'], env=env).stdout.strip() == '2'
        print('PASS relocated signature, SQL resources, handshake, library paths and helper caller rejection')
        protocol = run(['python3', ROOT/'scripts/test-mcp-protocol.py', binary], cwd=root, env=env)
        print(protocol.stdout.strip())
        if drivers:
            storage = root/'Data'
            sample = next(drivers.glob('*.querycraftdriver'))
            api = plistlib.loads((sample/'Contents/Info.plist').read_bytes())['QCDriverAPIVersion']
            destination = storage/f'DriverAPI-{api}'/'Drivers'; destination.mkdir(parents=True)
            for source in drivers.glob('*.querycraftdriver'):
                shutil.copytree(source, destination/source.name, symlinks=True)
            checked = run([binary, '--check-drivers', '--data-dir', storage], cwd=root, env=env)
            assert 'is implemented in both' not in checked.stderr, checked.stderr
            loaded = json.loads(checked.stdout)
            expected = ['doris', 'elasticsearch', 'kafka', 'mysql', 'postgresql', 'redis']
            assert sorted(loaded) == expected, f'Driver loading mismatch: {loaded}'
            print('PASS six API 5 drivers loaded from relocated standalone runtime: '+', '.join(loaded))
            for kind in ['MySQL', 'Doris']:
                solo = root / ('Solo-' + kind)
                source = next(drivers.glob(kind + '-*.querycraftdriver'))
                target = solo / f'DriverAPI-{api}' / 'Drivers' / source.name
                shutil.copytree(source, target, symlinks=True)
                checked = run([binary, '--check-drivers', '--data-dir', solo], cwd=root, env=env)
                assert json.loads(checked.stdout) == [kind.lower()], checked.stderr
                assert 'is implemented in both' not in checked.stderr, checked.stderr
            print('PASS MySQL and Doris each load independently with packaged transport')
            if previous_drivers:
                for updated, previous in [('MySQL', 'Doris'), ('Doris', 'MySQL')]:
                    mixed = root / ('Mixed-' + updated)
                    for kind, catalog in [(updated, drivers), (previous, previous_drivers)]:
                        source = next(catalog.glob(kind + '-*.querycraftdriver'))
                        shutil.copytree(source, mixed / f'DriverAPI-{api}' / 'Drivers' / source.name, symlinks=True)
                    checked = run([binary, '--check-drivers', '--data-dir', mixed], cwd=root, env=env)
                    assert json.loads(checked.stdout) == ['doris', 'mysql'], checked.stderr
                    assert 'is implemented in both' not in checked.stderr, checked.stderr
                print('PASS independent MySQL/Doris upgrades coexist with previous static transport drivers')


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--drivers-dir', type=Path)
    parser.add_argument('--previous-drivers-dir', type=Path)
    args=parser.parse_args()
    verify(args.app.resolve(), args.drivers_dir.resolve() if args.drivers_dir else None, args.previous_drivers_dir.resolve() if args.previous_drivers_dir else None)
