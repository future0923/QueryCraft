#!/usr/bin/env python3
"""Run physical iOS/iPadOS native/live acceptance against disposable LAN fixtures.

Never imports saved credentials, edits device connection libraries, or uninstalls apps.
Use the Xcode destination UDID, not its separate CoreDevice identifier.
"""
import argparse
import ipaddress
import json
import pathlib
import shutil
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--device-id', required=True)
parser.add_argument('--host', required=True, help='This Mac LAN address reachable by iPad')
parser.add_argument('--team-id', required=True)
parser.add_argument('--output-dir', default='.build/ipad-physical')
parser.add_argument('--derived-data-path', help='Reuse an existing build for the same universal device target')
args = parser.parse_args()
if not ipaddress.ip_address(args.host).is_private:
    parser.error('Use a private LAN address')
root = pathlib.Path(__file__).resolve().parents[1]
output = root / args.output_dir
output.mkdir(parents=True, exist_ok=True)
derived_data = pathlib.Path(args.derived_data_path) if args.derived_data_path else output / 'DerivedData'
docker = shutil.which('docker')
if not docker:
    parser.error('Docker is required for disposable fixtures')
owner = str(uuid.uuid4())
label = 'querycraft.ipad.acceptance=' + owner
owned = []
password = uuid.uuid4().hex


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)


def container(image, port, options=(), command=()):
    name = 'qc-ipad-physical-' + uuid.uuid4().hex[:12]
    run([docker, 'run', '--detach', '--rm', '--name', name, '--label', label,
         '--publish', args.host + '::' + str(port), *options, image, *command], stdout=subprocess.DEVNULL)
    owned.append(name)
    mapping = subprocess.check_output([docker, 'port', name, str(port) + '/tcp'], text=True).strip()
    return name, mapping.rsplit(':', 1)[1]


def wait(name, command, seconds=180):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            print('READY', name, flush=True)
            return
        time.sleep(1)
    raise RuntimeError(name + ' fixture did not become ready')


def test(name, selectors, env):
    command = ['xcodebuildmcp', 'device', 'test', '--project-path',
               str(root / 'QueryCraftMobile/QueryCraftMobile.xcodeproj'), '--scheme', 'QueryCraftMobileProof',
               '--device-id', args.device_id, '--derived-data-path', str(derived_data),
               '--configuration', 'Debug', '--output', 'json', '--json', json.dumps({'testRunnerEnv': env}),
               '--extra-args', 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_STYLE=Automatic',
               'DEVELOPMENT_TEAM=' + args.team_id, 'CODE_SIGN_IDENTITY=Apple Development',
               '-allowProvisioningUpdates', '-parallel-testing-enabled', 'NO']
    command += ['-only-testing:QueryCraftMobileProofTests/' + selector for selector in selectors]
    path = output / (name + '.json')
    with path.open('w') as stream:
        result = subprocess.run(command, cwd=root, stdout=stream)
    report = json.loads(path.read_text())
    summary = report.get('data', {}).get('summary', {})
    print(name, json.dumps(summary), flush=True)
    if result.returncode or report.get('didError') or summary.get('status') != 'SUCCEEDED':
        raise RuntimeError('Physical test failed; inspect ' + str(path))


