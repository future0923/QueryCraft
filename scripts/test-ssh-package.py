#!/usr/bin/env python3
"""Validate the actual native SSH distribution ZIP in an isolated runtime directory."""
import argparse
import base64
import ctypes
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    arch = platform.machine()
    metadata = json.loads((ROOT / 'Components/versions.json').read_text())['ssh']
    archives = list(args.directory.glob(f'querycraft-ssh-*-{arch}.zip'))
    assert len(archives) == 1, 'Expected exactly one native SSH archive'
    archive = archives[0]
    module('ssh_catalog', ROOT / 'scripts/package-ssh-catalog.py').inspect_package(archive, arch, metadata)
    record = json.loads(archive.with_suffix('.release.json').read_text())
    release = json.loads(base64.b64decode(record['payload'], validate=True))
    assert len(base64.b64decode(record['signature'], validate=True)) == 64
    assert release['sha256'] == hashlib.sha256(archive.read_bytes()).hexdigest()
    assert release['size'] == archive.stat().st_size
    assert {k:v for k,v in release.items() if k not in ('url','size','sha256')} == dict(metadata, component='ssh', architectures=[arch])
    with tempfile.TemporaryDirectory(prefix='qc-ssh-package-') as temporary:
        subprocess.run(['ditto','-x','-k',str(archive),temporary],check=True)
        bundle = Path(temporary) / 'QueryCraftSSH.bundle'
        module('signer', ROOT / 'scripts/code-signing.py').verify(bundle)
        binary = bundle / 'Contents/MacOS/QueryCraftSSH'
        assert subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip() == arch
        for line in subprocess.check_output(['otool','-L',str(binary)],text=True).splitlines()[1:]:
            dependency = line.strip().split(' (',1)[0]
            assert dependency == '@rpath/QueryCraftSSH' or dependency.startswith(('/usr/lib/','/System/Library/')), dependency
        library = ctypes.CDLL(str(binary))
        for name in ['version','file_version','file_management_version','pool_version','progress_version','route_version','diagnostic_version']:
            function = getattr(library, 'querycraft_ssh_plugin_' + name)
            function.restype = ctypes.c_uint32
            assert function() == 1, name
        for name in ['create','run','cancel','destroy','file_create','pool_create','pool_run','pool_invalidate','pool_prune','pool_destroy','set_progress','set_route','diagnostic']:
            assert getattr(library,'querycraft_ssh_plugin_'+name)
    print(f'PASS {arch}: signed SSH package identity, native load, ABI/capabilities and self-contained dependencies')

if __name__ == '__main__': main()
