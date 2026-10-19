#!/usr/bin/env python3
"""DBX-behavior regression using only owned, disposable localhost MySQLs.

Requires a completed Debug build and cached official MySQL 5.7/8.0/8.4 images.
Optional QC_SCHEMA_REFERENCE_RUNTIME points at the final app's Frameworks.
No saved business profiles, global pointer events or keyboard events are used.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json
import os
import platform
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
DD = Path(os.environ.get('DERIVED_DATA', ROOT / 'output/schema-comparison-build')).resolve()
OUT = Path(os.environ.get('QC_REFERENCE_OUTPUT', DD / 'regression/dbx-reference')).resolve()
OUT.mkdir(parents=True, exist_ok=True)
PRODUCTS = DD / 'Build/Products/Debug'
DOCKER = shutil.which('docker') or '/Applications/Docker.app/Contents/Resources/bin/docker'
PREFIX = 'qc-schema-reference-' + uuid.uuid4().hex[:8]
owned = []
ports = {}


def run(args, input=None, timeout=180):
    return subprocess.run([str(x) for x in args], input=input, text=True, capture_output=True,
                          check=True, timeout=timeout).stdout.strip()


def sql(service, value):
    return run([DOCKER, 'exec', '-i', PREFIX + '-' + service, 'mysql', '--protocol=TCP', '-h127.0.0.1', '-uroot',
                '--default-character-set=utf8mb4', '-N', '-B'], input=value)


def start(service, image):
    name = PREFIX + '-' + service
    run([DOCKER, 'run', '--rm', '-d', '--name', name, '-e', 'MYSQL_ALLOW_EMPTY_PASSWORD=yes',
         '-p', '127.0.0.1::3306', image, '--character-set-server=utf8mb4', '--collation-server=utf8mb4_general_ci'])
    owned.append(name)
    binding = json.loads(run([DOCKER, 'inspect', name]))[0]['NetworkSettings']['Ports']['3306/tcp'][0]
    ports[service] = int(binding['HostPort'])
    deadline = time.monotonic() + 120
    while True:
        try:
            version = sql(service, 'SELECT @@version;')
            break
        except subprocess.CalledProcessError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.5)
    sql(service, '''
CREATE DATABASE qc_schema_source CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE qc_schema_target CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE TABLE qc_schema_source.orders (id bigint NOT NULL PRIMARY KEY, created_at datetime DEFAULT NULL,
 note varchar(255) DEFAULT NULL COMMENT '买家备注', KEY idx_created_at (created_at)) ENGINE=InnoDB;
CREATE TABLE qc_schema_target.orders (id bigint NOT NULL PRIMARY KEY, created_at datetime DEFAULT NULL) ENGINE=InnoDB;
CREATE TABLE qc_schema_source.users (id int NOT NULL PRIMARY KEY, email varchar(255) DEFAULT NULL,
 status varchar(12) NOT NULL DEFAULT 'active', KEY idx_status (status)) ENGINE=InnoDB;
CREATE TABLE qc_schema_target.users (id int NOT NULL PRIMARY KEY, email varchar(100) DEFAULT NULL,
 obsolete varchar(20) DEFAULT NULL, KEY idx_obsolete (obsolete)) ENGINE=InnoDB;
CREATE TABLE qc_schema_source.new_orders (id int NOT NULL AUTO_INCREMENT PRIMARY KEY, label varchar(60),
 UNIQUE KEY ux_label (label)) ENGINE=InnoDB;
CREATE TABLE qc_schema_target.legacy_events (id int NOT NULL PRIMARY KEY) ENGINE=InnoDB;
INSERT INTO qc_schema_target.users (id,email,obsolete) VALUES (1,'buyer@example.com','legacy');
CREATE USER 'qc_source'@'%' IDENTIFIED BY '';
CREATE USER 'qc_target'@'%' IDENTIFIED BY '';
GRANT SELECT, SHOW VIEW ON qc_schema_source.* TO 'qc_source'@'%';
GRANT SELECT, SHOW VIEW ON qc_schema_target.* TO 'qc_target'@'%';
''')
    print('READY', service, version, ports[service], flush=True)
    return version


def harness(mode, service='57', target=None, folder=None):
    destination = OUT / (folder or mode)
    destination.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, QC_REGRESSION_MODE=mode, QC_SCHEMA_TEST_PORT=str(ports[service]),
               QC_REGRESSION_OUTPUT=str(destination), QC_SCHEMA_WINDOW_CAPTURE='1',
               QC_REGRESSION_DRIVERS=str(Path.home() / 'Library/Application Support/QueryCraftDev/DriverAPI-5/Drivers'),
               QC_REGRESSION_ARCH=platform.machine(),
               DYLD_FRAMEWORK_PATH=os.environ.get('QC_SCHEMA_REFERENCE_RUNTIME', str(PRODUCTS / 'PackageFrameworks')))
    if target:
        env['QC_SCHEMA_TARGET_PORT'] = str(ports[target])
    binary = PRODUCTS / 'SchemaComparisonUIProbe.app/Contents/MacOS/schema-comparison-regression'
    result = subprocess.run([str(binary), '-AppleLanguages', '(zh-Hans)'], env=env,
                            text=True, capture_output=True, timeout=180)
    (destination / (mode + '.log')).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(mode + ': ' + (result.stdout + result.stderr)[-3000:])
    print(result.stdout.strip(), flush=True)
    return destination


def migration(target):
    destination = harness('reference', target=target, folder='mysql' + target)
    script = (destination / ('reference-' + str(ports[target]) + '.sql')).read_text()
    assert 'CREATE TABLE' in script and 'MODIFY COLUMN' in script and 'DROP TABLE' in script
    sql(target, script)
    assert sql(target, "SELECT HEX(COLUMN_COMMENT) FROM information_schema.columns WHERE table_schema='qc_schema_target' AND table_name='orders' AND column_name='note';") == 'E4B9B0E5AEB6E5A487E6B3A8'
    assert sql(target, 'SELECT email,status FROM qc_schema_target.users WHERE id=1;') == 'buyer@example.com\tactive'
    assert sql(target, "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='qc_schema_target' AND table_name='legacy_events';") == '0'
    assert sql(target, "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='qc_schema_target' AND table_name='users' AND column_name='obsolete';") == '0'
    harness('verify-synchronized', target=target, folder='mysql' + target)
    (destination / 'apply.log').write_text('PASS reviewed full plan executed, target re-read matches source, existing row retained, UTF-8 comment exact\n')
    return target


try:
    versions = {service: start(service, image) for service, image in [
        ('57', 'public.ecr.aws/docker/library/mysql:5.7'),
        ('80', 'public.ecr.aws/docker/library/mysql:8.0'), ('84', 'mysql:8.4')]}
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(harness, 'native'), pool.submit(harness, 'connections'),
                   pool.submit(migration, '80'), pool.submit(migration, '84')]
        for future in futures:
            future.result()
    harness('failure')
    (OUT / 'summary.json').write_text(json.dumps({'status': 'passed', 'versions': versions,
        'coverage': ['monotonic-native-progress', 'catalog-attributes', 'create-modify-drop-review',
                     'index-column-dependencies', 'destructive-review-acknowledgment', 'real-sql-apply-and-recompare',
                     'retained-row-and-utf8-comment', 'native-connections-and-scope', 'native-save-copy-cancel-refresh',
                     'stable-pages', 'failure-recovery']}, ensure_ascii=False, indent=2))
    print('PASS all reference regressions:', OUT, flush=True)
finally:
    for name in owned:
        subprocess.run([DOCKER, 'stop', name], capture_output=True, timeout=45)
