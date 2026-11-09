#!/usr/bin/env python3
"""Developer ID signing. Private keys stay outside git; no signing fallback."""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import subprocess
import tempfile
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
DIRECTORY = Path(os.environ.get('QUERYCRAFT_SIGNING_DIRECTORY',
    str(Path.home() / 'Library/Application Support/QueryCraftDeveloperID'))).expanduser().resolve()
KEYCHAIN = Path(os.environ.get('QUERYCRAFT_SIGNING_KEYCHAIN',
    str(DIRECTORY / 'signing.keychain-db' if os.environ.get('CI') == 'true'
        else Path.home() / 'Library/Keychains/login.keychain-db'))).expanduser()


def run(*args, input=None):
    result = subprocess.run(list(map(str, args)), input=input, capture_output=True)
    if result.returncode:
        # Arguments can contain passwords. Never log them.
        raise RuntimeError(f'{args[0]} failed: {result.stderr.decode().strip()}')
    return result.stdout


def configuration():
    value = json.loads((ROOT / 'Config/DeveloperID.json').read_text())
    if not re.fullmatch(r'[A-F0-9]{40}', value['identity']) or not re.fullmatch(r'[A-Z0-9]{10}', value['teamID']):
        raise RuntimeError('Invalid Developer ID configuration.')
    return value


def expected_identity():
    return configuration()['identity']


def validate_release():
    def version(value):
        if not re.fullmatch(r'\d+\.\d+\.\d+', value):
            raise RuntimeError('Release versions must use major.minor.patch.')
        return tuple(map(int, value.split('.')))
    legacy = version(configuration()['lastLegacyAppVersion'])
    shared = (ROOT / 'Config/Shared.xcconfig').read_text()
    current = re.search(r'^MARKETING_VERSION\s*=\s*(\S+)', shared, re.MULTILINE)
    if not current or version(current[1]) <= legacy:
        raise RuntimeError('Developer ID release needs a new app version after the legacy channel.')
    metadata = json.loads((ROOT / 'Components/versions.json').read_text())
    for kind in ('mcp', 'ssh'):
        if os.environ.get('QUERYCRAFT_BUILD_' + kind.upper()) == 'true' and version(metadata[kind]['minimumAppVersion']) <= legacy:
            raise RuntimeError(kind + ': minimumAppVersion must exclude legacy self-signed hosts.')
    print('Developer ID release compatibility boundary verified.')


def team_requirement():
    return ('anchor apple generic and certificate leaf[subject.OU] = "' + configuration()['teamID']
            + '" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')


def helper_source():
    source = (ROOT / 'CredentialHelper/main.swift').read_text()
    source = source.replace('__PINNED_CERTIFICATE_SHA1__', expected_identity())
    source = source.replace('certificate leaf = H\\"\\(certificate)\\"',
                            team_requirement().replace('"', '\\"'))
    # Old and paid shared helpers must lock the same vault during coexistence.
    return source.replace('Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "vault.lock")',
        'Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appending(path: "vault.lock")')


def search_list():
    return shlex.split(run('security', 'list-keychains', '-d', 'user').decode())


def activate():
    if os.environ.get('CI') == 'true':
        password = (DIRECTORY / 'keychain-password').read_text().strip()
        run('security', 'unlock-keychain', '-p', password, KEYCHAIN)
    identities = run('security', 'find-identity', '-v', '-p', 'codesigning', KEYCHAIN).decode()
    config = configuration()
    if not any(config['identity'] in line and '"' + config['name'] + '"' in line for line in identities.splitlines()):
        raise RuntimeError('Configured Developer ID certificate/private key unavailable. Import the existing identity; no fallback is allowed.')
    return config['identity']


def provision(from_ci):
    if not from_ci:
        print('Using installed Developer ID: ' + activate())
        return
    if os.environ.get('CI') != 'true' or 'QUERYCRAFT_SIGNING_DIRECTORY' not in os.environ:
        raise RuntimeError('CI import requires CI=true and an explicit temporary signing directory.')
    for name in ('QUERYCRAFT_DEVELOPER_ID_P12_BASE64', 'QUERYCRAFT_DEVELOPER_ID_P12_PASSWORD'):
        if not os.environ.get(name):
            raise RuntimeError('Required Actions secret missing: ' + name)
    if KEYCHAIN.exists():
        print('Using imported Developer ID: ' + activate())
        return
    DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    DIRECTORY.chmod(0o700)
    previous = search_list()
    (DIRECTORY / 'previous-keychains.json').write_text(json.dumps(previous))
    password = secrets.token_hex(32)
    (DIRECTORY / 'keychain-password').write_text(password)
    p12 = DIRECTORY / 'identity.p12'
    try:
        p12.write_bytes(base64.b64decode(os.environ['QUERYCRAFT_DEVELOPER_ID_P12_BASE64'], validate=True))
        run('security', 'create-keychain', '-p', password, KEYCHAIN)
        run('security', 'unlock-keychain', '-p', password, KEYCHAIN)
        run('security', 'set-keychain-settings', '-lut', '21600', KEYCHAIN)
        run('security', 'import', p12, '-k', KEYCHAIN,
            '-P', os.environ['QUERYCRAFT_DEVELOPER_ID_P12_PASSWORD'], '-T', '/usr/bin/codesign')
        run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, KEYCHAIN)
        run('security', 'list-keychains', '-d', 'user', '-s', *previous, KEYCHAIN)
        print('Developer ID ready: ' + activate())
    finally:
        p12.unlink(missing_ok=True)


