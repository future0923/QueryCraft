#!/usr/bin/env python3
"""Test shared credential ownership with disposable items and isolated helper installs.

Never reads an existing connection credential or permits Keychain interaction.
Checks desktop/MCP handoff, upgrades, insert-only migration, deletion markers,
caller authentication and helper tampering. Removes all temporary Keychain items.
"""
import concurrent.futures
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def main():
    signer = module('shared_signer', ROOT / 'scripts/code-signing.py')
    packager = module('shared_packager', ROOT / 'scripts/credential-helper.py')
    identity = signer.activate()
    with tempfile.TemporaryDirectory(prefix='qc-shared-credentials-') as temporary:
        folder = Path(temporary)
        source = folder / 'Host.swift'
        source.write_text('''import Foundation
import Security
@main struct Host {
    static func main() async {
        let args = CommandLine.arguments
        let operation = args[1], account = UUID(uuidString: args[3])!
        let root = URL(fileURLWithPath: args[2])
        let legacy = WorkspaceCredentialHelperClient(installationRoot: root.appending(path: "legacy"))
        let helper = WorkspaceCredentialHelperClient.shared(installationRoot: root.appending(path: "shared"))
        let shared = SharedKeychainCredentialStore(directory: root, helper: helper)
        let vault = SharedKeychainCredentialStore.vaultIdentifier(in: root)
        do {
            switch operation {
            case "vault-count":
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "io.github.future0923.QueryCraft.shared-connection-profile-v2",
                    kSecAttrAccount as String: "connections-" + vault,
                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
                var result: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                      (result as? [[String: Any]])?.count == 1 else { exit(7) }
            case "isolated":
                let isolated = SharedKeychainCredentialStore(directory: root.appending(path: "OtherData"), helper: helper)
                guard try await isolated.record(for: account) == nil else { exit(8) }
            case "seed":
                _ = try await legacy.send(.init(operation: "save", account: account, password: "temporary fixture α😀", allowsInteraction: false))
            case "migrate":
                if try await shared.record(for: account) == nil {
                    guard let password = try await legacy.send(.init(operation: "get", account: account, allowsInteraction: false)) else { exit(2) }
                    try await shared.importIfAbsent(password: password, for: account)
                }
                _ = try await legacy.send(.init(operation: "delete", account: account, allowsInteraction: false))
                guard try await legacy.send(.init(operation: "get", account: account, allowsInteraction: false)) == nil else { exit(9) }
            case "get":
                guard try await shared.password(for: account) == "temporary fixture α😀" else { exit(3) }
            case "edit": try await shared.save(password: "updated fixture", for: account)
            case "updated":
                guard try await shared.password(for: account) == "updated fixture" else { exit(4) }
            case "delete": try await shared.delete(for: account)
            case "stale-import": try await shared.importIfAbsent(password: "old snapshot", for: account)
            case "deleted":
                guard let record = try await shared.record(for: account), record.password == nil else { exit(5) }
            case "cleanup":
                _ = try await helper.send(.init(operation: "delete", account: account, allowsInteraction: false, vault: vault))
                _ = try await legacy.send(.init(operation: "delete", account: account, allowsInteraction: false))
                guard try await shared.record(for: account) == nil,
                      try await legacy.send(.init(operation: "get", account: account, allowsInteraction: false)) == nil else { exit(6) }
            default: exit(64)
            }
            print("PASS", operation)
        } catch {
            // No secret or raw system diagnostic in test output.
            fputs("Credential fixture operation failed\\n", stderr)
            exit(1)
        }
    }
}
''')
        binary = folder / 'Host'
        feature = ROOT / 'QueryCraftPackage/Sources/QueryCraftFeature'
        subprocess.run(['swiftc', '-parse-as-library', str(source),
                        *[str(feature / name) for name in ['WorkspaceCredentialHelperClient.swift',
                          'SharedKeychainCredentialStore.swift', 'CredentialStore.swift', 'QueryCraftStorageLocation.swift']],
                        '-o', str(binary)], check=True)
        apps = []
        identifiers = ['io.github.future0923.QueryCraft.Dev', 'io.github.future0923.QueryCraft',
                       'io.github.future0923.QueryCraft.MCP.Dev', 'io.github.future0923.QueryCraft.MCP',
                       'io.github.future0923.QueryCraft.Untrusted']
        for index, identifier in enumerate(identifiers):
            app = folder / f'Host-{index}.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            shutil.copy2(binary, app / 'Contents/MacOS/Host')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Host',
                'CFBundleName': f'QueryCraft Shared Fixture {index}', 'CFBundlePackageType': 'APPL',
                'CFBundleVersion': str(index), 'LSUIElement': True,
            }))
            if index == 0:
                packager.embed(app, signer, identity)
            else:
                shutil.copytree(apps[0] / 'Contents/Helpers', app / 'Contents/Helpers', symlinks=True)
            # A different packaged v2 binary must not replace the already installed v2.
            if index == 3:
                helper = app / 'Contents/Helpers/QueryCraft Shared Credentials.app'
                info_path = helper / 'Contents/Info.plist'
                info = plistlib.loads(info_path.read_bytes()); info['CFBundleVersion'] = '2.1'
                info_path.write_bytes(plistlib.dumps(info))
                signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN,
                           '--timestamp=none', '--options', 'runtime', helper)
            signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', app)
            apps.append(app)
        cache = folder / 'installed'
        accounts = [str(uuid.uuid4()) for _ in range(8)]

        def run(index, operation, account, check=True):
            return subprocess.run([str(apps[index] / 'Contents/MacOS/Host'), operation, str(cache), account],
                                  capture_output=True, text=True, timeout=20, check=check)

        try:
            for account in accounts:
                run(0, 'seed', account)
            for account in accounts:
                run(0, 'migrate', account)
            run(0, 'vault-count', accounts[0])
            run(0, 'isolated', accounts[0])
            installed = cache / 'shared/QueryCraft Shared Credentials.app'
            installed_info = (installed / 'Contents/Info.plist').read_bytes()
            for index in range(4):
                for account in accounts:
                    run(index, 'get', account)
            assert (installed / 'Contents/Info.plist').read_bytes() == installed_info
            print('PASS eight legacy passwords shared across desktop/MCP Dev/release, no interaction; immutable v2 retained')
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                list(executor.map(lambda account: run(2, 'edit', account), accounts))
            for account in accounts:
                run(0, 'updated', account)
            print('PASS one Keychain vault for eight passwords, isolated data-directory namespaces and concurrent process writes')
            run(2, 'edit', accounts[0])
            run(0, 'migrate', accounts[0])
            for index in range(4):
                run(index, 'updated', accounts[0])
            run(3, 'delete', accounts[0])
            run(0, 'stale-import', accounts[0])
            for index in range(4):
                run(index, 'deleted', accounts[0])
            print('PASS password edits and deletion markers shared; legacy migration cannot overwrite either')
            assert run(4, 'get', accounts[1], check=False).returncode != 0
            rejected = subprocess.run([str(installed / 'Contents/MacOS/QueryCraftCredentials')],
                                      input=b'', capture_output=True, timeout=10)
            assert rejected.returncode == 77 and not rejected.stdout
            info_path = installed / 'Contents/Info.plist'
            info_path.write_bytes(installed_info + b'\n')
            try:
                assert run(0, 'get', accounts[1], check=False).returncode != 0
            finally:
                info_path.write_bytes(installed_info)
            print('PASS signed unrelated caller, unsigned caller and modified helper rejected')
        finally:
            # All IDs are random and created only by this test. Both namespaces are removed.
            for account in accounts:
                run(0, 'cleanup', account)
            print('PASS all temporary legacy/shared Keychain items removed')


if __name__ == '__main__':
    main()
