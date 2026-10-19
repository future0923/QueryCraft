#!/usr/bin/env python3
"""Disposable six-driver/schema regression. Never uses saved profiles or business DBs.

Run after a Debug build, with DERIVED_DATA set. Images must be available locally.
QC_REGRESSION_PREFIX optionally adopts this task's already-created disposable
containers (qc-schema-* only); otherwise owns and removes freshly created ones.
QC_REGRESSION_KEEP=1 retains fixtures for diagnosis; default removes containers.
"""
from pathlib import Path
import json
import os
import platform
import socket
import socketserver
import threading
import select
import subprocess
import sys
import shutil
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent.parent
DD = Path(os.environ.get('DERIVED_DATA', ROOT / 'output/schema-comparison-build'))
OUT = DD / 'regression'
OUT.mkdir(parents=True, exist_ok=True)
PREFIX = os.environ.get('QC_REGRESSION_PREFIX', 'qc-schema-' + uuid.uuid4().hex[:8])
assert PREFIX.startswith('qc-schema-'), 'Only disposable qc-schema-* containers may be used'
DRIVERS = Path(os.environ.get('QC_REGRESSION_DRIVERS', Path.home() / 'Library/Application Support/QueryCraftDev/DriverAPI-5/Drivers'))
created = []
ports = {}
DOCKER = shutil.which('docker') or '/Applications/Docker.app/Contents/Resources/bin/docker'


def run(args, input=None, timeout=120):
    p = subprocess.run(args, input=input, text=True, capture_output=True, timeout=timeout)
    if p.returncode:
        raise RuntimeError(f'{args[0:3]}: {p.stderr[-2000:]}')
    return p.stdout.strip()


def docker(*args, **kwargs):
    return run([DOCKER, *args], **kwargs)


def name(service):
    return PREFIX + '-' + service


def wait(call, seconds=150):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            return call()
        except Exception as error:
            last = error
            time.sleep(1)
    raise RuntimeError(f'Service did not become ready: {last}')


def sql(service, statement):
    if service == 'postgres':
        return docker('exec', '-i', name(service), 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', input=statement)
    if service == 'doris':
        return docker('exec', '-i', name('mysql84'), 'mysql', '-h', 'host.docker.internal', '-P', str(ports['doris']), '-uroot', '--default-character-set=utf8mb4', '-N', '-B', input=statement)
    return docker('exec', '-i', name(service), 'mysql', '-uroot', '--default-character-set=utf8mb4', '-N', '-B', input=statement)


def http(method, path, data=None):
    request = urllib.request.Request(f'http://127.0.0.1:{ports["es"]}{path}',
        data=json.dumps(data).encode() if data is not None else None, method=method,
        headers={'Content-Type': 'application/json'})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=10) as response:
        return json.load(response)