try:
    mysql, mysql_port = container('mysql:8.4', 3306, ['--env', 'MYSQL_ROOT_PASSWORD=' + password])
    # Container entrypoints briefly start a socket-only bootstrap server. Wait
    # for the final TCP listener, otherwise fixture SQL can race its shutdown.
    mq = [docker, 'exec', '--env', 'MYSQL_PWD=' + password, mysql, 'mysql',
          '--protocol=tcp', '-h127.0.0.1', '-uroot', '--default-character-set=utf8mb4', '-N']
    wait('MySQL', mq + ['-e', 'SELECT 1'])
    run(mq + ['-e', "CREATE DATABASE physical_acceptance CHARACTER SET utf8mb4; CREATE USER 'physical_acceptance'@'%' IDENTIFIED BY '" + password + "'; GRANT ALL ON physical_acceptance.* TO 'physical_acceptance'@'%';"], stdout=subprocess.DEVNULL)
    pg, pg_port = container('postgres:17', 5432, ['--env', 'POSTGRES_PASSWORD=' + password,
        '--env', 'POSTGRES_USER=physical_acceptance', '--env', 'POSTGRES_DB=physical_acceptance'])
    pq = [docker, 'exec', '--env', 'PGPASSWORD=' + password, pg, 'psql', '-h127.0.0.1',
          '-U', 'physical_acceptance', '-d', 'physical_acceptance', '-Atc']
    wait('PostgreSQL', pq + ['SELECT 1'])
    redis, redis_port = container('redis:7.4.2', 6379)
    rq = [docker, 'exec', redis, 'redis-cli', '--raw']
    wait('Redis', rq + ['PING'])
    for command in [['SET', 'querycraft-proof:string', '你好 Redis'], ['RPUSH', 'querycraft-proof:list', 'first'],
                    ['HSET', 'querycraft-proof:hash', 'field', 'value'], ['SADD', 'querycraft-proof:set', 'member'],
                    ['ZADD', 'querycraft-proof:zset', '1', 'member']]:
        run(rq + command, stdout=subprocess.DEVNULL)
    es, es_port = container('docker.elastic.co/elasticsearch/elasticsearch:8.18.0', 9200,
        ['--env', 'discovery.type=single-node', '--env', 'xpack.security.enabled=false', '--env', 'ES_JAVA_OPTS=-Xms512m -Xmx512m'])
    url = 'http://' + args.host + ':' + es_port
    wait('Elasticsearch', ['curl', '--fail', '--silent', '--noproxy', '*', url])
    def es_request(method, path, data):
        run(['curl', '--fail', '--silent', '--show-error', '--noproxy', '*', '-X', method, url + path,
             '-H', 'Content-Type: application/json', '--data-binary', data], stdout=subprocess.DEVNULL)
    es_request('PUT', '/querycraft-ios-proof', '{"mappings":{"properties":{"name":{"type":"text"}}}}')
    es_request('PUT', '/querycraft-ios-proof/_doc/one?refresh=true', '{"name":"你好 Elasticsearch"}')
    es_request('POST', '/_aliases', '{"actions":[{"add":{"index":"querycraft-ios-proof","alias":"querycraft-ios-alias"}}]}')
    doris, doris_port = container('apache/doris:all-in-one-4.1.3', 9030, ['--env', 'FE_HEAP=768m', '--env', 'BE_HEAP=512m'])
    dq = [docker, 'exec', doris, 'mysql', '-h127.0.0.1', '-P9030', '-uroot', '--default-character-set=utf8mb4', '-N', '-e']
    wait('Doris', dq + ['SELECT 1'])
    run(dq + ['CREATE DATABASE querycraft_ios_drivers'], stdout=subprocess.DEVNULL)
    wait('Doris backend', dq + ["CREATE TABLE IF NOT EXISTS querycraft_ios_drivers.sample (id INT, name VARCHAR(80) COMMENT '真实字段注释') DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ('replication_num'='1')"])
    run(dq + ["INSERT INTO querycraft_ios_drivers.sample VALUES (1,'你好 Doris'),(2,'second');"], stdout=subprocess.DEVNULL)
    env = {'PROOF_SERVER_HOST': args.host, 'PROOF_REDIS_PORT': redis_port,
           'PROOF_DORIS_PORT': doris_port, 'PROOF_ELASTICSEARCH_PORT': es_port,
           'QUERYCRAFT_PHYSICAL_SQL_ACCEPTANCE': '1', 'QUERYCRAFT_PHYSICAL_SQL_OWNER': owner,
           'QUERYCRAFT_PHYSICAL_MYSQL_HOST': args.host, 'QUERYCRAFT_PHYSICAL_MYSQL_PORT': mysql_port,
           'QUERYCRAFT_PHYSICAL_MYSQL_PASSWORD': password,
           'QUERYCRAFT_PHYSICAL_PG_HOST': args.host, 'QUERYCRAFT_PHYSICAL_PG_PORT': pg_port,
           'QUERYCRAFT_PHYSICAL_PG_PASSWORD': password,
           'QUERYCRAFT_PHYSICAL_REDIS_ACCEPTANCE': '1', 'QUERYCRAFT_PHYSICAL_REDIS_OWNER': owner,
           'QUERYCRAFT_PHYSICAL_REDIS_HOST': args.host, 'QUERYCRAFT_PHYSICAL_REDIS_PORT': redis_port}
    suites = ['MobileDriverSupportTests', 'MobileDorisParityTests', 'MobileElasticsearchTests',
              'MobileCanvasPresentationTests', 'MobileSwitchPresentationTests', 'MobileActionLayoutPresentationTests',
              'MobileConnectionPresentationTests', 'MobileSQLExecutionPresentationTests', 'MobileSQLFormattingPresentationTests',
              'MobileQueryBatchPresentationTests', 'MobileQueryEditingPresentationTests', 'MobileSchemaPresentationTests',
              'MobileNewTablePresentationTests', 'MobileTableOptionsPresentationTests', 'MobileTableActionPresentationTests',
              'MobileResourcePresentationTests', 'MobileRedisTypePresentationTests', 'MobileElasticsearchPresentationTests',
              'MobileElasticsearchStateTests', 'MobileSQLSnippetPresentationTests', 'MobileWorkspaceLayoutTests',
              'MobileFilterViewportTests', 'MobileGridAxisLockTests', 'MobileGridFindNavigationTests',
              'MobileGridFullscreenTests', 'MobileSurfaceEditingPresentationTests', 'MobilePersistentWorkspaceTests',
              'MobileEditorPreferenceTests', 'MobileSQLAndGridTests', 'MobileConnectionReliabilityTests',
              'MobilePhysicalSQLAcceptanceTests/testPhysicalMySQLNativeInputFilterAndEditing',
              'MobilePhysicalSQLAcceptanceTests/testPhysicalPostgreSQLNativeInputFilterAndEditing',
              'MobileRedisMemberInputPresentationTests/testPhysicalHashInputCreateUpdateAndCleanup',
              'MobileRedisMemberInputPresentationTests/testTypingIntoCreationRowsDoesNotPerformFormRowDelete']
    test('native-and-five-drivers', suites, env)
    test('independent-cleanup', ['MobilePhysicalSQLAcceptanceTests/testPhysicalMySQLCleanup',
                                'MobileRedisMemberInputPresentationTests/testPhysicalRedisCleanup'], env)
    for engine, command in [('MySQL', mq + ['-e', "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='physical_acceptance' AND table_name LIKE 'qc_ios_admin_user_%'"]),
                            ('PostgreSQL', pq + ["SELECT COUNT(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'qc_ios_admin_user_%'"]),
                            ('Redis', rq + ['EXISTS', '__querycraft_ios_acceptance__:' + owner])]:
        assert subprocess.check_output(command, text=True).strip() == '0', engine + ' fixture remained'
    (output / 'verification.json').write_text(json.dumps({'owner': owner, 'device': args.device_id,
        'nativeAndFiveDriversPassed': True, 'independentCleanupPassed': True,
        'businessProfilesUnchanged': True, 'fixtureAbsenceVerified': ['mysql', 'postgresql', 'redis']}, indent=2) + '\n')
    print('PASS physical device acceptance and server-side fixture absence', flush=True)
finally:
    cleaned = []
    for name in reversed(owned):
        state = subprocess.run([docker, 'inspect', '--format', '{{ index .Config.Labels "querycraft.ipad.acceptance" }}', name], capture_output=True, text=True)
        if state.returncode == 0 and state.stdout.strip() == owner:
            run([docker, 'rm', '--force', '--volumes', name], stdout=subprocess.DEVNULL)
            cleaned.append(name)
    (output / 'container-cleanup.json').write_text(json.dumps({'owner': owner, 'created': owned, 'removed': cleaned}, indent=2) + '\n')
    if len(cleaned) != len(owned):
        raise RuntimeError('Not all owned fixture containers were removed; inspect cleanup receipt')
