#!/usr/bin/env python3
"""Check the structural/signing gates of a Mac App Store candidate. Never uploads."""
import argparse
import json
import plistlib
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from importlib.util import module_from_spec, spec_from_file_location

_spec = spec_from_file_location('store_components', Path(__file__).with_name('embed-store-components.py'))
_components = module_from_spec(_spec)
_spec.loader.exec_module(_components)

DRIVERS = {'mysql', 'postgresql', 'doris', 'redis', 'elasticsearch', 'kafka', 'milvus'}


def read_info(bundle):
    return plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())


def dependency_errors(app, executable, roots, architectures):
    """Follow dyld load commands per slice, including architecture-only leaves."""
    errors, seen = [], set()
    def expand(value, binary):
        return value.replace('@loader_path', str(binary.parent)).replace('@executable_path', str(executable.parent))
    def visit(binary, architecture, inherited):
        binary = binary.resolve()
        key = (binary, architecture)
        if key in seen:
            return
        seen.add(key)
        if not binary.is_file():
            errors.append(f'Missing dependency: {binary}')
            return
        actual = subprocess.run(['lipo', '-archs', str(binary)], capture_output=True, text=True)
        if architecture not in actual.stdout.split():
            errors.append(f'Missing {architecture} slice: {binary.relative_to(app.resolve())}')
            return
        commands = subprocess.run(['otool', '-arch', architecture, '-l', str(binary)], capture_output=True, text=True).stdout.splitlines()
        paths = []
        for index, line in enumerate(commands):
            if line.strip() == 'cmd LC_RPATH':
                value = commands[index + 2].strip().removeprefix('path ').split(' (offset', 1)[0]
                paths.append(expand(value, binary))
        paths += inherited
        dependencies = []
        for index, line in enumerate(commands):
            if line.strip() in {'cmd LC_LOAD_DYLIB', 'cmd LC_LOAD_WEAK_DYLIB', 'cmd LC_REEXPORT_DYLIB', 'cmd LC_LOAD_UPWARD_DYLIB', 'cmd LC_LAZY_LOAD_DYLIB'}:
                dependencies.append(commands[index + 2].strip().removeprefix('name ').split(' (offset', 1)[0])
        for library in dependencies:
            if library.startswith(('/usr/lib/', '/System/Library/')):
                continue
            if library.startswith('@rpath/'):
                suffix = library.removeprefix('@rpath/')
                candidates = [Path(p) / suffix for p in paths]
                # Swift runtime libraries can reside solely in the dyld cache.
                if suffix.startswith('libswift') and any(str(p).startswith('/usr/lib/swift/') for p in candidates):
                    continue
            else:
                candidates = [Path(expand(library, binary))]
            resolved = next((p for p in candidates if p.is_file()), None)
            if resolved is None or not resolved.resolve().is_relative_to(app.resolve()):
                errors.append(f'Unresolved {architecture} dependency in {binary.name}: {library}')
                continue
            visit(resolved, architecture, paths)
    for architecture in architectures:
        for root in roots:
            visit(root, architecture, [str(executable.parent / '../Frameworks'), '/usr/lib/swift'])
    return errors


