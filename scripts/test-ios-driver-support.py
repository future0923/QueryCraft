#!/usr/bin/env python3
"""Create isolated loopback PostgreSQL/Redis/Elasticsearch/Doris fixtures, test, and remove them.

No user connections, installed desktop drivers, or existing containers are used.
Images must already exist locally; this script never pulls images.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('simulator')
parser.add_argument('--full', action='store_true', help='Run the complete mobile suite')
options = parser.parse_args()
root = Path(__file__).resolve().parent.parent
docker = shutil.which('docker') or '/Applications/Docker.app/Contents/Resources/bin/docker'
containers = []
redis = None

def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)

def container(image, port, *args):
    run(docker, 'image', 'inspect', image, stdout=subprocess.DEVNULL)
    name = 'querycraft-ios-drivers-' + uuid.uuid4().hex[:12]
    run(docker, 'run', '--detach', '--rm', '--name', name, '--publish', f'127.0.0.1::{port}', *args, image, stdout=subprocess.DEVNULL)
    containers.append(name)
    data = json.loads(subprocess.check_output([docker, 'inspect', name]))[0]
    return name, int(data['NetworkSettings']['Ports'][str(port) + '/tcp'][0]['HostPort'])

def wait_for(label, probe, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if probe():
                print(label + ' ready', flush=True)
                return
        except (OSError, subprocess.SubprocessError, ValueError):
            pass
        time.sleep(1)
    raise RuntimeError(label + ' readiness timed out')

try:
    run("xcodegen", "generate", "--spec", str(root / "QueryCraftMobile/project.yml"), cwd=root)
    with tempfile.TemporaryDirectory(prefix='querycraft-ios-drivers-') as temporary:
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0)); redis_port = s.getsockname()[1]
        with open(Path(temporary) / 'redis.log', 'w') as log:
            redis = subprocess.Popen(['redis-server', '--bind', '127.0.0.1', '--port', str(redis_port), '--save', '', '--appendonly', 'no', '--dir', temporary], stdout=log, stderr=log)
        def redis_command(*args):
            return subprocess.check_output(['redis-cli', '-h', '127.0.0.1', '-p', str(redis_port), *args], text=True, stderr=subprocess.DEVNULL).strip()
        wait_for('Redis', lambda: redis_command('PING') == 'PONG')
        for args in [('SET', 'querycraft-proof:string', '你好 Redis'), ('RPUSH', 'querycraft-proof:list', 'first', 'second'), ('HSET', 'querycraft-proof:hash', 'field', 'value'), ('SADD', 'querycraft-proof:set', 'member'), ('ZADD', 'querycraft-proof:zset', '1.5', 'member')]:
            redis_command(*args)
        pg_name, pg_port = container('postgres:17', 5432, '--env', 'POSTGRES_PASSWORD=querycraft-proof-pg', '--env', 'POSTGRES_DB=querycraft_ios_pg')
        def postgres(sql):
            return subprocess.run([docker, 'exec', pg_name, 'psql', '-U', 'postgres', '-d', 'querycraft_ios_pg', '-v', 'ON_ERROR_STOP=1', '-c', sql], text=True, capture_output=True, check=True).stdout
        wait_for('PostgreSQL', lambda: '1' in postgres('SELECT 1'))
        postgres((root / 'scripts/fixtures/mobile-postgresql.sql').read_text())
        es_name, es_port = container('docker.elastic.co/elasticsearch/elasticsearch:8.18.0', 9200,
            '--env', 'discovery.type=single-node', '--env', 'xpack.security.enabled=false', '--env', 'ES_JAVA_OPTS=-Xms256m -Xmx256m')
        def es(path, body=None, method='GET'):
            request = urllib.request.Request(f'http://127.0.0.1:{es_port}' + path,
                data=None if body is None else json.dumps(body).encode(), method=method, headers={'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        wait_for('Elasticsearch', lambda: es('/')['version']['number'].startswith('8.'))
        es('/querycraft-ios-proof', {'mappings': {'properties': {'name': {'type': 'text'}, 'count': {'type': 'integer'}}}}, 'PUT')
        es('/querycraft-ios-proof/_doc/1?refresh=true', {'name': '你好 Elasticsearch', 'count': 1}, 'PUT')
        es('/querycraft-ios-proof/_alias/querycraft-ios-alias', {}, 'PUT')
        doris_name, doris_port = container('apache/doris:all-in-one-4.1.3', 9030, '--env', 'FE_HEAP=768m', '--env', 'BE_HEAP=512m')
        def doris(sql, check=True):
            return subprocess.run([docker, 'exec', doris_name, 'mysql', '-h127.0.0.1', '-P9030', '-uroot', '-N', '-e', sql], text=True, capture_output=True, check=check).stdout
        wait_for('Doris', lambda: '1' in doris('SELECT 1'))
        doris("CREATE DATABASE querycraft_ios_drivers")
        # Wait for actual tablet allocation, not an unrelated true status field.
        wait_for('Doris backend', lambda: doris("CREATE TABLE IF NOT EXISTS querycraft_ios_drivers.sample (id INT, name VARCHAR(80) COMMENT '真实字段注释') DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ('replication_num'='1')") is not None)
        doris("INSERT INTO querycraft_ios_drivers.sample VALUES (1,'你好 Doris'),(2,'second'); CREATE VIEW querycraft_ios_drivers.sample_view AS SELECT * FROM querycraft_ios_drivers.sample;")
        print('Fixtures prepared; running mobile tests', flush=True)
        arguments = ['xcodebuildmcp', 'simulator', 'test', '--project-path', str(root / 'QueryCraftMobile/QueryCraftMobile.xcodeproj'),
            '--scheme', 'QueryCraftMobileProof', '--simulator-id', options.simulator, '--derived-data-path', str(root / '.build/ios-driver-derived'),
            '--json', json.dumps({'testRunnerEnv': {'PROOF_REDIS_PORT': str(redis_port), 'PROOF_ELASTICSEARCH_PORT': str(es_port), 'PROOF_DORIS_PORT': str(doris_port), 'PROOF_POSTGRES_PORT': str(pg_port), 'PROOF_DRIVER_PREVIEW_OUTPUT': str(root / '.build/ios-driver-previews')}})]
        if options.full:
            # Reuse the existing complete MySQL setup so its integration tests are
            # exercised in the same run as the other four driver fixtures.
            environment = dict(os.environ, IOS_PROOF_DERIVED_DATA=str(root / '.build/ios-driver-derived'),
                PROOF_ADDITIONAL_TEST_ENV=json.dumps({'PROOF_REDIS_PORT': str(redis_port), 'PROOF_ELASTICSEARCH_PORT': str(es_port), 'PROOF_DORIS_PORT': str(doris_port), 'PROOF_POSTGRES_PORT': str(pg_port),
                    'PROOF_DRIVER_PREVIEW_OUTPUT': str(root / '.build/ios-driver-previews')}))
            subprocess.run(['bash', str(root / 'scripts/test-ios-proof.sh'), options.simulator], cwd=root, env=environment, check=True)
        else:
            arguments += ['--extra-args', '-only-testing:QueryCraftMobileProofTests/MobileRedisKeyActionTests', '-only-testing:QueryCraftMobileProofTests/MobileRedisKeyActionStateTests', '-only-testing:QueryCraftMobileProofTests/MobileRedisFieldTTLTests', '-only-testing:QueryCraftMobileProofTests/MobileRedisPagingTests', '-only-testing:QueryCraftMobileProofTests/MobileRedisSearchTests','-only-testing:QueryCraftMobileProofTests/MobileRedisSearchStateTests','-only-testing:QueryCraftMobileProofTests/MobileRedisConsoleTests','-only-testing:QueryCraftMobileProofTests/MobileRedisMutationTests', '-only-testing:QueryCraftMobileProofTests/MobileRedisEditorStateTests', '-only-testing:QueryCraftMobileProofTests/MobileRedisPresentationTests', '-only-testing:QueryCraftMobileProofTests/MobilePostgreSQLTests', '-only-testing:QueryCraftMobileProofTests/MobilePostgreSQLMutationTests', '-only-testing:QueryCraftMobileProofTests/MobilePostgreSQLSessionTests', '-only-testing:QueryCraftMobileProofTests/MobilePostgreSQLPresentationTests', '-only-testing:QueryCraftMobileProofTests/MobileDriverSupportTests', '-only-testing:QueryCraftMobileProofTests/MobileResourcePresentationTests']
            arguments += ['--output', 'json']
            report = root / '.build/ios-validation' / ('driver-support-' + options.simulator + '-tests.json')
            report.parent.mkdir(parents=True, exist_ok=True)
            with report.open('w') as output:
                process = subprocess.run(arguments, cwd=root, stdout=output)
            result = json.loads(report.read_text())
            print(json.dumps(result.get('data', {}).get('summary', {})), flush=True)
            print('Test report: ' + str(report), flush=True)
            if process.returncode or result.get('didError') or result.get('data', {}).get('summary', {}).get('status') != 'SUCCEEDED':
                raise RuntimeError('Mobile driver tests failed; see ' + str(report))
finally:
    if redis is not None:
        redis.terminate()
        try:
            redis.wait(timeout=10)
        except subprocess.TimeoutExpired:
            redis.kill(); redis.wait()
    for name in reversed(containers):
        subprocess.run([docker, 'rm', '--force', '--volumes', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
