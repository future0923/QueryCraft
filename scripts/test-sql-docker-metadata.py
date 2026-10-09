#!/usr/bin/env python3
"""Check installed Dev SQL drivers against the existing local Docker test databases.

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
frameworks = products / 'PackageFrameworks'
binary = root / '.build/test-sql-docker-metadata'
args = [
    '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc',
    '-parse-as-library', '-target', platform.machine() + '-apple-macosx15.0',
    '-sdk', subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True).strip()
    + '/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk',
    str(root / 'scripts/test-sql-docker-metadata.swift'), '-I', str(products),
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

comment = '昵称（员工名称），这是一段较长的字段注释，用于验证单行省略与完整提示'
driver_dir = Path(os.environ.get('CHECK_DRIVER_DIRECTORY', Path.home() / 'Library/Application Support/QueryCraftDev/DriverAPI-4/Drivers'))
failures = []
for container, driver in [('querycraft-mysql56-test', 'mysql'),
                          ('querycraft-postgres16-test', 'postgresql'),
                          ('querycraft-postgres17-test', 'postgresql')]:
    config = json.loads(subprocess.check_output([docker, 'inspect', container]))[0]
    credentials = dict(v.split('=', 1) for v in config['Config']['Env'] if '=' in v)
    is_pg = driver == 'postgresql'
    port = config['NetworkSettings']['Ports']['5432/tcp' if is_pg else '3306/tcp'][0]['HostPort']
    first = 'qc_header_' + uuid.uuid4().hex[:12]
    second = first + '_archive'
    database = credentials.get('POSTGRES_DB', 'postgres') if is_pg else first
    user = credentials.get('POSTGRES_USER', 'postgres') if is_pg else 'root'
    password = credentials.get('POSTGRES_PASSWORD' if is_pg else 'MYSQL_ROOT_PASSWORD')

    def sql(statement):
        command = ([docker, 'exec', '-i', container, 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', user, '-d', database]
                   if is_pg else [docker, 'exec', '-i', container, 'sh', '-c',
                                  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u root --default-character-set=utf8mb4'])
        result = subprocess.run(command, input=statement, text=True, capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        return result.stdout.strip()

    try:
        version = sql('SELECT version();')
        print(container + ': ' + next(line.strip() for line in version.splitlines() if ('PostgreSQL ' in line or '5.6.' in line)), flush=True)
        if is_pg:
            sql(f"""CREATE SCHEMA {first}; CREATE SCHEMA {second};
                CREATE TABLE {first}.users (id integer PRIMARY KEY, user_nick varchar(20), amount numeric(12,2), tags integer[]);
                COMMENT ON COLUMN {first}.users.user_nick IS '{comment}';
                CREATE TABLE {second}.users (id integer PRIMARY KEY);
                COMMENT ON COLUMN {second}.users.id IS '归档编号';
                INSERT INTO {first}.users VALUES (1, '张三', 12.34, ARRAY[1,2]);
                INSERT INTO {second}.users VALUES (1);
                CREATE VIEW {first}.user_view AS SELECT user_nick FROM {first}.users;
                COMMENT ON COLUMN {first}.user_view.user_nick IS '视图昵称';""")
        else:
            sql(f"""CREATE DATABASE {first} CHARACTER SET utf8mb4; CREATE DATABASE {second} CHARACTER SET utf8mb4;
                CREATE TABLE {first}.users (id integer PRIMARY KEY, user_nick varchar(20) COMMENT '{comment}', amount decimal(12,2), unsigned_id bigint unsigned);
                CREATE TABLE {second}.users (id integer PRIMARY KEY COMMENT '归档编号');
                INSERT INTO {first}.users VALUES (1, '张三', 12.34, 18446744073709551615);
                INSERT INTO {second}.users VALUES (1);""")
        env = dict(os.environ, CHECK_DRIVER=driver, CHECK_PORT=port, CHECK_USER=user,
                   CHECK_DATABASE=database, CHECK_FIRST=first, CHECK_SECOND=second,
                   CHECK_BUNDLE=str(driver_dir / f'{"PostgreSQL" if is_pg else "MySQL"}-{platform.machine()}.querycraftdriver'))
        if password is not None:
            env['CHECK_PASSWORD'] = password
        env['DYLD_FRAMEWORK_PATH'] = os.environ.get('CHECK_FEATURE_FRAMEWORKS', '/Applications/QueryCraftDev.app/Contents/Frameworks')
        preview_dir = root / '.build/previews'
        preview_dir.mkdir(parents=True, exist_ok=True)
        env['CHECK_PREVIEW_PATH'] = str(preview_dir / ('docker-' + container))
        run = subprocess.run([str(binary)], env=env, capture_output=True, text=True, timeout=60)
        if run.returncode:
            diagnostic = next((line for line in run.stderr.splitlines() if line.startswith('FAIL:')), run.stderr[:1200])
            raise RuntimeError(diagnostic)
        print(container + ': ' + run.stdout.strip(), flush=True)
    except Exception as error:
        failures.append(container)
        print(f'FAIL {container}: {error}', flush=True)
    finally:
        sql(f'DROP SCHEMA IF EXISTS {first} CASCADE; DROP SCHEMA IF EXISTS {second} CASCADE;' if is_pg
            else f'DROP DATABASE IF EXISTS {first}; DROP DATABASE IF EXISTS {second};')
if failures:
    raise SystemExit('Failed: ' + ', '.join(failures))
