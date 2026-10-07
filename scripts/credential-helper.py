#!/usr/bin/env python3
"""Package the pinned, protocol-versioned Keychain helper into a QueryCraft app."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
HELPER_NAME = 'QueryCraft Credentials.app'
IDENTIFIER = 'io.github.future0923.QueryCraft.CredentialHelper'


def embed(app, signer, identity):
    app = Path(app)
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    if info['CFBundleIdentifier'] not in ('io.github.future0923.QueryCraft', 'io.github.future0923.QueryCraft.Dev'):
        raise RuntimeError('Only QueryCraft applications may embed the credential helper.')
    helper = app / 'Contents/Helpers' / HELPER_NAME
    if helper.exists():
        # Never silently replace an already packaged helper while re-signing a host.
        requirement = f'identifier "{IDENTIFIER}" and certificate leaf = H"{identity}"'
        signer.run('codesign', '--verify', '--strict', '-R', requirement, helper)
    else:
        (helper / 'Contents/MacOS').mkdir(parents=True)
        source = (ROOT / 'CredentialHelper/main.swift').read_text().replace('__PINNED_CERTIFICATE_SHA1__', identity)
        with tempfile.TemporaryDirectory(prefix='querycraft-helper-') as directory:
            directory = Path(directory)
            main = directory / 'main.swift'
            main.write_text(source)
            binaries = []
            for arch in ('arm64', 'x86_64'):
                binary = directory / arch
                subprocess.run(['swiftc', '-O', '-target', arch + '-apple-macosx15.0', str(main), '-o', str(binary)], check=True)
                binaries.append(binary)
            subprocess.run(['lipo', '-create', *map(str, binaries), '-output', str(helper / 'Contents/MacOS/QueryCraftCredentials')], check=True)
        (helper / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': IDENTIFIER,
            'CFBundleName': 'QueryCraft Credentials',
            'CFBundleDisplayName': 'QueryCraft Credentials',
            'CFBundleExecutable': 'QueryCraftCredentials',
            'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1',
            'LSMinimumSystemVersion': '15.0',
            'LSUIElement': True,
            'QCCredentialProtocolVersion': 1,
        }))
        signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN,
                   '--timestamp=none', '--options', 'runtime', helper)
    info['QCCredentialHelperRequired'] = True
    info_path.write_bytes(plistlib.dumps(info))


if __name__ == '__main__':
    import sys
    spec = importlib.util.spec_from_file_location('querycraft_signer', ROOT / 'scripts/code-signing.py')
    signer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(signer)
    embed(Path(sys.argv[1]), signer, signer.activate())