def check(app, signed=True, architectures=None):
    info = read_info(app)
    errors = []
    for key, expected in {
        'QCDistributionChannel': 'appStore',
        'QCCloudSyncBillingMode': 'appStore',
        'CFBundleIdentifier': 'io.github.future0923.QueryCraft.Mobile',
        'QCCredentialHelperRequired': False,
        'QCSharedCredentialHelperRequired': False,
    }.items():
        if info.get(key) != expected:
            errors.append(f'{key} must equal {expected!r}')
    if any(key.startswith('SU') for key in info):
        errors.append('Sparkle configuration remains in the app')
    if not info.get('QCMCPVersion'):
        errors.append('Embedded MCP version is missing')
    if any('sparkle' in p.name.lower() for p in app.rglob('*')):
        errors.append('Sparkle files remain in the app')
    if list(app.rglob('*.storekit')):
        errors.append('Test StoreKit products must not ship')
    installed = set()
    for driver in (app / 'Contents/PlugIns/Drivers').glob('*.querycraftdriver'):
        metadata = read_info(driver)
        kind = metadata.get('QCDriverDatabaseType')
        if kind in installed:
            errors.append(f'Duplicate bundled driver: {kind}')
        installed.add(kind)
        if metadata.get('QCDriverAPIVersion') != 5:
            errors.append(f'Incompatible driver API: {driver.name}')
    if installed != DRIVERS:
        errors.append(f'Bundled driver set differs: {sorted(DRIVERS - installed)} missing')
    ssh = app / 'Contents/PlugIns/QueryCraftSSH.bundle'
    if not (ssh / 'Contents/PlugIns/TerminalRenderer.bundle').is_dir():
        errors.append('SSH plugin or terminal renderer is missing')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    expected_architectures = set(architectures or (['arm64', 'x86_64'] if signed else []))
    for binary in app.rglob('*'):
        if not _components.is_macho(binary):
            continue
        relative = str(binary.relative_to(app))
        arch = subprocess.run(['lipo', '-archs', str(binary)], capture_output=True, text=True)
        if arch.returncode or (expected_architectures and not expected_architectures.intersection(arch.stdout.split())):
            errors.append(f'Missing requested architecture in {relative}')
        dependencies = subprocess.run(['otool', '-L', str(binary)], capture_output=True, text=True)
        for line in dependencies.stdout.splitlines():
            if not line.startswith('\t'):
                continue
            library = line.strip().split(' (compatibility version', 1)[0]
            if not library.startswith(('@', '/System/Library/', '/usr/lib/')):
                errors.append(f'Nonportable dependency in {relative}: {library}')
    roots = [executable]
    for metadata in (app / 'Contents/PlugIns').rglob('Contents/Info.plist'):
        entry = plistlib.loads(metadata.read_bytes())
        if entry.get('CFBundleExecutable'):
            roots.append(metadata.parent / 'MacOS' / entry['CFBundleExecutable'])
    errors.extend(dependency_errors(app, executable, roots, expected_architectures))
    for binary in [executable, app / 'Contents/Frameworks/QueryCraftFeature.framework/QueryCraftFeature']:
        result = subprocess.run(['otool', '-L', str(binary)], capture_output=True, text=True)
        if result.returncode or 'Sparkle.framework' in result.stdout:
            errors.append(f'Invalid dependency closure: {binary.name}')
    if signed:
        result = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], capture_output=True, text=True)
        if result.returncode:
            errors.append('Strict signature validation failed')
        result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True)
        try:
            ent = plistlib.loads(result.stdout)
            if ent.get('com.apple.security.app-sandbox') is not True:
                errors.append('App Sandbox entitlement is absent')
            if ent.get('com.apple.security.get-task-allow') is True:
                errors.append('Debug task access must not ship')
            if ent.get('com.apple.security.cs.disable-library-validation') is True:
                errors.append('Library Validation must remain enabled')
            if ent.get('com.apple.developer.icloud-container-environment') != 'Production':
                errors.append('CloudKit must use Production')
            if ent.get('com.apple.developer.team-identifier') != '5975A7N3W3':
                errors.append('Unexpected Apple team')
        except plistlib.InvalidFileException:
            errors.append('Cannot read signing entitlements')
        if not (app / 'Contents/embedded.provisionprofile').is_file():
            errors.append('App Store provisioning profile is absent')
        else:
            profile = subprocess.run(['security', 'cms', '-D', '-i', str(app / 'Contents/embedded.provisionprofile')], capture_output=True)
            try:
                value = plistlib.loads(profile.stdout)
                if value.get('ProvisionedDevices') or value.get('ProvisionsAllDevices'):
                    errors.append('Provisioning profile is not for App Store distribution')
                expiration = value.get('ExpirationDate')
                if not expiration or expiration.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
                    errors.append('Provisioning profile is expired or has no expiration')
                if value.get('TeamIdentifier') != ['5975A7N3W3']:
                    errors.append('Provisioning profile team mismatch')
            except plistlib.InvalidFileException:
                errors.append('Cannot decode provisioning profile')
    return errors


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--unsigned-build', action='store_true', help='Structural checks only; not a release acceptance')
    parser.add_argument('--architectures', nargs='+', choices=['arm64', 'x86_64'], help='Defaults to both architectures for release checks')
    args = parser.parse_args()
    failures = check(args.app, signed=not args.unsigned_build, architectures=args.architectures)
    print(json.dumps({'passed': not failures, 'signed_checks': not args.unsigned_build, 'errors': failures}, ensure_ascii=False, indent=2))
    raise SystemExit(bool(failures))
