#!/usr/bin/env python3
"""Run the entire mobile test target against fresh, owned LAN fixtures."""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid

p = argparse.ArgumentParser()
p.add_argument('--device-id', required=True)
p.add_argument('--host', required=True)
p.add_argument('--team-id', required=True)
p.add_argument('--output-dir', required=True)
p.add_argument('--derived-data-path', required=True)
p.add_argument('--scheme', default='QueryCraftMobileProof', choices=['QueryCraftMobileProof', 'QueryCraftMobilePhysicalUI'])
p.add_argument('--suite', action='append', help='Optional focused repair recheck')
a = p.parse_args()
assert ipaddress.ip_address(a.host).is_private
root = Path(__file__).resolve().parents[1]
out = root / a.output_dir
out.mkdir(parents=True, exist_ok=True)
docker = shutil.which('docker')
assert docker
owner = str(uuid.uuid4())
label = 'querycraft.full.physical.acceptance'
owned = []


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)


def container(image, port, options=(), command=()):
    name = 'qc-full-physical-' + uuid.uuid4().hex[:12]
    run([docker, 'run', '--detach', '--rm', '--name', name, '--label', label + '=' + owner,
         '--publish', a.host + '::' + str(port), *options, image, *command], stdout=subprocess.DEVNULL)
    owned.append(name)
    mapping = subprocess.check_output([docker, 'port', name, str(port) + '/tcp'], text=True).strip()
    return name, mapping.rsplit(':', 1)[1]


def wait(name, command):
    for _ in range(180):
        if subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            print('READY', name, flush=True)
            return
        time.sleep(1)
    raise RuntimeError(name + ' fixture did not become ready')


