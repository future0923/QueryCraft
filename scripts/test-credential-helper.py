#!/usr/bin/env python3
"""Exercise the real helper with a temporary credential; never touch saved connection passwords."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    sys.modules[name] = value
    spec.loader.exec_module(value)
    return value


def cdhash(app):
    result = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], check=True, capture_output=True, text=True)
    return next(line for line in result.stderr.splitlines() if line.startswith('CDHash='))


def main():
    signer = module('helper_test_signer', ROOT / 'scripts/code-signing.py')
    packager = module('helper_test_packager', ROOT / 'scripts/credential-helper.py')
    identity = signer.activate()
    account = str(uuid.uuid4())
    with tempfile.TemporaryDirectory(prefix='querycraft-helper-test-') as temporary:
        folder = Path(temporary)
        source = folder / 'Host.swift'
        source.write_text('''import Foundation
@main struct Host {
    static func main() async {
        let arguments = CommandLine.arguments
        let client = WorkspaceCredentialHelperClient(installationRoot: URL(fileURLWithPath: arguments[2]))
        let account = UUID(uuidString: arguments[3])!
        let operation = arguments[1]
        do {
            switch operation {
            case "save", "update":
                _ = try await client.send(.init(operation: "save", account: account,
                    password: operation == "save" ? "temporary fixture α😀" : "updated fixture", allowsInteraction: false))
            case "get", "updated":
                let password = try await client.send(.init(operation: "get", account: account, allowsInteraction: false))
                guard password == (operation == "get" ? "temporary fixture α😀" : "updated fixture") else { exit(2) }
            case "missing":
                guard try await client.send(.init(operation: "get", account: account, allowsInteraction: false)) == nil else { exit(3) }
            case "delete":
                _ = try await client.send(.init(operation: "delete", account: account, allowsInteraction: false))
            default: exit(64)
            }
            print("PASS", operation)
        } catch {
            fputs("Helper test failed: \\(error.localizedDescription)\\n", stderr)
            exit(1)
        }
    }
}
''')
        hosts = []
        for version in ('A', 'B'):
            app = folder / (version + '.app')
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'io.github.future0923.QueryCraft.Dev',
                'CFBundleExecutable': 'Host', 'CFBundleName': 'QueryCraft Helper Test',
                'CFBundleVersion': version, 'CFBundlePackageType': 'APPL',
            }))
            subprocess.run(['swiftc', '-parse-as-library', str(source),
                            str(ROOT / 'QueryCraftPackage/Sources/QueryCraftFeature/WorkspaceCredentialHelperClient.swift'),
                            '-o', str(app / 'Contents/MacOS/Host')], check=True)
            packager.embed(app, signer, identity)
            if version == 'B':
                helper = app / 'Contents/Helpers' / packager.HELPER_NAME
                helper_info = helper / 'Contents/Info.plist'
                value = plistlib.loads(helper_info.read_bytes())
                value['CFBundleVersion'] = '1.1'
                helper_info.write_bytes(plistlib.dumps(value))
                signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN,
                           '--timestamp=none', '--options', 'runtime', helper)
            signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', app)
            hosts.append(app)
        assert cdhash(hosts[0]) != cdhash(hosts[1])
        assert cdhash(hosts[0] / 'Contents/Helpers' / packager.HELPER_NAME) != cdhash(hosts[1] / 'Contents/Helpers' / packager.HELPER_NAME)
        cache = folder / 'installed-helper'
        installed = cache / packager.HELPER_NAME
        def run(host, operation):
            subprocess.run([str(host / 'Contents/MacOS/Host'), operation, str(cache), account], check=True, timeout=30)
        try:
            run(hosts[0], 'missing')
            helper_hash = cdhash(installed)
            run(hosts[0], 'save')
            run(hosts[0], 'get')
            run(hosts[1], 'get')
            assert cdhash(installed) == helper_hash
            run(hosts[1], 'update')
            run(hosts[0], 'updated')
            # An unsigned/untrusted caller is rejected before reading stdin/Keychain.
            result = subprocess.run([str(installed / 'Contents/MacOS/QueryCraftCredentials')],
                                    input=b'', capture_output=True, timeout=10)
            assert result.returncode == 77 and not result.stdout
            print('PASS unauthorized caller rejected')
            # Reject a replaced helper rather than falling back to direct Keychain access.
            info = installed / 'Contents/Info.plist'
            original = info.read_bytes()
            info.write_bytes(original + b'\n')
            bad = subprocess.run([str(hosts[1] / 'Contents/MacOS/Host'), 'get', str(cache), account],
                                 capture_output=True, timeout=10)
            info.write_bytes(original)
            assert bad.returncode != 0
            print('PASS modified helper rejected')
        finally:
            if installed.exists():
                run(hosts[0], 'delete')
                run(hosts[0], 'missing')
        print('PASS host update retained helper identity; credential read/write required no dialogs')


if __name__ == '__main__':
    main()
