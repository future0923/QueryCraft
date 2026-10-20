#!/usr/bin/env python3
"""Exercise installed Dev drivers and the editor model against named local test containers.

Only uniquely named test tables are written, then removed. No desktop input.
Example: python3 scripts/test-sql-transaction-state.py --container mysql=TEST_MYSQL --container postgresql=TEST_POSTGRES
"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--container', action='append', default=[], metavar='DRIVER=NAME')
parser.add_argument('--driver-directory', type=Path)
parser.add_argument('--read-only', action='store_true', help='Only load bundles and SELECT 1, for older peer-driver compatibility checks')
parser.add_argument('--load-only', action='store_true', help='Verify installed driver packages using the app startup loader, without connecting')
options = parser.parse_args()
if not options.container and not options.load_only:
    parser.error('Provide --container or --load-only')
dd = Path(os.environ.get('DERIVED_DATA', root / '.build/DerivedData'))
products = dd / 'Build/Products/Debug'
frameworks = products / 'PackageFrameworks'
binary = root / '.build/transaction-state-harness/test-sql-transaction-state'
binary.parent.mkdir(parents=True, exist_ok=True)
# The installed Release host resolves parser resources beside the executable.
for resource in Path('/Applications/QueryCraftDev.app/Contents/Resources').glob('*.bundle'):
    link = binary.parent / resource.name
    if not link.exists():
        link.symlink_to(resource, target_is_directory=True)
toolchain = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin'
sdk = subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True).strip() + '/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
args = [toolchain + '/swiftc', '-parse-as-library', '-target', platform.machine() + '-apple-macosx15.0',
        '-sdk', sdk, str(root / 'scripts/test-sql-transaction-state.swift'), '-I', str(products),
        '-F', str(frameworks), '-framework', 'QueryCraftFeature', '-o', str(binary),
        '-Xlinker', '-rpath', '-Xlinker', str(frameworks)]
for module_map in (dd / 'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'):
    args += ['-Xcc', '-fmodule-map-file=' + str(module_map)]
args += ['-Xcc', '-fmodule-map-file=' + str(dd / 'SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap')]
args += ['-Xcc', '-fmodule-map-file=' + str(dd / 'SourcePackages/checkouts/swift-atomics/Sources/_AtomicsShims/include/module.modulemap')]
args += ['-Xcc', '-fmodule-map-file=' + str(dd / 'SourcePackages/checkouts/swift-nio/Sources/CNIOWindows/include/module.modulemap')]
args += ['-Xcc', '-fmodule-map-file=' + str(dd / 'SourcePackages/checkouts/swift-system/Sources/CSystem/include/module.modulemap')]
for path in [root / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include',
             root / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include',
             dd / 'SourcePackages/checkouts/tree-sitter/lib/include',
             dd / 'SourcePackages/checkouts/TextStory/Sources/Internal',
             root / 'ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include']:
    args += ['-Xcc', '-I' + str(path)]
subprocess.run(args, check=True)
api_source = (root / 'QueryCraftPackage/Sources/QueryCraftFeature/DatabaseDriverPackage.swift').read_text()
api = re.search(r'static let currentDriverAPIVersion = (\d+)', api_source).group(1)
directory = options.driver_directory or Path.home() / f'Library/Application Support/QueryCraftDev/DriverAPI-{api}/Drivers'
app_version = plistlib.loads(Path('/Applications/QueryCraftDev.app/Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
for name in ['MySQL', 'Doris', 'PostgreSQL', 'Redis', 'Elasticsearch', 'Kafka']:
    bundle = directory / f'{name}-{platform.machine()}.querycraftdriver'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
if options.load_only:
    env = dict(os.environ, CHECK_DRIVER_DIRECTORY=str(directory), CHECK_ARCH=platform.machine(), CHECK_LOAD_ONLY='1', CHECK_APP_VERSION=app_version,
               DYLD_FRAMEWORK_PATH='/Applications/QueryCraftDev.app/Contents/Frameworks')
    subprocess.run([str(binary)], env=env, check=True, timeout=45)
    raise SystemExit(0)
docker = '/Applications/Docker.app/Contents/Resources/bin/docker'
for item in options.container:
    driver, container = item.split('=', 1)
    if driver not in ('mysql', 'postgresql'):
        parser.error('Expected mysql or postgresql')
    config = json.loads(subprocess.check_output([docker, 'inspect', container]))[0]
    pg = driver == 'postgresql'
    bindings = config['NetworkSettings']['Ports']['5432/tcp' if pg else '3306/tcp']
    binding = next((b for b in bindings if b['HostIp'] == '127.0.0.1'), None)
    if binding is None:
        parser.error('An explicit loopback port binding is required')
    values = dict(v.split('=', 1) for v in config['Config']['Env'] if '=' in v)
    env = dict(os.environ, CHECK_DRIVER=driver, CHECK_ARCH=platform.machine(), CHECK_PORT=binding['HostPort'],
               CHECK_APP_VERSION=app_version,
               CHECK_DRIVER_DIRECTORY=str(directory), CHECK_USER=values.get('POSTGRES_USER', 'postgres') if pg else 'root',
               CHECK_DATABASE=values.get('POSTGRES_DB', 'postgres') if pg else values.get('MYSQL_DATABASE', 'mysql'),
               CHECK_PASSWORD=values.get('POSTGRES_PASSWORD' if pg else 'MYSQL_ROOT_PASSWORD', ''),
               CHECK_READ_ONLY='1' if options.read_only else '0',
               DYLD_FRAMEWORK_PATH='/Applications/QueryCraftDev.app/Contents/Frameworks',
               PACKAGE_RESOURCE_BUNDLE_PATH=str(products))
    result = subprocess.run([str(binary)], env=env, capture_output=True, text=True, timeout=90)
    if result.returncode:
        diagnostic = result.stderr
        if env['CHECK_PASSWORD']:
            diagnostic = diagnostic.replace(env['CHECK_PASSWORD'], '[redacted]')
        raise SystemExit(f'FAIL {container}: {diagnostic[:4000]}')
    print(container + ':\n' + '\n'.join(line for line in result.stdout.splitlines() if line.startswith('PASS ')), flush=True)