try:
    mysql, myport = container('mysql:8.4', 3306,
        ['--env', 'MYSQL_ROOT_PASSWORD=qc-workspace-mysql', '--env', 'MYSQL_ROOT_HOST=%'], ['--local-infile=ON'])
    my = [docker, 'exec', '--interactive', '--env', 'MYSQL_PWD=qc-workspace-mysql', mysql, 'mysql',
          '--protocol=tcp', '-h127.0.0.1', '-uroot', '--default-character-set=utf8mb4', '-N']
    wait('MySQL', my + ['-e', 'SELECT 1'])
    # Keep the existing simulator fixture as the single source of its SQL and
    # wide-table generator. Never execute that script's simulator launch steps.
    source = (root / 'scripts/test-ios-proof.sh').read_text()
    sql = source.split("<<'SQL'\n", 1)[1].split('\nSQL\n', 1)[0]
    generator = re.search(r"python3 - <<'PYSQL'[^\n]*\n(.*?)\nPYSQL", source, re.S).group(1)
    generated = subprocess.check_output([sys.executable, '-c', generator], text=True)
    run(my, input=sql + '\n' + generated, stdout=subprocess.DEVNULL)
    digits = '(SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)'
    run(my, input=f"""CREATE DATABASE qc_workspace_source CHARACTER SET utf8mb4;
CREATE TABLE qc_workspace_source.sample (id BIGINT PRIMARY KEY, value LONGTEXT, missing TEXT, `empty` TEXT, raw LONGBLOB) ENGINE=InnoDB;
INSERT INTO qc_workspace_source.sample SELECT 9007199254740993+a.n+10*b.n+100*c.n+1000*d.n,REPEAT('雪😀',1000),NULL,'',UNHEX('00FF8027') FROM {digits} a CROSS JOIN {digits} b CROSS JOIN {digits} c CROSS JOIN {digits} d WHERE a.n+10*b.n+100*c.n+1000*d.n<1001;
CREATE DATABASE physical_acceptance CHARACTER SET utf8mb4;
CREATE USER 'physical_acceptance'@'%' IDENTIFIED BY 'qc-physical-mysql';
GRANT ALL ON physical_acceptance.* TO 'physical_acceptance'@'%';
""", stdout=subprocess.DEVNULL)
    if a.scheme == 'QueryCraftMobilePhysicalUI':
        env = {'PROOF_SERVER_HOST': a.host, 'PROOF_MYSQL_PORT': myport}
    else:
        pg, pgport = container('postgres:17', 5432,
            ['--env', 'POSTGRES_PASSWORD=querycraft-proof-pg', '--env', 'POSTGRES_DB=querycraft_ios_pg'])
        pq = [docker, 'exec', '--interactive', '--env', 'PGPASSWORD=querycraft-proof-pg', pg, 'psql',
              '-h127.0.0.1', '-U', 'postgres', '-d', 'querycraft_ios_pg', '-v', 'ON_ERROR_STOP=1']
        wait('PostgreSQL', pq + ['-c', 'SELECT 1'])
        run(pq, input=(root / 'scripts/fixtures/mobile-postgresql.sql').read_text(), stdout=subprocess.DEVNULL)
        run(pq, input="""CREATE SCHEMA workspace_source;
    CREATE TABLE workspace_source.sample (id BIGINT PRIMARY KEY,value TEXT,missing TEXT,"empty" TEXT,raw BYTEA);
    INSERT INTO workspace_source.sample SELECT 9007199254740993+n,repeat('雪😀',1000),NULL,'',decode('00ff8027','hex') FROM generate_series(0,1000)n;
    CREATE USER physical_acceptance PASSWORD 'qc-physical-pg';
    CREATE DATABASE physical_acceptance OWNER physical_acceptance;
    """, stdout=subprocess.DEVNULL)
        redis, redisport = container('redis:7.4.2', 6379)
        rq = [docker, 'exec', redis, 'redis-cli', '--raw']
        wait('Redis', rq + ['PING'])
        for cmd in [['SET','querycraft-proof:string','你好 Redis'],['RPUSH','querycraft-proof:list','first','second'],
                    ['HSET','querycraft-proof:hash','field','value'],['SADD','querycraft-proof:set','member'],
                    ['ZADD','querycraft-proof:zset','1.5','member']]:
            run(rq + cmd, stdout=subprocess.DEVNULL)
        es, esport = container('docker.elastic.co/elasticsearch/elasticsearch:8.18.0', 9200,
            ['--env','discovery.type=single-node','--env','xpack.security.enabled=false','--env','ES_JAVA_OPTS=-Xms512m -Xmx512m'])
        url = 'http://' + a.host + ':' + esport
        wait('Elasticsearch', ['curl','--fail','--silent','--noproxy','*',url])
        def request(method, path, data):
            run(['curl','--fail','--silent','--show-error','--noproxy','*','-X',method,url+path,
                 '-H','Content-Type: application/json','--data-binary',data], stdout=subprocess.DEVNULL)
        request('PUT','/querycraft-ios-proof','{"mappings":{"properties":{"name":{"type":"text"},"count":{"type":"integer"}}}}')
        request('PUT','/querycraft-ios-proof/_doc/1?refresh=true','{"name":"你好 Elasticsearch","count":1}')
        request('PUT','/querycraft-ios-proof/_alias/querycraft-ios-alias','{}')
        doris, dorisport = container('apache/doris:all-in-one-4.1.3', 9030,
            ['--env','FE_HEAP=768m','--env','BE_HEAP=512m'])
        dq = [docker,'exec',doris,'mysql','-h127.0.0.1','-P9030','-uroot','--default-character-set=utf8mb4','-N','-e']
        wait('Doris', dq + ['SELECT 1'])
        run(dq + ['CREATE DATABASE querycraft_ios_drivers'], stdout=subprocess.DEVNULL)
        wait('Doris backend', dq + ["CREATE TABLE IF NOT EXISTS querycraft_ios_drivers.sample(id INT,name VARCHAR(80) COMMENT '真实字段注释') DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES('replication_num'='1')"])
        run(dq + ["INSERT INTO querycraft_ios_drivers.sample VALUES(1,'你好 Doris'),(2,'second');CREATE VIEW querycraft_ios_drivers.sample_view AS SELECT * FROM querycraft_ios_drivers.sample"], stdout=subprocess.DEVNULL)
        env = {'PROOF_SERVER_HOST':a.host,'PROOF_MYSQL_PORT':myport,'PROOF_TRANSFER_MYSQL_PORT':myport,
            'PROOF_POSTGRES_PORT':pgport,'PROOF_REDIS_PORT':redisport,'PROOF_REDIS_FIELD_TTL':'1',
            'PROOF_ELASTICSEARCH_PORT':esport,'PROOF_DORIS_PORT':dorisport,
            'QUERYCRAFT_ES_LIVE_TESTS':'1','QUERYCRAFT_ES_LIVE_HOST':a.host,'QUERYCRAFT_ES_LIVE_PORTS':esport,
            'QUERYCRAFT_PHYSICAL_SQL_ACCEPTANCE':'1','QUERYCRAFT_PHYSICAL_SQL_OWNER':owner,
            'QUERYCRAFT_PHYSICAL_MYSQL_HOST':a.host,'QUERYCRAFT_PHYSICAL_MYSQL_PORT':myport,'QUERYCRAFT_PHYSICAL_MYSQL_PASSWORD':'qc-physical-mysql',
            'QUERYCRAFT_PHYSICAL_PG_HOST':a.host,'QUERYCRAFT_PHYSICAL_PG_PORT':pgport,'QUERYCRAFT_PHYSICAL_PG_PASSWORD':'qc-physical-pg',
            'QUERYCRAFT_PHYSICAL_REDIS_ACCEPTANCE':'1','QUERYCRAFT_PHYSICAL_REDIS_OWNER':owner,
            'QUERYCRAFT_PHYSICAL_REDIS_HOST':a.host,'QUERYCRAFT_PHYSICAL_REDIS_PORT':redisport}
        frontends = subprocess.check_output([part for part in dq[:-1] if part != '-N'] + ['--batch', '-e', 'SHOW FRONTENDS'], text=True).splitlines()
        columns = frontends[0].split('\t')
        versions = {
            'mysql': subprocess.check_output(my + ['-e', 'SELECT VERSION()'], text=True).strip(),
            'postgresql': subprocess.check_output(pq + ['-Atc', 'SHOW server_version'], text=True).strip(),
            'redis': next(line for line in subprocess.check_output(rq + ['INFO', 'server'], text=True).splitlines() if line.startswith('redis_version:')),
            'elasticsearch': json.loads(subprocess.check_output(['curl', '--fail', '--silent', '--noproxy', '*', url], text=True))['version']['number'],
            'dorisFrontend': [dict(zip(columns, row.split('\t'))).get('Version') for row in frontends[1:]],
        }
        (out/'server-versions.json').write_text(json.dumps(versions, indent=2)+'\n')
    (out/'scope.json').write_text(json.dumps({'owner':owner,'device':a.device_id,'allTests':not a.suite,
        'scheme':a.scheme,'suites':a.suite,'fixtures':owned},indent=2)+'\n')
    command = ['xcodebuildmcp','device','test','--project-path',str(root/'QueryCraftMobile/QueryCraftMobile.xcodeproj'),
        '--scheme',a.scheme,'--device-id',a.device_id,'--derived-data-path',a.derived_data_path,
        '--output','json','--json',json.dumps({'testRunnerEnv':env}),'--extra-args','CODE_SIGNING_ALLOWED=YES',
        'CODE_SIGN_STYLE=Automatic','DEVELOPMENT_TEAM='+a.team_id,'CODE_SIGN_IDENTITY=Apple Development',
        '-allowProvisioningUpdates','-parallel-testing-enabled','NO']
    target = 'QueryCraftMobileSystemUITests' if a.scheme == 'QueryCraftMobilePhysicalUI' else 'QueryCraftMobileProofTests'
    if a.suite:command += ['-only-testing:'+target+'/'+s for s in a.suite]
    with (out/'tests.json').open('w') as stream:result=subprocess.run(command,cwd=root,stdout=stream)
    report=json.loads((out/'tests.json').read_text());summary=report.get('data',{}).get('summary',{})
    print(json.dumps(summary),flush=True)
    if result.returncode or report.get('didError') or summary.get('status')!='SUCCEEDED':
        raise RuntimeError('Physical full suite failed; inspect '+str(out/'tests.json'))
    assert summary.get('counts',{}).get('passed',0)>0
    if not a.suite:
        assert summary.get('counts',{}).get('skipped',0)==0, 'Complete physical run unexpectedly skipped tests'
finally:
    removed=[]
    for name in reversed(owned):
        r=subprocess.run([docker,'inspect','--format','{{ index .Config.Labels "'+label+'" }}',name],capture_output=True,text=True)
        if r.returncode==0 and r.stdout.strip()==owner:
            run([docker,'rm','--force','--volumes',name],stdout=subprocess.DEVNULL);removed.append(name)
    (out/'cleanup.json').write_text(json.dumps({'owner':owner,'created':owned,'removed':removed},indent=2)+'\n')
    if set(removed)!=set(owned):raise RuntimeError('Owned full-suite fixture cleanup incomplete')
