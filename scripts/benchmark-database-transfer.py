#!/usr/bin/env python3
"""Benchmark the real transfer manager with installed drivers and isolated Docker fixtures.

No saved connections are read. Three uniquely named containers are removed on exit.
Results, process RSS samples and JSONL progress remain in .build/validation/transfer-performance.
"""
import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import subprocess
import time
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--rows', type=int, nargs='+', default=[1_000_000])
parser.add_argument('--cases', nargs='+', default=['mysql-mysql', 'postgresql-postgresql', 'mysql-postgresql', 'postgresql-mysql'],
                    choices=['mysql-mysql', 'postgresql-postgresql', 'mysql-postgresql', 'postgresql-mysql'])
parser.add_argument('--batch', type=int, default=1000)
parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Release')
parser.add_argument('--skip-cancellation', action='store_true')
parser.add_argument('--load-only', action='store_true')
parser.add_argument('--timeout', type=int, default=3600)
parser.add_argument('--driver-root', type=Path, default=Path.home()/'Library/Application Support/QueryCraftDev/DriverAPI-5/Drivers')
parser.add_argument('--require-native', action='store_true')
parser.add_argument('--disable-mysql-local', action='store_true', help='Verify fallback without modifying any existing server')
parser.add_argument('--regression-only', action='store_true', help='Run the 203-row feature/edge matrix in owned containers')
parser.add_argument('--strategies', nargs='+', choices=['append','upsert','overwrite','rebuild'], default=['append'])
parser.add_argument('--compile-only', action='store_true')
parser.add_argument('--doris-smoke', action='store_true')
parser.add_argument('--doris-port', type=int)
args = parser.parse_args()
if any(n < 1 for n in args.rows) or not 100 <= args.batch <= 10000:
    parser.error('Positive row counts and batch size 100–10000 required')
root = Path(__file__).resolve().parent.parent
token = time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6]
output = root / '.build/validation/transfer-performance' / token
output.mkdir(parents=True)
docker = '/Applications/Docker.app/Contents/Resources/bin/docker'
dd = root / '.build/DerivedData'
products = dd / ('Build/Products/' + args.configuration)
# PackageFrameworks may be stale after an incremental app build. Use the actual app's framework.
frameworks = products / 'QueryCraft.app/Contents/Frameworks'
compiler = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
sdk = subprocess.check_output(['xcode-select', '-p'], text=True).strip() + '/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
command = [compiler, '-O', '-parse-as-library', '-target', platform.machine() + '-apple-macosx15.0', '-sdk', sdk,
           str(root / ('scripts/test-native-doris.swift' if args.doris_smoke else 'scripts/test-database-transfer.swift' if args.regression_only else 'scripts/benchmark-database-transfer.swift')), '-I', str(products),
           '-F', str(dd / 'SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64'), '-F', str(frameworks),
           '-framework', 'QueryCraftFeature', '-o', str(output / 'benchmark'), '-Xlinker', '-rpath', '-Xlinker', str(frameworks)]
maps = list((dd / 'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
maps += sorted((dd / 'SourcePackages/checkouts').rglob('module.modulemap'))
seen = set()
for path in maps:
    if '/Tests/' in str(path):
        continue
    match = re.search(r'\bmodule\s+(\w+)', path.read_text())
    if match and match[1] not in seen:
        command += ['-Xcc', '-fmodule-map-file=' + str(path)]
        seen.add(match[1])
for path in [root / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include', root / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include',
             dd / 'SourcePackages/checkouts/tree-sitter/lib/include', dd / 'SourcePackages/checkouts/TextStory/Sources/Internal',
             root / 'ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include']:
    command += ['-Xcc', '-I' + str(path)]
subprocess.run(command, check=True)
def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1_048_576), b''): hasher.update(chunk)
    return hasher.hexdigest()

host_binary = frameworks/'QueryCraftFeature.framework/QueryCraftFeature'
provenance = dict(configuration=args.configuration, host_framework_sha256=digest(host_binary),
                  host_framework_uuid=subprocess.check_output(['/usr/bin/dwarfdump','--uuid',str(host_binary)],text=True).strip(), drivers={})
