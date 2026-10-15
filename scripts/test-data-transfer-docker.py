#!/usr/bin/env python3
"""Verify table export/import round trips through packaged Dev drivers and local Docker databases.

Creates uniquely named fixtures and removes only those fixtures in finally blocks.
Containers stay running. Credentials are read in memory and never printed.
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
frameworks = Path(os.environ.get('CHECK_FRAMEWORK_DIRECTORY', products / 'PackageFrameworks'))
binary = root / '.build/test-data-transfer-docker'
args = [
    '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc',
    '-parse-as-library', '-target', platform.machine() + '-apple-macosx15.0',
    '-sdk', subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True).strip()
    + '/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk',
    str(root / 'scripts/test-data-transfer-docker.swift'), '-I', str(products),
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


driver_dir = Path(os.environ.get('CHECK_DRIVER_DIRECTORY', Path.home() / 'Library/Application Support/QueryCraftDev/DriverAPI-5/Drivers'))
if os.environ.get('CHECK_ALL_DRIVER_LOADS') == '1':
    for driver, bundle_name in [('mysql', 'MySQL'), ('postgresql', 'PostgreSQL'), ('doris', 'Doris'),
                               ('redis', 'Redis'), ('elasticsearch', 'Elasticsearch'), ('kafka', 'Kafka')]:
        env = dict(os.environ, CHECK_DRIVER=driver, CHECK_LOAD_ONLY='1',
                   CHECK_BUNDLE=str(driver_dir / f'{bundle_name}-{platform.machine()}.querycraftdriver'),
                   DYLD_FRAMEWORK_PATH=str(frameworks))
        subprocess.run([str(binary)], env=env, check=True, timeout=30)
    if os.environ.get('CHECK_LOAD_ONLY') == '1': raise SystemExit(0)
failures = []
cases = [(os.environ.get('CHECK_MYSQL80_CONTAINER', 'qc-schema-0b02-mysql80'), 'mysql'),
         (os.environ.get('CHECK_MYSQL84_CONTAINER', 'qc-schema-0b02-mysql84'), 'mysql'),
         (os.environ.get('CHECK_POSTGRES_CONTAINER', 'qc-schema-0b02-postgres'), 'postgresql'),
         (os.environ.get('CHECK_DORIS_CONTAINER', 'qc-schema-0b02-doris'), 'doris')]
for container, driver in cases:
    if os.environ.get("CHECK_CONTAINER") and os.environ["CHECK_CONTAINER"] != container: continue
    inspection = subprocess.run([docker, 'inspect', container], capture_output=True, text=True)
    if inspection.returncode:
        failures.append(container)
        print(f'FAIL {container}: test container is unavailable', flush=True)
        continue
    config = json.loads(inspection.stdout)[0]
    credentials = dict(v.split('=', 1) for v in config['Config']['Env'] if '=' in v)
    is_pg = driver == 'postgresql'
    port = config['NetworkSettings']['Ports']['5432/tcp' if is_pg else ('9030/tcp' if driver == 'doris' else '3306/tcp')][0]['HostPort']
    namespace = 'qc_transfer_' + uuid.uuid4().hex[:12]
    database = credentials.get('POSTGRES_DB', 'postgres') if is_pg else namespace
    user = credentials.get('POSTGRES_USER', 'postgres') if is_pg else 'root'
    password = credentials.get('POSTGRES_PASSWORD' if is_pg else 'MYSQL_ROOT_PASSWORD', '')
    # Only localhost published Docker endpoints; no saved user connections are read.
    def sql(statement):
        if is_pg:
            command = [docker, 'exec', '-i', container, 'psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-U', user, '-d', database]
        else:
            cli_container = os.environ.get('CHECK_MYSQL_CLIENT_CONTAINER', 'qc-schema-0b02-mysql80') if driver == 'doris' else container
            connection = '-h host.docker.internal -P ' + port if driver == 'doris' else ''
            command = [docker, 'exec', '-i', cli_container, 'sh', '-c', 'MYSQL_PWD=' + ('\'\'' if driver == 'doris' else '"$MYSQL_ROOT_PASSWORD"') + ' exec mysql -u root --default-character-set=utf8mb4 ' + connection]
        result = subprocess.run(command, input=statement, text=True, capture_output=True, timeout=90)
        if result.returncode: raise RuntimeError(result.stderr.strip())
        return result.stdout.strip()
    quote = '"' if is_pg else '`'
    def table(name): return quote + namespace + quote + '.' + quote + name + quote
    def literal(value):
        if value is None: return 'NULL'
        hexed = value.encode().hex()
        return ("convert_from(decode('" + hexed + "','hex'),'UTF8')" if is_pg else
                "UNHEX('" + hexed + "')" if driver == 'doris' else "CONVERT(X'" + hexed + "' USING utf8mb4)")
    try:
        sql(('CREATE SCHEMA ' if is_pg else 'CREATE DATABASE ') + namespace + ('' if is_pg or driver == 'doris' else ' CHARACTER SET utf8mb4'))
        definition = ('id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, value text, amount numeric(30,9), flag boolean, blank text, literal_null text, computed bigint GENERATED ALWAYS AS (id + 1) STORED' if is_pg else
                      'id bigint NOT NULL, value STRING, amount decimal(30,9), flag boolean, blank STRING, literal_null STRING' if driver == 'doris' else
                      'id bigint PRIMARY KEY AUTO_INCREMENT, value text, amount decimal(30,9), flag boolean, blank text, literal_null text, computed bigint GENERATED ALWAYS AS (id + 1) STORED')
        suffix = (' DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES("replication_num"="1")' if driver == 'doris' else '' if is_pg else ' ENGINE=InnoDB DEFAULT CHARSET=utf8mb4')
        # MySQL prohibits generated expressions referencing AUTO_INCREMENT.
        if driver == 'mysql': definition = definition.replace('AUTO_INCREMENT', '')
        for name in ['source.with.dot', 'copy.with.dot']: sql('CREATE TABLE ' + table(name) + ' (' + definition + ')' + suffix)
        values = []
        samples = [None, '', 'NULL', '中文🙂', "O'Reilly\\path", 'line1\r\nline2\tend', 'a,b"c', '=1+1', '_x0041_', ' trailing ']
        if os.environ.get('CHECK_LARGE_VALUES') == '1':
            samples.append('大文件🙂' * 1600)
        for i in range(5003):
            values.append('(' + ','.join([str(9007199254740993+i), literal(samples[i % len(samples)]), '1234567890123456789.123456789', 'true' if i % 2 else 'false', literal(''), literal('NULL')]) + ')')
        for start in range(0, len(values), 500):
            sql('INSERT INTO ' + table('source.with.dot') + ' (id,value,amount,flag,blank,literal_null)' + (' OVERRIDING SYSTEM VALUE' if is_pg else '') + ' VALUES ' + ','.join(values[start:start+500]))
        env = dict(os.environ, CHECK_DRIVER=driver, CHECK_PORT=port, CHECK_USER=user, CHECK_PASSWORD=password,
                   CHECK_DATABASE=database, CHECK_NAMESPACE=namespace,
                   CHECK_BUNDLE=str(driver_dir / f'{dict(mysql="MySQL",postgresql="PostgreSQL",doris="Doris")[driver]}-{platform.machine()}.querycraftdriver'),
                   DYLD_FRAMEWORK_PATH=str(frameworks))
        run = subprocess.run([str(binary)], env=env, capture_output=True, text=True, timeout=240)
        print(container + ':\n' + run.stdout, flush=True)
        if run.returncode:
            diagnostic = next((line for line in run.stderr.splitlines() if line.startswith('FAIL:')), run.stderr[:1800])
            raise RuntimeError(diagnostic)
    except Exception as error:
        failures.append(container)
        print(f'FAIL {container}: {error}', flush=True)
    finally:
        sql('DROP SCHEMA IF EXISTS ' + namespace + ' CASCADE' if is_pg else 'DROP DATABASE IF EXISTS ' + namespace)
if failures: raise SystemExit('Failed: ' + ', '.join(failures))
