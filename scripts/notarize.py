#!/usr/bin/env python3
"""Notarize final artifacts before publishing/signing archive metadata.

Local authentication: notarytool Keychain profile QueryCraft-Notary (override
QUERYCRAFT_NOTARY_PROFILE). CI: QUERYCRAFT_NOTARY_KEY_ID, _ISSUER_ID and
_PRIVATE_KEY_BASE64, or QUERYCRAFT_NOTARY_APPLE_ID, _APP_PASSWORD and _TEAM_ID.
No credentials or private-key paths are logged.
"""
import argparse
import base64
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def local_profile():
    if os.environ.get('QUERYCRAFT_NOTARY_PROFILE'):
        return os.environ['QUERYCRAFT_NOTARY_PROFILE']
    path = ROOT / 'Config/LocalDistribution.json'
    if path.exists():
        profile = json.loads(path.read_text()).get('notaryProfile')
        if not isinstance(profile, str) or not profile.strip():
            raise RuntimeError('Invalid local notarization profile configuration.')
        return profile
    return 'QueryCraft-Notary'


def run(*args):
    # These operations are idempotent. Never blindly resubmit an upload after
    # an ambiguous network failure, or retry authentication/ticket rejection.
    retryable = args[:3] in {
        ('xcrun', 'notarytool', 'history'), ('xcrun', 'notarytool', 'log'),
        ('xcrun', 'stapler', 'staple'), ('xcrun', 'stapler', 'validate'),
    }
    delays = (5, 15, 30)
    for attempt in range(len(delays) + 1):
        result = subprocess.run(list(map(str, args)), capture_output=True, text=True)
        if not result.returncode:
            return result.stdout
        diagnostic = result.stderr.strip() or result.stdout.strip() or f'{args[0]} failed'
        network_error = re.search(r'NSURLErrorDomain\s+(?:Code=|error\s+)-100[13459]\b', diagnostic)
        if not retryable or not network_error or attempt == len(delays):
            # Never echo argv: authentication arguments can contain passwords.
            raise RuntimeError(diagnostic)
        print(f'Transient Apple network error; retrying {args[1]} {args[2]} '
              f'({attempt + 2}/{len(delays) + 1}) in {delays[attempt]}s.', file=sys.stderr, flush=True)
        time.sleep(delays[attempt])


@contextmanager
def credentials():
    names = ['QUERYCRAFT_NOTARY_KEY_ID', 'QUERYCRAFT_NOTARY_ISSUER_ID', 'QUERYCRAFT_NOTARY_PRIVATE_KEY_BASE64']
    configured = [bool(os.environ.get(name)) for name in names]
    apple_names = ['QUERYCRAFT_NOTARY_APPLE_ID', 'QUERYCRAFT_NOTARY_APP_PASSWORD', 'QUERYCRAFT_NOTARY_TEAM_ID']
    apple_configured = [bool(os.environ.get(name)) for name in apple_names]
    if any(configured):
        if not all(configured):
            raise RuntimeError('Configure all three QUERYCRAFT_NOTARY API-key secrets.')
        with tempfile.TemporaryDirectory(prefix='qc-notary-auth-') as temporary:
            key = Path(temporary) / 'AuthKey.p8'
            key.write_bytes(base64.b64decode(os.environ[names[2]], validate=True))
            key.chmod(0o600)
            yield ['--key', str(key), '--key-id', os.environ[names[0]], '--issuer', os.environ[names[1]]]
    elif any(apple_configured):
        if not all(apple_configured):
            raise RuntimeError('Configure Apple ID, App-specific password and Team ID together.')
        expected_team = json.loads((ROOT / 'Config/DeveloperID.json').read_text())['teamID']
        if os.environ[apple_names[2]] != expected_team:
            raise RuntimeError('Notarization Team ID does not match the configured Developer ID Team.')
        yield ['--apple-id', os.environ[apple_names[0]], '--password', os.environ[apple_names[1]],
               '--team-id', os.environ[apple_names[2]]]
    else:
        if os.environ.get('CI') == 'true':
            raise RuntimeError('Missing notarization credentials: configure Apple ID/App-specific password/Team ID or an API key; release notarization cannot be skipped.')
        yield ['--keychain-profile', local_profile()]


def check():
    with credentials() as auth:
        json.loads(run('xcrun', 'notarytool', 'history', *auth, '--output-format', 'json'))
    print('Notarization credentials verified.')


def notarize(path, *, log=None):
    path = Path(path).resolve()
    if not path.exists() or path.suffix not in ('.app', '.dmg', '.zip'):
        raise RuntimeError('Expected an existing .app, .dmg or final .zip artifact.')
    with credentials() as auth, tempfile.TemporaryDirectory(prefix='qc-notary-') as temporary:
        archive = path
        if path.suffix == '.app':
            archive = Path(temporary) / 'application.zip'
            run('ditto', '-c', '-k', '--keepParent', path, archive)
        result = json.loads(run('xcrun', 'notarytool', 'submit', archive, *auth,
                                '--wait', '--timeout', '20m', '--output-format', 'json'))
        if not result.get('id'):
            raise RuntimeError('Notary service returned no submission ID.')
        report = json.loads(run('xcrun', 'notarytool', 'log', result['id'], *auth))
        if log:
            Path(log).write_text(json.dumps(report, indent=2) + '\n')
        if result.get('status') != 'Accepted' or report.get('status') != 'Accepted':
            raise RuntimeError('Apple notarization did not accept this artifact: ' + result['id'])
        # Plugin ZIPs have no staple target. Apple records their Mach-O tickets
        # online. App and DMG tickets are stapled for offline Gatekeeper checks.
        if path.suffix in ('.app', '.dmg'):
            run('xcrun', 'stapler', 'staple', path)
            run('xcrun', 'stapler', 'validate', path)
            if path.suffix == '.app':
                run('spctl', '--assess', '--type', 'execute', '--verbose=2', path)
            else:
                run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', path)
        print('Apple notarization accepted: ' + path.name + ' (' + result['id'] + ')')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', help='check, validate, or path to final .app/.dmg/.zip')
    parser.add_argument('target', nargs='?', help='stapled .app/.dmg for validate')
    parser.add_argument('--log', type=Path)
    args = parser.parse_args()
    if args.artifact == 'check':
        check()
    elif args.artifact == 'validate':
        # Gate for downloaded release artifacts; shares the bounded network retry.
        if not args.target or not Path(args.target).exists():
            raise RuntimeError('Expected an existing stapled .app or .dmg to validate.')
        print(run('xcrun', 'stapler', 'validate', args.target).strip())
    else:
        notarize(args.artifact, log=args.log)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        raise SystemExit(str(error))
