#!/usr/bin/env python3
"""Persistent, localhost-only user demo; never connects to an existing DB server."""
from pathlib import Path
import argparse, ast, json, os, shutil, socket, subprocess, time

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'output/schema-comparison-build/user-demo'
DOCKER = shutil.which('docker') or '/Applications/Docker.app/Contents/Resources/bin/docker'
OWNER = str(ROOT)
LABEL = 'io.querycraft.schema-demo.workspace'
SPECS = {
    'source': ('qc-schema-demo-0b02-source', 'public.ecr.aws/docker/library/mysql:5.7', 13357, 'qc_demo_source'),
    'target': ('qc-schema-demo-0b02-target', 'public.ecr.aws/docker/library/mysql:8.0', 13380, 'qc_demo_target'),
}

def run(args, text=None, timeout=120):
    p = subprocess.run([str(x) for x in args], input=text, text=True, capture_output=True, timeout=timeout)
    if p.returncode: raise RuntimeError(p.stderr[-2000:])
    return p.stdout.strip()

def inspect(name, kind='container'):
    p = subprocess.run([DOCKER, kind, 'inspect', name], text=True, capture_output=True)
    return json.loads(p.stdout)[0] if p.returncode == 0 else None

def owned(role):
    name = SPECS[role][0]
    item = inspect(name)
    if item:
        labels = item['Config'].get('Labels') or {}
        if labels.get(LABEL) != OWNER or labels.get('io.querycraft.schema-demo.role') != role:
            raise RuntimeError('Refusing a container not owned by this demo: ' + name)
    return item

def sql(role, value):
    owned(role) or (_ for _ in ()).throw(RuntimeError('Demo container missing'))
    return run([DOCKER, 'exec', '-i', SPECS[role][0], 'mysql', '--protocol=TCP', '-h127.0.0.1', '-uroot', '--default-character-set=utf8mb4', '-N', '-B'], value)

def fixture(role):
    tree = ast.parse((ROOT/'scripts/test-schema-comparison-full-native.py').read_text())
    start = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'start')
    block = next(n.value for n in ast.walk(start) if isinstance(n, ast.Constant) and isinstance(n.value, str) and 'CREATE DATABASE qc_schema_source' in n.value)
    schema = 'qc_schema_' + role
    prefixes = ('CREATE DATABASE ', 'CREATE TABLE ', 'CREATE VIEW ', 'CREATE TRIGGER ', 'CREATE FUNCTION ', 'CREATE PROCEDURE ', 'INSERT INTO ')
    lines = [line for line in block.splitlines() if line.startswith('DELIMITER ') or line.startswith(prefixes) and schema + '.' in line or line.startswith('CREATE DATABASE ' + schema + ' ')]
    result = '\n'.join(lines).replace(schema, SPECS[role][3]) + '\n'
    other = 'qc_schema_target' if role == 'source' else 'qc_schema_source'
    assert other not in result and 'GRANT ' not in result
    return result

def ensure(role):
    name, image, preferred, database = SPECS[role]
    item = owned(role)
    if not item:
        volume = name + '-data'
        existing = inspect(volume, 'volume')
        if existing and (existing.get('Labels') or {}).get(LABEL) != OWNER:
            raise RuntimeError('Refusing an unrelated volume: ' + volume)
        if not existing: run([DOCKER, 'volume', 'create', '--label', LABEL+'='+OWNER, volume])
        with socket.socket() as probe:
            try: probe.bind(('127.0.0.1', preferred)); port = preferred
            except OSError: probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
        run([DOCKER, 'run', '-d', '--name', name, '--label', LABEL+'='+OWNER,
             '--label', 'io.querycraft.schema-demo.role='+role, '-e', 'MYSQL_ALLOW_EMPTY_PASSWORD=yes',
             '-p', '127.0.0.1:'+str(port)+':3306', '--mount', 'type=volume,src='+volume+',dst=/var/lib/mysql',
             image, '--character-set-server=utf8mb4', '--collation-server=utf8mb4_general_ci',
             '--performance-schema=OFF', '--innodb-buffer-pool-size=64M'])
    elif not item['State']['Running']: run([DOCKER, 'start', name])
    deadline = time.monotonic() + 180
    while True:
        try: version = sql(role, 'SELECT @@version;'); break
        except RuntimeError:
            if time.monotonic() >= deadline: raise
            time.sleep(0.5)
    item = owned(role)
    bindings = item['NetworkSettings']['Ports']['3306/tcp']
    assert len(bindings) == 1 and bindings[0]['HostIp'] == '127.0.0.1'
    return dict(container=name, image=image, version=version, host='127.0.0.1', port=int(bindings[0]['HostPort']), database=database)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['setup', 'reset', 'start', 'stop', 'status'], nargs='?', default='setup')
    mode = parser.parse_args().mode
    OUT.mkdir(parents=True, exist_ok=True)
    context = json.loads(run([DOCKER, 'context', 'inspect']))[0]
    endpoint = os.environ.get('DOCKER_HOST') or context['Endpoints']['docker']['Host']
    if not endpoint.startswith('unix://'): raise RuntimeError('This demo only runs on a local Docker Unix socket.')
    ready = subprocess.run([DOCKER, 'info', '--format', '{{.ServerVersion}}'], capture_output=True).returncode == 0
    if not ready and mode in ['setup', 'reset', 'start']:
        run(['/usr/bin/open', '-g', '-a', 'Docker'])
        deadline = time.monotonic() + 120
        while not ready:
            if time.monotonic() >= deadline: raise RuntimeError('Docker Desktop did not become ready.')
            time.sleep(1)
            ready = subprocess.run([DOCKER, 'info', '--format', '{{.ServerVersion}}'], capture_output=True).returncode == 0
    if not ready:
        print('Docker Desktop is not running; demo data is retained in its volumes.')
        return
    if mode in ['stop', 'status']:
        for role in SPECS:
            item = owned(role)
            if mode == 'stop' and item and item['State']['Running']: run([DOCKER, 'stop', SPECS[role][0]])
            print(role, item['State']['Status'] if item else 'not created')
        return
    manifest = {'owner': OWNER, 'source': ensure('source'), 'target': ensure('target')}
    for role in SPECS:
        schema = SPECS[role][3]
        seed = fixture(role)
        (OUT/(role+'.sql')).write_text(seed)
        exists = sql(role, "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='"+schema+"';") == '1'
        if mode == 'reset': sql(role, 'DROP DATABASE IF EXISTS `'+schema+'`;'); exists = False
        if not exists: sql(role, seed)
        print('READY', role, manifest[role]['version'], '127.0.0.1:'+str(manifest[role]['port']), schema, flush=True)
    (OUT/'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False))
    for mode, title in [('reset','重置演练'),('start','启动演练'),('stop','停止演练')]:
        import shlex
        command = '#!/bin/zsh\n/usr/bin/python3 '+shlex.quote(str(Path(__file__).resolve()))+' '+mode+'\n'
        path = OUT/(title+'.command'); path.write_text(command); path.chmod(0o755)

if __name__ == '__main__': main()