def fixtures(service):
    # Each schema is owned by this isolated container and this test only.
    schemas = ['source', 'target', 'empty_source', 'empty_target', 'complex_source', 'complex_target', 'escaped_source', 'escaped_target']
    sql(service, '\n'.join(f'CREATE DATABASE qc_schema_{s} CHARACTER SET utf8mb4;' for s in schemas))
    sql(service, """
CREATE TABLE qc_schema_source.orders (id bigint NOT NULL PRIMARY KEY, created_at datetime DEFAULT NULL,
  note varchar(255) DEFAULT NULL COMMENT '买家备注', KEY idx_created_at (created_at));
CREATE TABLE qc_schema_target.orders (id bigint NOT NULL PRIMARY KEY, created_at datetime DEFAULT NULL);
CREATE TABLE qc_schema_source.users (id bigint NOT NULL PRIMARY KEY, email varchar(255) DEFAULT NULL);
CREATE TABLE qc_schema_target.users (id bigint NOT NULL PRIMARY KEY, email varchar(100) DEFAULT NULL);
CREATE TABLE qc_schema_target.legacy_events (id bigint NOT NULL PRIMARY KEY);
CREATE USER 'reader'@'%' IDENTIFIED BY 'fixture-only-password';
GRANT SELECT, SHOW VIEW ON qc_schema_source.* TO 'reader'@'%';
CREATE USER 'limited'@'%' IDENTIFIED BY 'fixture-only-password';
GRANT SELECT ON qc_schema_source.* TO 'limited'@'%';
CREATE TABLE qc_schema_escaped_source.`odd``表` (`id` int, `n``ote` varchar(120) DEFAULT NULL COMMENT '买家,  A  B; /* literal */');
CREATE TABLE qc_schema_escaped_target.`odd``表` (`id` int);
""")
    for side in ['source', 'target']:
        db = f'qc_schema_complex_{side}'
        sql(service, f"""
CREATE TABLE {db}.parents (id int NOT NULL PRIMARY KEY);
CREATE TABLE {db}.complex (id int NOT NULL PRIMARY KEY, parent_id int, value int, note varchar(120),
  computed int GENERATED ALWAYS AS (value + 1) STORED,
  CONSTRAINT fk_parent FOREIGN KEY (parent_id) REFERENCES {db}.parents (id),
  CONSTRAINT ck_positive CHECK (value >= 0), UNIQUE KEY ux_note (note),
  KEY idx_desc (value DESC), KEY idx_prefix (note(8)), KEY idx_func ((abs(value))));
CREATE TABLE {db}.partitioned (id int NOT NULL PRIMARY KEY) PARTITION BY HASH(id) PARTITIONS 2;
CREATE TABLE {db}.hidden (id int, hidden_value int INVISIBLE);
CREATE TABLE {db}.safe (id int);
CREATE VIEW {db}.excluded_view AS SELECT id FROM {db}.safe;
""")
    sql(service, 'ALTER TABLE qc_schema_complex_source.safe ADD note varchar(100) NULL;')
    print('Fixtures ready:', service, flush=True)


def large_fixture():
    sql('mysql84', 'CREATE DATABASE qc_schema_large_source; CREATE DATABASE qc_schema_large_target;')
    commands = []
    for i in range(1000):
        commands += [f'CREATE TABLE qc_schema_large_source.t{i:04d} (id int, note varchar(100) DEFAULT NULL);',
                     f'CREATE TABLE qc_schema_large_target.t{i:04d} (id int);']
    columns = ', '.join(f'c{i:03d} int DEFAULT NULL COMMENT \'字段{i:03d}\'' for i in range(250))
    commands += [f'CREATE TABLE qc_schema_large_source.wide_table ({columns}, note varchar(100) DEFAULT NULL);',
                 f'CREATE TABLE qc_schema_large_target.wide_table ({columns});']
    sql('mysql84', '\n'.join(commands))
    print('1001 tables per side ready', flush=True)


def harness(label, mode, service, **env):
    variables = dict(os.environ, DERIVED_DATA=str(DD), QC_SCHEMA_REGRESSION='1',
        QC_REGRESSION_MODE=mode, QC_REGRESSION_ARCH=platform.machine(),
        QC_REGRESSION_DRIVERS=str(DRIVERS), QC_REGRESSION_OUTPUT=str(OUT),
        QC_SCHEMA_TEST_PORT=str(ports[service]),
        DYLD_FRAMEWORK_PATH=str(DD / 'Build/Products/Debug/PackageFrameworks'), **env)
    binary = DD / 'Build/Products/Debug/schema-comparison-regression'
    args = ['/usr/bin/time', '-l', str(binary)] if binary.exists() else [sys.executable, str(ROOT / 'scripts/test-schema-comparison.py')]
    p = subprocess.run(args, env=variables, capture_output=True, text=True, timeout=600)
    (OUT / f'{label}.log').write_text(p.stdout + p.stderr)
    print(p.stdout.strip(), flush=True)
    if p.returncode or 'PASS ' not in p.stdout:
        raise RuntimeError(f'{label} failed (exit {p.returncode}): {p.stderr[-2500:]}')