def sign_code(path, *, entitlements=None, identifier=None, runtime=True):
    if not runtime:
        raise RuntimeError('Developer ID code must enable Hardened Runtime.')
    args = ['codesign', '--force', '--sign', activate(), '--keychain', KEYCHAIN,
            '--timestamp', '--options', 'runtime']
    if entitlements:
        args += ['--entitlements', entitlements]
    if identifier:
        args += ['--identifier', identifier]
    run(*args, path)


def sign_sparkle(framework):
    """Sign Sparkle from the inside out; binary SPM payloads can be ad-hoc.

    Keep functional entitlements, not Xcode's old identity/debug entitlements.
    Never use codesign --deep to sign or disable host library validation.
    """
    framework = Path(framework)
    if not framework.exists():
        return
    version = (framework / 'Versions/Current').resolve(strict=True)
    if not version.is_relative_to(framework.resolve()):
        raise RuntimeError('Sparkle version link escapes its framework.')
    nested = [version / 'Autoupdate', *version.rglob('*.app'), *version.rglob('*.xpc')]
    for path in sorted(nested, key=lambda p: len(p.parts), reverse=True):
        if not path.exists():
            raise RuntimeError('Incomplete Sparkle framework: ' + str(path))
        entitlements = run('codesign', '-d', '--entitlements', ':-', path)
        values = plistlib.loads(entitlements) if entitlements else {}
        for key in ('com.apple.application-identifier', 'application-identifier',
                    'com.apple.developer.team-identifier', 'com.apple.security.get-task-allow'):
            values.pop(key, None)
        details = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], capture_output=True, check=True).stderr.decode()
        identifier = next(line.split('=', 1)[1] for line in details.splitlines() if line.startswith('Identifier='))
        with tempfile.TemporaryDirectory(prefix='qc-sparkle-entitlements-') as temporary:
            plist = Path(temporary) / 'entitlements.plist'
            plist.write_bytes(plistlib.dumps(values))
            sign_code(path, entitlements=plist, identifier=identifier)
        verify(path)
    sign_code(framework)
    verify(framework)


def verify(path):
    requirement = team_requirement() + ' and certificate leaf = H"' + expected_identity() + '"'
    run('codesign', '--verify', '--deep', '--strict', '--all-architectures', '-R=' + requirement, path)
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], capture_output=True, check=True)
    details = result.stderr.decode()
    if 'Timestamp=' not in details or 'Timestamp=none' in details:
        raise RuntimeError('Developer ID artifact has no secure timestamp: ' + str(path))
    if Path(path).suffix != '.dmg' and '(runtime)' not in details:
        raise RuntimeError('Developer ID code must enable Hardened Runtime: ' + str(path))
    print('Verified Developer ID signature: ' + str(path))


def sign(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] not in ('io.github.future0923.QueryCraft', 'io.github.future0923.QueryCraft.Dev'):
        raise RuntimeError('Only QueryCraft application bundles can be signed.')
    entitlements = run('codesign', '-d', '--entitlements', ':-', app)
    if entitlements and plistlib.loads(entitlements).get('com.apple.security.app-sandbox'):
        raise RuntimeError('Use the non-sandboxed Release configuration for direct distribution.')
    spec = importlib.util.spec_from_file_location('credential_helper', ROOT / 'scripts/credential-helper.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    helper.embed(app, SimpleNamespace(run=run, KEYCHAIN=KEYCHAIN, sign_code=sign_code,
        helper_source=helper_source, team_requirement=team_requirement), activate())
    sign_sparkle(app / 'Contents/Frameworks/Sparkle.framework')
    for component in sorted((app / 'Contents/Frameworks').iterdir()):
        if component.name != 'Sparkle.framework' and component.suffix in ('.framework', '.dylib'):
            sign_code(component)
    sign_code(app, entitlements=ROOT / 'Config/Release.entitlements')
    verify(app)


def cleanup():
    if os.environ.get('CI') != 'true' or 'QUERYCRAFT_SIGNING_DIRECTORY' not in os.environ or KEYCHAIN != DIRECTORY / 'signing.keychain-db':
        raise RuntimeError('Cleanup is restricted to the explicit temporary CI keychain.')
    previous = DIRECTORY / 'previous-keychains.json'
    if previous.exists():
        run('security', 'list-keychains', '-d', 'user', '-s', *json.loads(previous.read_text()))
    if KEYCHAIN.exists():
        run('security', 'delete-keychain', KEYCHAIN)
    for name in ('identity.p12', 'keychain-password', 'previous-keychains.json'):
        (DIRECTORY / name).unlink(missing_ok=True)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['init', 'import-ci', 'check', 'check-release', 'sign', 'sign-path', 'verify', 'cleanup-ci', 'identity'])
    parser.add_argument('app', nargs='?', type=Path)
    args = parser.parse_args()
    if args.command in ('init', 'import-ci'):
        provision(args.command == 'import-ci')
    elif args.command == 'cleanup-ci':
        cleanup()
    elif args.command == 'identity':
        print(activate())
    elif args.command == 'check':
        print('Developer ID ready: ' + activate())
    elif args.command == 'check-release':
        validate_release()
    elif args.app is None:
        parser.error('sign/sign-path/verify require an artifact path')
    elif args.command == 'sign':
        sign(args.app.resolve())
    elif args.command == 'sign-path':
        sign_code(args.app.resolve())
        verify(args.app.resolve())
    else:
        verify(args.app.resolve())