for bundle in args.driver_root.resolve().glob('*.querycraftdriver'):
    info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
    binary=bundle/'Contents/MacOS'/info['CFBundleExecutable']
    provenance['drivers'][bundle.name]=dict(version=info.get('CFBundleShortVersionString'),build=info.get('CFBundleVersion'),
                                           api=info.get('QCDriverAPIVersion'),minimum_app=info.get('QCMinimumAppVersion'),sha256=digest(binary))
(output/'provenance.json').write_text(json.dumps(provenance,indent=2))
if args.compile_only:
    print(json.dumps(dict(event='compiled', binary=str(output/'benchmark'))), flush=True)
    raise SystemExit(0)
secret = uuid.uuid4().hex
containers = []
results = []
base = 9007199254740992


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def sql(endpoint, text, timeout=600):
    if endpoint['type'] == 'postgresql':
        cmd = [docker, 'exec', '-i', endpoint['container'], 'sh', '-c',
               'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -h 127.0.0.1 -X -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres']
    else:
        cmd = [docker, 'exec', '-i', endpoint['container'], 'sh', '-c',
               'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql --protocol=TCP -h 127.0.0.1 -u root --default-character-set=utf8mb4 -N -B']
    done = subprocess.run(cmd, input=text, text=True, capture_output=True, timeout=timeout)
    if done.returncode:
        raise RuntimeError(done.stderr.strip())
    return done.stdout.strip()


def launch(label, image, kind):
    name = 'qc-large-' + token + '-' + label
    port = '5432' if kind == 'postgresql' else '3306'
    cmd = [docker, 'run', '-d', '--name', name, '--memory', '2g', '--cpus', '4', '-p', '127.0.0.1::' + port]
    cmd += ['-e', ('POSTGRES_PASSWORD=' if kind == 'postgresql' else 'MYSQL_ROOT_PASSWORD=') + secret, image]
    if kind != 'postgresql':
        cmd += ['--character-set-server=utf8mb4', '--collation-server=utf8mb4_bin', '--innodb-buffer-pool-size=268435456', '--max-allowed-packet=67108864',
                '--local-infile=' + ('0' if args.disable_mysql_local else '1')]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    containers.append(name)
    item = json.loads(subprocess.check_output([docker, 'inspect', name]))[0]
    endpoint = dict(type=kind, container=name, port=item['NetworkSettings']['Ports'][port + '/tcp'][0]['HostPort'])
    for _ in range(120):
        try:
            if sql(endpoint, 'SELECT 1', timeout=5) == '1':
                emit(dict(event='container_ready', name=name, image=image)); return endpoint
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
        time.sleep(0.5)
    raise RuntimeError('Isolated database did not become ready: ' + name)


def qualified(endpoint, namespace):
    q = '"' if endpoint['type'] == 'postgresql' else '`'
    return f'{q}{namespace}{q}.{q}large_rows{q}'


def expressions(endpoint, id_expr='id'):
    n = f'({id_expr}-{base})'
    if endpoint['type'] == 'postgresql':
        combining = f"CASE WHEN {n}%17=0 THEN chr(769) ELSE '' END"
        payload = f"CASE WHEN {n}%11=0 THEN NULL WHEN {n}%13=0 THEN '' ELSE repeat('数据🙂',12)||':'||{id_expr}::text||chr(39)||({combining})||chr(92)||({combining})||chr(10) END"
        raw = f"decode(md5({id_expr}::text||'bytes'),'hex')"
        flag = f'({n}%2=0)'
    else:
        combining = f"CASE WHEN MOD({n},17)=0 THEN CONVERT(X'CC81' USING utf8mb4) ELSE '' END"
        payload = f"CASE WHEN MOD({n},11)=0 THEN NULL WHEN MOD({n},13)=0 THEN '' ELSE CONCAT(REPEAT('数据🙂',12),':',{id_expr},CHAR(39),{combining},CHAR(92),{combining},CHAR(10)) END"
        raw = f"UNHEX(MD5(CONCAT({id_expr},'bytes')))"
        flag = f'(MOD({n},2)=0)'
    amount = f'CAST(123456789012345678901.123456789 AS DECIMAL(30,9)) + MOD({n},1000)*0.000000001'
    return payload, amount, raw, flag


def namespace(endpoint, name):
    sql(endpoint, ('CREATE SCHEMA ' if endpoint['type'] == 'postgresql' else 'CREATE DATABASE ') + name)