class FaultProxy:
    def __init__(self, upstream):
        self.control = OUT / 'proxy-control'
        self.active_file = OUT / 'proxy-active'
        self.control.write_text('pass')
        self.active_file.write_text('0')
        self.lock = threading.Lock()
        self.active = 0
        owner = self
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                with owner.lock:
                    owner.active += 1
                    owner.active_file.write_text(str(owner.active))
                try:
                    with socket.create_connection(('127.0.0.1', upstream), timeout=3) as remote:
                        streams = [self.request, remote]
                        while True:
                            state = owner.control.read_text()
                            if state == 'drop': return
                            if state == 'pause': time.sleep(0.01); continue
                            readable, _, _ = select.select(streams, [], [], 0.02)
                            for stream in readable:
                                data = stream.recv(65536)
                                if not data: return
                                (remote if stream is self.request else self.request).sendall(data)
                except OSError:
                    pass
                finally:
                    with owner.lock:
                        owner.active -= 1
                        owner.active_file.write_text(str(owner.active))
        self.server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
    def close(self):
        self.control.write_text('drop')
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def faults():
    proxy = FaultProxy(ports['mysql84'])
    ports['proxy'] = proxy.server.server_address[1]
    try:
        harness('faults', 'faults', 'proxy', QC_REGRESSION_PROXY_CONTROL=str(proxy.control), QC_REGRESSION_PROXY_ACTIVE=str(proxy.active_file))
    finally:
        proxy.close()


def start():
    # Kafka needs a stable advertised localhost port known before container startup.
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); kafka_port = s.getsockname()[1]
    services = {
        'mysql84': ('mysql:8.4', 3306, ['-e', 'MYSQL_ALLOW_EMPTY_PASSWORD=yes']),
        'mysql80': ('public.ecr.aws/docker/library/mysql:8.0', 3306, ['-e', 'MYSQL_ALLOW_EMPTY_PASSWORD=yes']),
        'postgres': ('postgres:17', 5432, ['-e', 'POSTGRES_HOST_AUTH_METHOD=trust']),
        'redis': ('redis:7.4.2', 6379, []),
        'es': ('docker.elastic.co/elasticsearch/elasticsearch:8.18.0', 9200,
               ['-e', 'discovery.type=single-node', '-e', 'xpack.security.enabled=false', '-e', 'ES_JAVA_OPTS=-Xms512m -Xmx512m']),
        'doris': ('apache/doris:all-in-one-4.1.3', 9030, []),
        'kafka': ('apache/kafka:3.9.1', 9092, sum((['-e', v] for v in [
            'KAFKA_NODE_ID=1', 'KAFKA_PROCESS_ROLES=broker,controller',
            'KAFKA_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093,INTERNAL://:9094',
            f'KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://127.0.0.1:{kafka_port},INTERNAL://localhost:9094',
            'KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER', 'KAFKA_INTER_BROKER_LISTENER_NAME=INTERNAL',
            'KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,INTERNAL:PLAINTEXT',
            'KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9093', 'KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1',
            'KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1', 'KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1']), []))}
    for service, (image, port, options) in services.items():
        if not os.environ.get('QC_REGRESSION_PREFIX'):
            binding = f'127.0.0.1:{kafka_port if service == "kafka" else ""}:{port}'
            docker('run', '-d', '--rm', '--name', name(service), '-p', binding, *options, image)
        created.append(name(service))
        ports[service] = int(json.loads(docker('inspect', name(service)))[0]['NetworkSettings']['Ports'][f'{port}/tcp'][0]['HostPort'])
    (OUT / 'ports.json').write_text(json.dumps(ports, indent=2))


