#!/usr/bin/env python3
"""Read-only editor smoke against explicitly named local Docker containers.

Pass --container mysql=name (and the other five driver names). Credentials stay
in memory. No fixtures, schemas, keys, indices, topics, or messages are written.
Requires the Debug app to have been built; uses its feature framework and the
installed Dev driver bundles. Captures native views without desktop input.
"""
from pathlib import Path
import json
import os
import platform
import subprocess
import uuid

root = Path(__file__).resolve().parent.parent
dd = Path(os.environ.get('DERIVED_DATA', root / '.build/DerivedData'))
docker = '/Applications/Docker.app/Contents/Resources/bin/docker'
products = dd / 'Build/Products/Debug'
frameworks = products / 'PackageFrameworks'
binary = root / '.build/test-editor-driver-smoke'
args = [
    '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc',
    '-parse-as-library', '-target', platform.machine() + '-apple-macosx15.0',
    '-sdk', subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True).strip()
    + '/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk',
    str(root / 'scripts/test-editor-driver-smoke.swift'), '-I', str(products),
    '-F', str(frameworks), '-framework', 'QueryCraftFeature', '-o', str(binary),
    '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
]
for name in ['TreeSitterJSON', 'TreeSitterSQL', 'TreeSitter', 'Internal']:
    args += ['-Xcc', '-fmodule-map-file=' + str(dd / f'Build/Intermediates.noindex/GeneratedModuleMaps/{name}.modulemap')]
args += ['-Xcc', '-fmodule-map-file=' + str(dd / 'SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap')]
for path in [root / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include',
             root / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include',
             dd / 'SourcePackages/checkouts/tree-sitter/lib/include',
             dd / 'SourcePackages/checkouts/TextStory/Sources/Internal',
             root / 'ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include']:
    args += ['-Xcc', '-I' + str(path)]
subprocess.run(args, check=True)


import argparse
import re
parser = argparse.ArgumentParser()
parser.add_argument('--container', action='append', required=True, metavar='DRIVER=NAME')
options = parser.parse_args()
ports = {'mysql': '3306/tcp', 'postgresql': '5432/tcp', 'doris': '9030/tcp',
         'redis': '6379/tcp', 'elasticsearch': '9200/tcp', 'kafka': '9092/tcp'}
bundles = {'mysql': 'MySQL', 'postgresql': 'PostgreSQL', 'doris': 'Doris',
           'redis': 'Redis', 'elasticsearch': 'Elasticsearch', 'kafka': 'Kafka'}
api_source = (root / 'QueryCraftPackage/Sources/QueryCraftFeature/DatabaseDriverPackage.swift').read_text()
api_version = re.search(r'static let currentDriverAPIVersion = (\d+)', api_source).group(1)
driver_dir = Path.home() / f'Library/Application Support/QueryCraftDev/DriverAPI-{api_version}/Drivers'
output = root / '.build/previews/editor-driver-smoke'
output.mkdir(parents=True, exist_ok=True)
failures = []
for item in options.container:
    driver, container = item.split('=', 1)
    if driver not in ports:
        parser.error('Unknown driver: ' + driver)
    config = json.loads(subprocess.check_output([docker, 'inspect', container]))[0]
    bindings = config['NetworkSettings']['Ports'][ports[driver]]
    local = next((b for b in bindings if b['HostIp'] == '127.0.0.1'), None)
    if local is None:
        parser.error('An explicit loopback port binding is required')
    values = dict(v.split('=', 1) for v in config['Config']['Env'] if '=' in v)
    env = dict(os.environ, CHECK_DRIVER=driver, CHECK_PORT=local['HostPort'],
               CHECK_BUNDLE=str(driver_dir / f'{bundles[driver]}-{platform.machine()}.querycraftdriver'),
               CHECK_OUTPUT=str(output), DYLD_FRAMEWORK_PATH=str(frameworks), PACKAGE_RESOURCE_BUNDLE_PATH=str(products),
               CHECK_USER=values.get('POSTGRES_USER', 'postgres') if driver == 'postgresql' else ('root' if driver in ('mysql', 'doris') else ''),
               CHECK_DATABASE=values.get('POSTGRES_DB', 'postgres') if driver == 'postgresql' else '')
    env['CHECK_PASSWORD'] = values.get('POSTGRES_PASSWORD' if driver == 'postgresql' else 'MYSQL_ROOT_PASSWORD', '') if driver in ('postgresql', 'mysql') else ''
    try:
        result = subprocess.run([str(binary)], env=env, capture_output=True, text=True, timeout=90)
        # Only the harness's controlled status lines are emitted; driver logs can contain data.
        print('\n'.join(line for line in result.stdout.splitlines() if line.startswith('PASS ')), flush=True)
        if result.returncode:
            failures.append(driver)
            print('FAIL ' + driver + ': read-only smoke failed (no connection secrets logged)', flush=True)
            diagnostic = result.stderr[:3000] + '\n' + '\n'.join(line for line in result.stdout.splitlines() if line.startswith('FAIL harness'))
            for secret in [env.get('CHECK_PASSWORD'), env.get('CHECK_USER')]:
                if secret:
                    diagnostic = diagnostic.replace(secret, '[redacted]')
            print('Exit:', result.returncode, diagnostic, flush=True)
    except subprocess.TimeoutExpired:
        failures.append(driver)
        print('FAIL ' + driver + ': read-only smoke timed out', flush=True)
if failures:
    raise SystemExit('Failed drivers: ' + ', '.join(failures))
