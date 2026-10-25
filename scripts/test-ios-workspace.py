#!/usr/bin/env python3
"""Own all three disposable SQL servers for native workspace/transfer acceptance."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('simulator', nargs='+')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
docker = shutil.which('docker') or '/Applications/Docker.app/Contents/Resources/bin/docker'
owned = []

def container(image, port, options=(), command=()):
    subprocess.run([docker, 'image', 'inspect', image], check=True, stdout=subprocess.DEVNULL)
    name = 'qc-mobile-workspace-' + uuid.uuid4().hex[:10]
    subprocess.run([docker, 'run', '--detach', '--rm', '--name', name, '--publish', f'127.0.0.1::{port}', *options, image, *command], check=True, stdout=subprocess.DEVNULL)
    owned.append(name)
    info = json.loads(subprocess.check_output([docker, 'inspect', name]))[0]
    return name, info['NetworkSettings']['Ports'][str(port) + '/tcp'][0]['HostPort']

def wait(label, command, probe=lambda result: result.returncode == 0):
    for _ in range(180):
        result = subprocess.run(command, text=True, capture_output=True, timeout=30)
        if probe(result):
            print(label + ' ready', flush=True)
            return
        time.sleep(1)
    raise RuntimeError(label + ' did not become ready')

try:
    mysql, mysql_port = container('mysql:8.4', 3306, ['--env', 'MYSQL_ROOT_PASSWORD=qc-workspace-mysql', '--env', 'MYSQL_ROOT_HOST=%'], ['--local-infile=ON'])
    my = [docker, 'exec', '--interactive', '--env', 'MYSQL_PWD=qc-workspace-mysql', mysql, 'mysql', '--user=root', '--default-character-set=utf8mb4']
    wait('MySQL', my + ['-e', 'SELECT 1'])
    digits = '(SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)'
    seed = f"""CREATE DATABASE qc_workspace_source CHARACTER SET utf8mb4;
CREATE TABLE qc_workspace_source.sample (id BIGINT PRIMARY KEY, value LONGTEXT, missing TEXT, `empty` TEXT, raw LONGBLOB) ENGINE=InnoDB;
INSERT INTO qc_workspace_source.sample SELECT 9007199254740993+a.n+10*b.n+100*c.n+1000*d.n,REPEAT('雪😀',1000),NULL,'',UNHEX('00FF8027') FROM {digits} a CROSS JOIN {digits} b CROSS JOIN {digits} c CROSS JOIN {digits} d WHERE a.n+10*b.n+100*c.n+1000*d.n<1001;
"""
    subprocess.run(my, input=seed, text=True, check=True, stdout=subprocess.DEVNULL)
    pg, pg_port = container('postgres:17', 5432, ['--env', 'POSTGRES_PASSWORD=querycraft-proof-pg', '--env', 'POSTGRES_DB=querycraft_ios_pg'])
    pq = [docker, 'exec', '--interactive', pg, 'psql', '-U', 'postgres', '-d', 'querycraft_ios_pg', '-v', 'ON_ERROR_STOP=1']
    wait('PostgreSQL', pq + ['-c', 'SELECT 1'])
    subprocess.run(pq, input="""CREATE SCHEMA workspace_source;
CREATE TABLE workspace_source.sample (id BIGINT PRIMARY KEY, value TEXT, missing TEXT, "empty" TEXT, raw BYTEA);
INSERT INTO workspace_source.sample SELECT 9007199254740993+n,repeat('雪😀',1000),NULL,'',decode('00ff8027','hex') FROM generate_series(0,1000) n;
""", text=True, check=True, stdout=subprocess.DEVNULL)
    doris, doris_port = container('apache/doris:all-in-one-4.1.3', 9030, ['--env', 'FE_HEAP=768m', '--env', 'BE_HEAP=512m'])
    dq = [docker, 'exec', doris, 'mysql', '-h127.0.0.1', '-P9030', '-uroot', '--default-character-set=utf8mb4', '-N']
    wait('Doris', dq + ['-e', 'SELECT 1'])
    subprocess.run(dq + ['-e', 'CREATE DATABASE querycraft_ios_drivers'], check=True, stdout=subprocess.DEVNULL)
    # A true-valued status column does not guarantee an allocatable backend.
    wait('Doris backend', dq + ['-e', "CREATE TABLE IF NOT EXISTS querycraft_ios_drivers.sample (id INT, name VARCHAR(80) COMMENT '真实字段注释') DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ('replication_num'='1')"])
    subprocess.run(dq + ['-e', "INSERT INTO querycraft_ios_drivers.sample VALUES (1,'你好 Doris'),(2,'second'); CREATE VIEW querycraft_ios_drivers.sample_view AS SELECT * FROM querycraft_ios_drivers.sample;"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['xcodegen', 'generate', '--spec', 'QueryCraftMobile/project.yml'], cwd=root, check=True, stdout=subprocess.DEVNULL)
    suites = ['MobileTransferIntegrationTests', 'MobileDorisParityTests', 'MobilePersistentWorkspaceTests', 'MobileEditorPreferenceTests', 'MobileRemainingPresentationTests', 'MobileSQLEditorTests', 'MobileWorkspaceSafetyTests', 'DataTransferSQLTests', 'DataTransferRunnerTests', 'DataTransferLibraryTests', 'TransferBulkEncoderTests']
    env = {'PROOF_TRANSFER_MYSQL_PORT': mysql_port, 'PROOF_POSTGRES_PORT': pg_port, 'PROOF_DORIS_PORT': doris_port, 'PROOF_DRIVER_PREVIEW_OUTPUT': str(root / '.build/ios-driver-previews')}
    for simulator in args.simulator:
        command = ['xcodebuildmcp', 'simulator', 'test', '--project-path', 'QueryCraftMobile/QueryCraftMobile.xcodeproj', '--scheme', 'QueryCraftMobileProof', '--simulator-id', simulator, '--derived-data-path', '.build/ios-driver-derived', '--output', 'json', '--json', json.dumps({'testRunnerEnv': env}), '--extra-args']
        command += ['-only-testing:QueryCraftMobileProofTests/' + suite for suite in suites]
        output = root / '.build/ios-validation' / ('workspace-acceptance-' + simulator + '.json')
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open('w') as file:
            result = subprocess.run(command, cwd=root, stdout=file)
        report = json.loads(output.read_text())
        print(json.dumps(report.get('data', {}).get('summary', {})), flush=True)
        if result.returncode or report.get('didError') or report.get('data', {}).get('summary', {}).get('status') != 'SUCCEEDED':
            raise RuntimeError('Workspace acceptance failed; inspect ' + str(output))

finally:
    for name in reversed(owned):
        subprocess.run([docker, 'rm', '--force', '--volumes', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