def main():
    # Always compile against the completed build; never reuse a stale harness.
    subprocess.run([sys.executable, str(ROOT / 'scripts/test-schema-comparison.py')],
                   env=dict(os.environ, DERIVED_DATA=str(DD), QC_SCHEMA_REGRESSION='1',
                            QC_SCHEMA_COMPILE_ONLY='1'), check=True)
    start()
    for service in ['mysql84', 'mysql80']:
        wait(lambda: sql(service, 'SELECT version();'))
        fixtures(service)
    harness('mysql84', 'mysql', 'mysql84', QC_REGRESSION_OTHER_PORT=str(ports['mysql80']))
    harness('mysql80', 'mysql', 'mysql80', QC_REGRESSION_OTHER_PORT=str(ports['mysql84']))
    faults()
    harness('native', 'native', 'mysql84')
    for service in ['mysql84', 'mysql80']:
        for stem in ['schema', 'escaped']:
            sql(service, (OUT / f'{stem}-{ports[service]}.sql').read_text())
        assert sql(service, "SELECT HEX(COLUMN_COMMENT) FROM information_schema.columns WHERE TABLE_SCHEMA='qc_schema_target' AND TABLE_NAME='orders' AND COLUMN_NAME='note';") == 'E4B9B0E5AEB6E5A487E6B3A8'
        assert sql(service, "SELECT count(*) FROM information_schema.statistics WHERE TABLE_SCHEMA='qc_schema_target' AND INDEX_NAME='idx_created_at';") == '1'
        assert sql(service, "SELECT count(*) FROM information_schema.tables WHERE TABLE_SCHEMA='qc_schema_target' AND TABLE_NAME='legacy_events';") == '1'
        print('PASS exported SQL apply/UTF-8/target-only retention:', service, flush=True)
    large_fixture()
    harness('performance', 'performance', 'mysql84')
    driver_smoke()


def driver_smoke():
    wait(lambda: sql('postgres', 'SELECT 1;'))
    wait(lambda: sql('doris', 'SELECT 1;'))
    wait(lambda: http('GET', '/'))
    for service in ['mysql84', 'postgres', 'doris']:
        if service == 'postgres':
            sql(service, "CREATE TABLE qc_schema_smoke (id int, note varchar(100)); INSERT INTO qc_schema_smoke VALUES (1, '回归验证');")
        elif service == 'doris':
            sql(service, "CREATE DATABASE qc_schema_smoke_db; CREATE TABLE qc_schema_smoke_db.qc_schema_smoke (id int, note varchar(100)) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ('replication_num'='1'); INSERT INTO qc_schema_smoke_db.qc_schema_smoke VALUES (1, '回归验证');")
        else:
            sql(service, "CREATE TABLE qc_schema_source.qc_schema_smoke (id int, note varchar(100)); INSERT INTO qc_schema_source.qc_schema_smoke VALUES (1, '回归验证');")
    docker('exec', name('redis'), 'redis-cli', 'SET', 'qc_schema_smoke', '回归验证')
    http('PUT', '/qc_schema_smoke', {'mappings': {'properties': {'id': {'type': 'integer'}, 'note': {'type': 'keyword'}}}})
    http('PUT', '/qc_schema_smoke/_doc/1?refresh=true', {'id': 1, 'note': '回归验证'})
    wait(lambda: docker('exec', name('kafka'), '/opt/kafka/bin/kafka-topics.sh', '--bootstrap-server', 'localhost:9094', '--create', '--if-not-exists', '--topic', 'qc_schema_smoke', '--partitions', '1', '--replication-factor', '1'))
    docker('exec', '-i', name('kafka'), '/opt/kafka/bin/kafka-console-producer.sh', '--bootstrap-server', 'localhost:9094', '--topic', 'qc_schema_smoke', input='{"id":1,"note":"回归验证"}\n')
    for service, title, type_, db in [('mysql84', 'MySQL', 'mysql', 'qc_schema_source'), ('postgres', 'PostgreSQL', 'postgresql', 'postgres'), ('doris', 'Doris', 'doris', 'qc_schema_smoke_db'), ('redis', 'Redis', 'redis', 'DB 0'), ('es', 'Elasticsearch', 'elasticsearch', 'Elasticsearch'), ('kafka', 'Kafka', 'kafka', 'Kafka')]:
        harness(title, 'drivers', service, QC_REGRESSION_DRIVER=title, QC_REGRESSION_TYPE=type_, QC_REGRESSION_DATABASE=db)


if __name__ == '__main__':
    try:
        main()
    finally:
        if os.environ.get('QC_REGRESSION_KEEP') != '1':
            for container in reversed(created):
                subprocess.run([DOCKER, 'stop', container], capture_output=True, timeout=45)
