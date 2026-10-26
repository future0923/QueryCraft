#!/usr/bin/env python3
"""Verify native SSH pages, signed downloads and optional explicitly chosen real account."""
import argparse
import functools
import getpass
import http.server
import importlib.util
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mcp', type=Path, required=True, help='Signed matching development MCP app')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--language', choices=['en', 'zh-Hans'], default='zh-Hans')
    parser.add_argument('--packages', type=Path, default=ROOT / '.build/ssh-plugin/packages')
    parser.add_argument('--distribution-only', action='store_true', help='Verify signed downloads without rendering UI')
    parser.add_argument('--previous-package', type=Path, help='Previously signed native SSH ZIP for update/downgrade checks')
    parser.add_argument('--live-host')
    parser.add_argument('--username')
    parser.add_argument('--fingerprint')
    args = parser.parse_args()
    if args.live_host and not (args.username and args.fingerprint):
        parser.error('Real-server verification requires username and an independently verified fingerprint')
    args.output = args.output.resolve(); args.output.mkdir(parents=True, exist_ok=True)
    serving = args.output / 'catalog'; serving.mkdir(exist_ok=True)
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=str(serving)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    spec = importlib.util.spec_from_file_location('signer', ROOT / 'scripts/code-signing.py')
    signer = importlib.util.module_from_spec(spec); spec.loader.exec_module(signer); identity = signer.activate()
    secret = getpass.getpass('SSH password (hidden): ') if args.live_host else ''
    dd = ROOT / '.build/DerivedData'; products = dd / 'Build/Products/Debug'; frameworks = products / 'PackageFrameworks'
    try:
        with tempfile.TemporaryDirectory(prefix='querycraft-ssh-desktop-') as temp:
            temp = Path(temp); host = temp / 'Verifier.app'; binary = host / 'Contents/MacOS/Verifier'; binary.parent.mkdir(parents=True)
            (host / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='io.github.future0923.QueryCraft.Dev', CFBundleExecutable='Verifier', CFBundlePackageType='APPL', LSUIElement=True, QCAppVersion='0.1.12', QCSharedCredentialHelperRequired=True, CFBundleDevelopmentRegion=args.language, CFBundleLocalizations=[args.language])))
            shutil.copytree(args.mcp / 'Contents/Helpers', host / 'Contents/Helpers', symlinks=True)
            sdk = subprocess.check_output(['xcode-select', '-p'], text=True).strip() + '/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
            cmd = ['swiftc', '-parse-as-library', '-target', platform.machine() + '-apple-macosx15.0', '-sdk', sdk, str(ROOT / 'scripts/test-ssh-desktop.swift'), '-I', str(products), '-F', str(frameworks), '-framework', 'QueryCraftFeature', '-o', str(binary), '-Xlinker', '-rpath', '-Xlinker', str(frameworks)]
            for name in ['TreeSitterJSON', 'TreeSitterSQL', 'TreeSitter', 'Internal', 'CQueryCraftSSHPluginAPI']:
                modulemap = dd / f'Build/Intermediates.noindex/GeneratedModuleMaps/{name}.modulemap'
                if modulemap.exists(): cmd += ['-Xcc', '-fmodule-map-file=' + str(modulemap)]
            cmd += ['-Xcc', '-fmodule-map-file=' + str(dd / 'SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap')]
            for path in [ROOT / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include', ROOT / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include', dd / 'SourcePackages/checkouts/tree-sitter/lib/include', dd / 'SourcePackages/checkouts/TextStory/Sources/Internal', ROOT / 'ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include']:
                cmd += ['-Xcc', '-I' + str(path)]
            subprocess.run(cmd, check=True)
            resources = host / 'Contents/Resources'; resources.mkdir()
            for bundle in products.glob('*.bundle'): shutil.copytree(bundle, resources / bundle.name, symlinks=True)
            signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', host)
            cmd = [str(binary), str(temp / 'Data'), str(args.output), str(args.packages.resolve() / f'QueryCraftSSH-{platform.machine()}.zip'), str(args.mcp.resolve() / 'Contents/MacOS/querycraft-mcp'), f'http://127.0.0.1:{server.server_port}/']
            if args.live_host: cmd += [args.live_host, args.username, args.fingerprint]
            subprocess.run(cmd, input=secret.encode(), env=dict(os.environ, DYLD_FRAMEWORK_PATH=str(frameworks), QUERYCRAFT_TEST_SSH_DISTRIBUTION_ONLY='1' if args.distribution_only else '', QUERYCRAFT_TEST_SSH_PREVIOUS_PACKAGE=str(args.previous_package.resolve()) if args.previous_package else ''), check=True, timeout=180)
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__': main()