def seed(endpoint, count, old=0):
    table = qualified(endpoint, 'source_data')
    if old == 0:
        namespace(endpoint, 'source_data')
        sql(endpoint, f'CREATE TABLE {table} (id BIGINT PRIMARY KEY, payload TEXT, amount DECIMAL(30,9), raw ' +
            ('BYTEA' if endpoint['type'] == 'postgresql' else 'BLOB') + ', flag BOOLEAN)')
        if endpoint['type'] != 'postgresql':
            sql(endpoint, 'CREATE TABLE source_data.digits(d INT PRIMARY KEY); INSERT INTO source_data.digits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)')
    start = time.monotonic()
    payload, amount, raw, flag = expressions(endpoint)
    for offset in range(old, count, 100_000):
        size = min(100_000, count - offset)
        if endpoint['type'] == 'postgresql':
            ids = f'SELECT {base}+n AS id FROM generate_series({offset+1},{offset+size}) AS n'
        else:
            number = '+'.join(f'd{i}.d*{10**i}' for i in range(5))
            digits = ' CROSS JOIN '.join(f'source_data.digits d{i}' for i in range(5))
            ids = f'SELECT {base}+{offset}+1+{number} AS id FROM {digits} WHERE {number}<{size}'
        sql(endpoint, f'INSERT INTO {table} (id,payload,amount,raw,flag) SELECT id,{payload},{amount},{raw},{flag} FROM ({ids}) generated_ids')
    emit(dict(event='seeded', type=endpoint['type'], rows=count, seconds=time.monotonic()-start))


def verify(endpoint, name, expected, exact=True):
    table = qualified(endpoint, name)
    payload, amount, raw, flag = expressions(endpoint)
    equal = 'IS NOT DISTINCT FROM' if endpoint['type'] == 'postgresql' else '<=>'
    if endpoint['type'] == 'postgresql':
        # MySQL BOOLEAN is tinyint(1), which is correctly preserved as smallint
        # across engines. Accept the exact boolean value in either representation.
        bool_value = "CASE WHEN flag::text IN ('t','true','1') THEN TRUE WHEN flag::text IN ('f','false','0') THEN FALSE ELSE NULL END"
        bad = f'CASE WHEN (payload {equal} ({payload})) AND amount=({amount}) AND raw=({raw}) AND ({bool_value})=({flag}) THEN 0 ELSE 1 END'
    else:
        bad = f'CASE WHEN (BINARY payload {equal} BINARY ({payload})) AND amount=({amount}) AND raw=({raw}) AND flag=({flag}) THEN 0 ELSE 1 END'
    row = sql(endpoint, f'SELECT COUNT(*),COALESCE(SUM(id-{base}),0),COALESCE(SUM({bad}),0) FROM {table}')
    count, total, invalid = map(int, row.split('\t' if endpoint['type'] != 'postgresql' else '|'))
    if count != expected or invalid or exact and total != expected*(expected+1)//2:
        raise RuntimeError(f'Full-row verification failed: count={count}, expected={expected}, sum={total}, invalid={invalid}')
    return dict(rows=count, id_sum=total, invalid_rows=invalid)


