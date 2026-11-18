#!/usr/bin/env python3
"""Embed already verified native components in a Store build before Xcode signs it.

QC_STORE_COMPONENTS_DIR must contain Drivers/*.querycraftdriver and
QueryCraftSSH.bundle. Fetch/build components separately; this build step never
fetches executable code. It fails closed on missing drivers or wrong signatures.
"""
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = {'mysql', 'postgresql', 'doris', 'redis', 'elasticsearch', 'kafka', 'milvus'}
TRUST = '=anchor apple generic and certificate leaf[subject.OU] = "5975A7N3W3"'
MACHO_MAGIC = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
               b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def is_macho(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open('rb') as stream:
        return stream.read(4) in MACHO_MAGIC


def remove_build_rpaths(app, identity):
    """Make signed Debug probes exercise bundled frameworks, not DerivedData.

    Xcode adds its PackageFrameworks directory to development load commands. A
    Store candidate must also work after being moved away from the build tree.
    Only that build-output prefix is removed; missing dependencies still fail
    the final dependency-closure gate.
    """
    changed = False
    prefix = str(app.parent.resolve()) + '/'
    for binary in app.rglob('*'):
        if not is_macho(binary):
            continue
        if not binary.resolve().is_relative_to(app.resolve()):
            raise ValueError('Embedded code resolves outside the app: ' + str(binary))
        lines = run('otool', '-l', binary).decode().splitlines()
        paths = set()
        for index, line in enumerate(lines):
            if line.strip() == 'cmd LC_RPATH':
                path = lines[index + 2].strip().removeprefix('path ').split(' (offset', 1)[0]
                if path.startswith(prefix):
                    paths.add(path)
        for path in paths:
            run('install_name_tool', '-delete_rpath', path, binary)
            changed = True
    if changed and identity:
        code = [p for p in app.rglob('*') if not p.is_symlink() and
                p.suffix in {'.dylib', '.so', '.framework', '.bundle', '.querycraftdriver'}]
        for item in sorted(code, key=lambda p: len(p.parts), reverse=True):
            run('codesign', '--force', '--sign', identity, '--timestamp=none', item)


def run(*args):
    return subprocess.check_output(list(map(str, args)), stderr=subprocess.STDOUT)


def embed(source, app, architectures, identity=None):
    source = source.resolve()
    drivers = list((source / 'Drivers').glob('*.querycraftdriver'))
    found = set()
    for bundle in drivers:
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        kind = info.get('QCDriverDatabaseType')
        if kind in found or info.get('QCDriverAPIVersion') != 5:
            raise ValueError('Duplicate driver or incompatible Driver API')
        found.add(kind)
    if found != REQUIRED:
        raise ValueError('All seven reviewed drivers are required: ' + ', '.join(sorted(REQUIRED - found)))
    ssh = source / 'QueryCraftSSH.bundle'
    if not (ssh / 'Contents/PlugIns/TerminalRenderer.bundle').is_dir():
        raise ValueError('SSH plugin and terminal renderer are required')
    bundles = drivers + [ssh]
    for bundle in bundles:
        run('codesign', '--verify', '--deep', '--strict', '-R', TRUST, bundle)
        for binary in bundle.rglob('*'):
            if is_macho(binary) and not architectures.intersection(run('lipo', '-archs', binary).decode().split()):
                raise ValueError('No requested architecture in nested code: ' + str(binary))
        for metadata in bundle.rglob('Contents/Info.plist'):
            info = plistlib.loads(metadata.read_bytes())
            if executable := info.get('CFBundleExecutable'):
                binary = metadata.parent / 'MacOS' / executable
                if binary.is_file() and not architectures <= set(run('lipo', '-archs', binary).decode().split()):
                    raise ValueError('Missing requested architecture: ' + str(binary))
    app.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='store-components-', dir=app.parent) as temporary:
        staging = Path(temporary) / 'PlugIns'
        (staging / 'Drivers').mkdir(parents=True)
        for driver in drivers:
            shutil.copytree(driver, staging / 'Drivers' / driver.name, symlinks=True)
        shutil.copytree(ssh, staging / ssh.name, symlinks=True)
        if identity:
            code = [p for p in staging.rglob('*') if not p.is_symlink() and
                    (p.suffix in {'.dylib', '.so', '.framework', '.bundle', '.querycraftdriver'})]
            for item in sorted(code, key=lambda p: len(p.parts), reverse=True):
                run('codesign', '--force', '--sign', identity, '--timestamp=none', item)
        destination = app / 'Contents/PlugIns'
        destination.mkdir(parents=True, exist_ok=True)
        for name in ['Drivers', 'QueryCraftSSH.bundle']:
            existing = destination / name
            if existing.exists():
                shutil.rmtree(existing)
            shutil.move(str(staging / name), existing)
    print('Embedded seven database drivers and SSH in the App Store build')


if __name__ == '__main__':
    source = os.environ.get('QC_STORE_COMPONENTS_DIR')
    if not source:
        raise SystemExit('QC_STORE_COMPONENTS_DIR is required; see QueryCraftStore/README.md')
    app = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['WRAPPER_NAME']
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') if os.environ.get('CODE_SIGNING_ALLOWED') != 'NO' else None
    embed(Path(source), app, set(os.environ['ARCHS'].split()), identity)
    remove_build_rpaths(app, identity)
