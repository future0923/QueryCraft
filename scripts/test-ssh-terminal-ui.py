#!/usr/bin/env python3
"""Render the SSH client offscreen and exercise its real PTY session against an isolated sshd."""
import argparse
import getpass
import os
import socket
import time
import importlib.util
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--previous-bundle', type=Path, help='Optional signed older transport package without a renderer')
    parser.add_argument('--live-host', help='Optional explicitly authorized host from the existing Dev accounts; read-only terminal acceptance')
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--language', choices=['en', 'zh-Hans'], default='zh-Hans')
    args = parser.parse_args(); args.output = args.output.resolve(); args.output.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('signer', ROOT / 'scripts/code-signing.py')
    signer = importlib.util.module_from_spec(spec); spec.loader.exec_module(signer); identity = signer.activate()
    dd = ROOT / '.build/DerivedData'; products = dd / 'Build/Products/Debug'; frameworks = products / 'PackageFrameworks'
    with tempfile.TemporaryDirectory(prefix='qc-terminal-ui-') as temporary:
        temporary = Path(temporary); host = temporary / 'Verifier.app'; binary = host / 'Contents/MacOS/Verifier'; binary.parent.mkdir(parents=True)
        (host / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='io.github.future0923.QueryCraft.Dev' if args.live_host else 'io.github.future0923.QueryCraft.Dev.TerminalUIValidation', QCSharedCredentialHelperRequired=bool(args.live_host), CFBundleExecutable='Verifier', CFBundlePackageType='APPL', LSUIElement=True, CFBundleDevelopmentRegion=args.language, CFBundleLocalizations=[args.language])))
        sdk = subprocess.check_output(['xcode-select', '-p'], text=True).strip() + '/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
        command = ['swiftc', '-parse-as-library', '-target', platform.machine() + '-apple-macosx15.0', '-sdk', sdk, str(ROOT / 'scripts/test-ssh-terminal-ui.swift'), '-I', str(products), '-F', str(frameworks), '-framework', 'QueryCraftFeature', '-o', str(binary), '-Xlinker', '-rpath', '-Xlinker', str(frameworks)]
        for name in ['TreeSitterJSON', 'TreeSitterSQL', 'TreeSitter', 'Internal', 'CQueryCraftSSHPluginAPI']:
            path = dd / f'Build/Intermediates.noindex/GeneratedModuleMaps/{name}.modulemap'
            if path.exists(): command += ['-Xcc', '-fmodule-map-file=' + str(path)]
        command += ['-Xcc', '-fmodule-map-file=' + str(dd / 'SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap')]
        for path in [ROOT / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include', ROOT / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include', dd / 'SourcePackages/checkouts/tree-sitter/lib/include', dd / 'SourcePackages/checkouts/TextStory/Sources/Internal', ROOT / 'ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include']:
            command += ['-Xcc', '-I' + str(path)]
        subprocess.run(command, check=True)
        resources = host / 'Contents/Resources'; resources.mkdir()
        for bundle in products.glob('*.bundle'): shutil.copytree(bundle, resources / bundle.name, symlinks=True)
        if args.live_host:
            shutil.copytree(Path('/Applications/QueryCraftDev.app/Contents/Helpers'), host / 'Contents/Helpers', symlinks=True)
        signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', host)
        fixtures = temporary / 'RendererFixtures'
        for kind in ['missing', 'abi', 'version', 'corrupt']:
            candidate = fixtures / kind / 'QueryCraftSSH.bundle'
            shutil.copytree(args.bundle, candidate, symlinks=True)
            renderer = candidate / 'Contents/PlugIns/TerminalRenderer.bundle'
            if kind == 'missing': shutil.rmtree(renderer)
            elif kind in ('abi', 'version'):
                info_path = renderer / 'Contents/Info.plist'; info = plistlib.loads(info_path.read_bytes())
                info['QCSSHTerminalRendererABIVersion' if kind == 'abi' else 'CFBundleVersion'] = 99 if kind == 'abi' else '999'
                info_path.write_bytes(plistlib.dumps(info))
                signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', renderer)
            else:
                with (renderer / 'Contents/MacOS/QueryCraftSSHTerminalRenderer').open('ab') as corrupt: corrupt.write(b'corrupt-signature-fixture')
                continue
            signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', candidate)
        for name in ['host', 'client']:
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(temporary / name)], check=True)
        fingerprint = subprocess.check_output(['ssh-keygen', '-lf', str(temporary / 'host.pub'), '-E', 'sha256'], text=True).split()[1]
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0)); port = listener.getsockname()[1]
        config = temporary / 'sshd.conf'
        config.write_text(f"Port {port}\nListenAddress 127.0.0.1\nHostKey {temporary}/host\nPidFile {temporary}/sshd.pid\nAuthorizedKeysFile {temporary}/client.pub\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nAllowUsers {getpass.getuser()}\nLogLevel ERROR\n")
        with (temporary / 'sshd.log').open('w') as log:
            server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)], stdout=log, stderr=log)
            try:
                for _ in range(100):
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1): break
                    except OSError: time.sleep(.03)
                subprocess.run([str(binary), str(temporary / 'Data'), str(args.output), str(args.bundle.resolve()), str(port), getpass.getuser(), fingerprint, str(temporary / 'client')] + ([args.live_host, str(Path.home() / 'Library/Application Support/QueryCraftDev')] if args.live_host else []), env=dict(os.environ, QUERYCRAFT_RENDERER_FIXTURES=str(fixtures), QUERYCRAFT_PREVIOUS_SSH_BUNDLE=str(args.previous_bundle.resolve()) if args.previous_bundle else ''), check=True, timeout=120)
            finally:
                server.terminate(); server.wait(timeout=5)


if __name__ == '__main__': main()