def benchmark(source, target, rows, label, strategy='append', cancel_after=0, cancel_phase='read'):
    name = 'target_' + uuid.uuid4().hex[:10]
    namespace(target, name)
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(frameworks),
               BENCH_DRIVER_ROOT=str(args.driver_root.resolve()), BENCH_REQUIRE_NATIVE='1' if args.require_native else '0',
               BENCH_BATCH=str(args.batch), BENCH_HISTORY=str(output/(label+'-history.json')), BENCH_STRATEGY=strategy,
               BENCH_CANCEL_AFTER=str(cancel_after), BENCH_CANCEL_FILE=str(output/(label+'-cancel')),
               BENCH_CANCEL_PHASE=cancel_phase, BENCH_FILTER=f'id<={base+rows}')
    for side, endpoint, space in [('SOURCE', source, 'source_data'), ('TARGET', target, name)]:
        env.update({f'BENCH_{side}_TYPE': endpoint['type'], f'BENCH_{side}_PORT': endpoint['port'],
                    f'BENCH_{side}_PASSWORD': secret, f'BENCH_{side}_DATABASE': 'postgres' if endpoint['type']=='postgresql' else space,
                    f'BENCH_{side}_SCHEMA': space if endpoint['type']=='postgresql' else ''})
    if strategy in ['overwrite','upsert']:
        table = qualified(target, name)
        sql(target, f'CREATE TABLE {table} (id BIGINT PRIMARY KEY, payload TEXT, amount DECIMAL(30,9), raw '+('BYTEA' if target['type']=='postgresql' else 'BLOB')+', flag BOOLEAN)')
        if strategy == 'overwrite':
            payload, amount, raw, flag = expressions(target, str(base+1))
            sql(target, f'INSERT INTO {table} VALUES ({base+1},{payload},{amount},{raw},{flag})')
        else:
            if target['type'] != 'postgresql':
                sql(target, f'CREATE TABLE {name}.digits(d INT PRIMARY KEY); INSERT INTO {name}.digits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)')
            for offset in range(0,rows,100_000):
                size=min(100_000,rows-offset)
                if target['type']=='postgresql':
                    ids=f'SELECT {base}+n AS id FROM generate_series({offset+1},{offset+size}) n'
                    raw="decode('00','hex')"
                else:
                    number='+'.join(f'd{i}.d*{10**i}' for i in range(5))
                    digits=' CROSS JOIN '.join(f'{name}.digits d{i}' for i in range(5))
                    ids=f'SELECT {base}+{offset}+1+{number} AS id FROM {digits} WHERE {number}<{size}'
                    raw="X'00'"
                sql(target,f"INSERT INTO {table} SELECT id,'old',0,{raw},FALSE FROM ({ids}) generated_ids")
    emit(dict(event='benchmark_started', label=label, rows=rows, batch=args.batch, strategy=strategy, cancel_after=cancel_after))
    log_path = output/(label+'.jsonl')
    started = time.monotonic(); peak_rss = 0; samples = []; last_printed = started
    with log_path.open('w') as log:
        process = subprocess.Popen([str(output/'benchmark')], env=env, stdout=log, stderr=log)
        try:
            while process.poll() is None:
                usage = subprocess.run(['ps','-o','rss=','-p',str(process.pid)], capture_output=True, text=True)
                if usage.stdout.strip():
                    rss = int(usage.stdout.strip()); peak_rss = max(peak_rss,rss)
                    samples.append([round(time.monotonic()-started,3),rss])
                if time.monotonic()-last_printed >= 15:
                    last_printed=time.monotonic()
                    history = Path(env['BENCH_HISTORY'])
                    record = json.loads(history.read_text())[0] if history.exists() else {}
                    emit(dict(event='sample',label=label,seconds=round(time.monotonic()-started,1),
                              read_rows=sum(item['readRows'] for item in record.get('items',[])),peak_rss_mib=round(peak_rss/1024,2)))
                if time.monotonic()-started > args.timeout:
                    raise RuntimeError('Benchmark timeout: '+label)
                time.sleep(1)
        except BaseException:
            # Ask the actual manager to cancel and roll back before removing fixtures.
            Path(env['BENCH_CANCEL_FILE']).touch()
            try: process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.terminate(); process.wait(timeout=30)
            raise
    (output/(label+'-rss.json')).write_text(json.dumps(samples))
    events = []
    for line in log_path.read_text().splitlines():
        try: events.append(json.loads(line))
        except json.JSONDecodeError: pass
    if process.returncode:
        raise RuntimeError('Benchmark failed: '+label+' '+json.dumps(events[-3:],ensure_ascii=False))
    result = next(value for value in events if value.get('event')=='finished')
    result.update(label=label, peak_rss_mib=round(peak_rss/1024,2), source=source['type'], target=target['type'], batch=args.batch, strategy=strategy)
    if cancel_after and strategy=='upsert':
        raw_check="encode(raw,'hex')='00'" if target['type']=='postgresql' else "HEX(raw)='00'"
        bad=f"CASE WHEN payload='old' AND amount=0 AND {raw_check} AND NOT flag THEN 0 ELSE 1 END"
        actual=sql(target,f'SELECT COUNT(*),COALESCE(SUM(id-{base}),0),SUM({bad}) FROM {qualified(target,name)}')
        count,total,invalid=map(int,actual.split('|' if target['type']=='postgresql' else '\t'))
        if count!=rows or total!=rows*(rows+1)//2 or invalid:raise RuntimeError('Cancelled staged Upsert did not restore its original target')
        result['verification']=dict(rows=count,id_sum=total,invalid_rows=invalid,restored_original=True)
    else:
        result['verification'] = verify(target, name, 1 if cancel_after and strategy=='overwrite' else 0 if cancel_after else rows)
    results.append(result); (output/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
    emit(result)
    sql(target, ('DROP SCHEMA '+name+' CASCADE' if target['type']=='postgresql' else 'DROP DATABASE '+name))


emit(dict(event='output', path=str(output)))
if args.load_only:
    subprocess.run([str(output/'benchmark')], check=True, timeout=60,
                   env=dict(os.environ, DYLD_FRAMEWORK_PATH=str(frameworks), BENCH_LOAD_ONLY='1',
                            BENCH_DRIVER_ROOT=str(args.driver_root.resolve())))
    raise SystemExit(0)
try:
    mysql_source = launch('mysql57', 'public.ecr.aws/docker/library/mysql:5.7', 'mysql')
    mysql_target = launch('mysql80', 'public.ecr.aws/docker/library/mysql:8.0', 'mysql')
    pg = launch('pg17', 'postgres:17', 'postgresql')
    if args.doris_smoke:
        if not args.doris_port: raise RuntimeError('--doris-port is required for the owned Doris fixture')
        subprocess.run([str(output/'benchmark')],env=dict(os.environ,DYLD_FRAMEWORK_PATH=str(frameworks),BENCH_DRIVER_ROOT=str(args.driver_root.resolve()),
                       BENCH_DORIS_PORT=str(args.doris_port),BENCH_MYSQL_PORT=mysql_target['port'],BENCH_PG_PORT=pg['port'],BENCH_PASSWORD=secret),check=True,timeout=180)
        raise SystemExit(0)
    if args.regression_only:
        for index, (source, target) in enumerate([(mysql_source,mysql_target),(pg,pg),(mysql_source,pg),(pg,mysql_target)]):
            env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(frameworks), TRANSFER_TOKEN=uuid.uuid4().hex[:10],
                       TRANSFER_DRIVER_ROOT=str(args.driver_root.resolve()), TRANSFER_NATIVE_EDGES='1')
            for label, endpoint in [('SOURCE',source),('TARGET',target)]:
                env.update({f'TRANSFER_{label}_TYPE':endpoint['type'], f'TRANSFER_{label}_PORT':endpoint['port'],f'TRANSFER_{label}_PASSWORD':secret})
            subprocess.run([str(output/'benchmark')],env=env,check=True,timeout=300)
        raise SystemExit(0)
    info = json.loads(subprocess.check_output([docker,'info','--format','{{json .}}']))
    (output/'environment.json').write_text(json.dumps(dict(cpus=info['NCPU'],memory_bytes=info['MemTotal'],architecture=platform.machine(),
                                                        container_memory_gib=2,container_cpus=4,rows=args.rows,batch=args.batch,
                                                        configuration=args.configuration),indent=2))
    previous = 0
    for rows in sorted(set(args.rows)):
        for endpoint in [mysql_source, pg]: seed(endpoint, rows, previous)
        for case in args.cases:
            source_kind,target_kind=case.split('-')
            source = mysql_source if source_kind=='mysql' else pg
            target = mysql_target if target_kind=='mysql' else pg
            for strategy in args.strategies:
                benchmark(source,target,rows,f'{case}-{strategy}-{rows}',strategy=strategy)
        previous=rows
    if not args.skip_cancellation:
        for source,target in [(mysql_source,mysql_target),(pg,pg)]:
            benchmark(source,target,max(args.rows),source['type']+'-cancel-append',cancel_after=min(100_000,max(args.rows)))
            benchmark(source,target,max(args.rows),source['type']+'-cancel-overwrite',strategy='overwrite',cancel_after=min(100_000,max(args.rows)))
            benchmark(source,target,min(1_000_000,max(args.rows)),source['type']+'-cancel-upsert-merge',strategy='upsert',
                      cancel_after=min(100_000,max(args.rows)),cancel_phase='merge')
finally:
    for name in reversed(containers):
        subprocess.run([docker,'rm','-f','-v',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    emit(dict(event='cleanup_complete', containers=containers, results=str(output/'results.json')))
