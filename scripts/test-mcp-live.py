#!/usr/bin/env python3
"""Run the packaged MCP against disposable Docker databases on loopback only.

Pulls missing pinned images; creates/removes only containers and anonymous volumes
owned by this invocation. Never uses desktop connection storage or Keychain.
"""
import argparse,importlib.util,json,os,plistlib,shutil,socket,subprocess,tempfile,time,uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('protocol',ROOT/'scripts/test-mcp-protocol.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
DOCKER='/Applications/Docker.app/Contents/Resources/bin/docker'
containers={}
def docker(*args):return subprocess.check_output([DOCKER,*args],text=True,stderr=subprocess.PIPE).strip()
def port(kind,p):return int(docker('port',containers[kind],str(p)).split(':')[-1])
def freeport():
 with socket.socket() as sock:sock.bind(('127.0.0.1',0));return sock.getsockname()[1]
def start(kind):
 name='qc-mcp-check-'+uuid.uuid4().hex[:12]+'-'+kind
 images={'mysql':args.mysql_image,'pg':'postgres:17','redis':args.redis_image,'es':'docker.elastic.co/elasticsearch/elasticsearch:8.18.0','kafka':'apache/kafka:3.9.1','doris':'apache/doris:all-in-one-4.1.3'}
 internal={'mysql':3306,'pg':5432,'redis':6379,'es':9200,'kafka':9092,'doris':9030}[kind]
 host=freeport()
 env={'mysql':['MYSQL_ALLOW_EMPTY_PASSWORD=yes'],'pg':['POSTGRES_HOST_AUTH_METHOD=trust'],'redis':[],
      'es':['discovery.type=single-node','xpack.security.enabled=false','ES_JAVA_OPTS=-Xms512m -Xmx512m'],
      'doris':[],
      'kafka':['KAFKA_NODE_ID=1','KAFKA_PROCESS_ROLES=broker,controller','KAFKA_LISTENERS=PLAINTEXT://:9092,INTERNAL://:19092,CONTROLLER://:9093',f'KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://127.0.0.1:{host},INTERNAL://localhost:19092','KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,INTERNAL:PLAINTEXT','KAFKA_INTER_BROKER_LISTENER_NAME=INTERNAL','KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER','KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9093','KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1','KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1','KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1']}[kind]
 command=['run','-d','--name',name,'-p',f'127.0.0.1:{host}:{internal}']
 if kind=='doris':command+=['--memory=4g']
 for entry in env:command+=['-e',entry]
 command.append(images[kind]);containers[kind]=name;docker(*command)
 health={'mysql':['mysqladmin','--protocol=tcp','-h127.0.0.1','ping','-uroot'],'pg':['pg_isready','-h127.0.0.1','-U','postgres'],'redis':['redis-cli','ping'],
 'es':['curl','-fsS','http://localhost:9200/_cluster/health?wait_for_status=yellow&timeout=1s'],
 'kafka':['/opt/kafka/bin/kafka-topics.sh','--bootstrap-server','localhost:19092','--list'],
 'doris':['mysql','-h127.0.0.1','-P9030','-uroot','-B','-e','SHOW BACKENDS']}[kind]
 deadline=time.monotonic()+300
 while time.monotonic()<deadline:
  try:
   ready=docker('exec',name,*health)
   if kind!='doris':break
   lines=ready.splitlines()
   if len(lines)>1:
    backend=dict(zip(lines[0].split('\t'),lines[1].split('\t')))
    if backend.get('Alive')=='true' and float(backend.get('AvailCapacity','0').split()[0])>0:break
  except subprocess.CalledProcessError:pass
  time.sleep(1)
 else:
  if kind=='doris':
   try:print(docker('exec',name,*health),flush=True)
   except subprocess.CalledProcessError:pass
  raise RuntimeError(kind+' did not become ready')
 if kind=='kafka':docker('exec',name,'/opt/kafka/bin/kafka-topics.sh','--bootstrap-server','localhost:19092','--create','--topic','qc-mcp-fixture','--partitions','1','--replication-factor','1')
 print('READY '+kind,flush=True)

def permission_cases(typ,cid,base,call,settings,save):
 def rule(mode,scope='selected',overrides=None,names=None):
  target=base.get('database') or ('qc-mcp-fixture' if typ in ['elasticsearch','kafka'] else '0')
  settings['connections'][cid]={'mode':'read_only','databaseAccess':scope,'databases':names or [target],'databaseModes':overrides if overrides is not None else {target:mode}}
  save()
 def c(tool,**extra):return call(tool,{**base,**extra})
 def q(sql,**extra):return c('execute_query',sql=sql,**extra)
 def deny(tool,code='ACCESS_DENIED',**extra):
  result=call(tool,{**base,**extra},error=True)
  assert result['structuredContent']['error']['code']==code,(tool,extra,result)
 def rows(result):return result['results'][0]['result']['rows']
 if typ in ['mysql','postgresql','doris']:
  db=base['database'];rule('high_risk_write')
  original=next(p for p in call('list_connections') if p['id']==cid)
  discovery=call('add_connection',{'name':'Scoped discovery fixture','type':typ,'host':'127.0.0.1','port':original['port'],'username':'postgres' if typ=='postgresql' else 'root','database':'qc_missing_default','tls_mode':'disabled'})['connection_id']
  settings['connections'][discovery]={'mode':'read_only','databaseAccess':'selected','databases':[db],'databaseModes':{db:'high_risk_write'}};save()
  assert call('plugin_tools',{'connection_id':discovery})
  assert call('plugin_call',{'connection_id':discovery,'tool':'list_databases','arguments':{}})==[db]
  assert rows(call('plugin_call',{'connection_id':discovery,'tool':'execute_query','arguments':{'database':db,'sql':'SELECT 1'}}))==[['1']]
  create='CREATE TABLE qc_scoped (id INT PRIMARY KEY, note VARCHAR(100))'
  if typ=='doris':create='CREATE TABLE qc_scoped (id INT, note VARCHAR(100)) UNIQUE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ("replication_num"="1")'
  deny('execute_query',code='CONFIRMATION_REQUIRED',sql=create)
  q(create,confirm_high_risk=True)
  q("INSERT INTO qc_scoped(id,note) VALUES(1,'full')")
  probe='SELECT DATABASE(), VERSION()' if typ!='postgresql' else 'SELECT pg_catalog.current_database(), pg_catalog.version()'
  assert rows(q(probe))[0][0].split(':')[-1]==db
  if typ=='postgresql':comment="COMMENT ON COLUMN qc_scoped.note IS 'scoped permission'"
  elif typ=='doris':comment='ALTER TABLE qc_scoped MODIFY COLUMN note COMMENT "scoped permission"'
  else:comment="ALTER TABLE qc_scoped MODIFY COLUMN note VARCHAR(100) COMMENT 'scoped permission'"
  q(comment,confirm_high_risk=True)
  table=next(t['name'] for t in c('list_tables',refresh=True) if t['name'].split('.')[-1]=='qc_scoped')
  details=c('describe_table',table=table,refresh=True)
  assert any(col['name']=='note' and col['comment']=='scoped permission' for col in details[0]['columns']),details
  q('ALTER TABLE qc_scoped ADD COLUMN extra INT',confirm_high_risk=True)
  deadline=time.monotonic()+30
  while not any(col['name']=='extra' for col in c('describe_table',table=table,refresh=True)[0]['columns']):
   assert time.monotonic()<deadline,'Schema change did not become visible'
   time.sleep(.2)
  rule('safe_write');q("UPDATE qc_scoped SET note='safe' WHERE id=1")
  q("INSERT INTO qc_scoped(id,note) VALUES(2,'remove')");q('DELETE FROM qc_scoped WHERE id=2')
  deny('execute_query',sql='DELETE FROM qc_scoped')
  deny('execute_query',sql='ALTER TABLE qc_scoped ADD COLUMN denied INT',confirm_high_risk=True)
  rule('read_only');assert rows(q('SELECT note FROM qc_scoped WHERE id=1'))==[['safe']]
  rows(q(probe));deny('execute_query',sql="UPDATE qc_scoped SET note='denied' WHERE id=1")
  rule('high_risk_write');deny('execute_query',code='CONFIRMATION_REQUIRED',sql='DELETE FROM qc_scoped')
  if typ in ['mysql','doris']:
   settings['connections'][cid]={'mode':'high_risk_write','databaseAccess':'all','databaseModes':{}};save()
   q('CREATE DATABASE qc_mcp_ro',confirm_high_risk=True)
   ro={'connection_id':cid,'database':'qc_mcp_ro'}
   rocreate='CREATE TABLE qc_ro (id INT PRIMARY KEY)'
   if typ=='doris':rocreate='CREATE TABLE qc_ro (id INT) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ("replication_num"="1")'
   call('execute_query',{**ro,'sql':rocreate,'confirm_high_risk':True});call('execute_query',{**ro,'sql':'INSERT INTO qc_ro VALUES(7)'})
   for scope in ['selected','all']:
    rule('high_risk_write',scope=scope,overrides={db:'high_risk_write','qc_mcp_ro':'read_only'},names=[db,'qc_mcp_ro'])
    for sql in ['DELETE FROM qc_mcp_ro.qc_ro WHERE id=7','INSERT INTO qc_mcp_ro.qc_ro VALUES(8)','ALTER TABLE qc_mcp_ro.qc_ro ADD COLUMN denied INT']:
     deny('execute_query',sql=sql,confirm_high_risk=True)
    assert rows(q('SELECT id FROM qc_mcp_ro.qc_ro'))==[['7']]
    result=call('execute_query',{**ro,'sql':f"INSERT INTO {db}.qc_scoped(id,note) VALUES({8 if scope=='selected' else 9},'explicit target')"})
    assert result['results'][0]['affected_or_returned_rows']==1,result
  if typ=='postgresql':
   q('CREATE SCHEMA qc_permission_schema',confirm_high_risk=True)
   q('CREATE TABLE qc_permission_schema.t(id INT)',confirm_high_risk=True)
   q('DROP SCHEMA qc_permission_schema CASCADE',confirm_high_risk=True)
  rule('high_risk_write');q('DROP TABLE qc_scoped',confirm_high_risk=True)
 elif typ=='redis':
  rule('safe_write');c('execute_redis_command',arguments=['SET','qc:scope','value'])
  rule('read_only');assert c('execute_redis_command',arguments=['GET','qc:scope'])['reply']=='value'
  deny('execute_redis_command',arguments=['SET','qc:scope','denied'])
  rule('high_risk_write');deny('execute_redis_command',code='CONFIRMATION_REQUIRED',arguments=['FLUSHDB'])
  c('execute_redis_command',arguments=['FLUSHDB'],confirm_high_risk=True)
  assert c('execute_redis_command',arguments=['GET','qc:scope'])['reply'] is None
  settings['connections'][cid]={'mode':'high_risk_write','databaseAccess':'all','databaseModes':{'1':'read_only'}};save()
  deny('execute_redis_command',arguments=['FLUSHALL'],confirm_high_risk=True)
  settings['connections'][cid]['databaseModes']['1']='high_risk_write';save()
  deny('execute_redis_command',code='CONFIRMATION_REQUIRED',arguments=['FLUSHALL'])
  c('execute_redis_command',arguments=['FLUSHALL'],confirm_high_risk=True)
  original=next(p for p in call('list_connections') if p['id']==cid)
  alias=call('add_connection',{'name':'Redis saved DB label','type':'redis','host':'127.0.0.1','port':original['port'],'database':'DB 8','tls_mode':'disabled'})['connection_id']
  settings['connections'][alias]={'mode':'read_only','databaseAccess':'selected','databases':['8'],'databaseModes':{'DB 8':'safe_write'}};save()
  call('execute_redis_command',{'connection_id':alias,'arguments':['SET','qc:display-db','alias works']})
  assert call('execute_redis_command',{'connection_id':alias,'database':'8','arguments':['GET','qc:display-db']})['reply']=='alias works'
  assert call('list_databases',{'connection_id':alias})==['DB 8']
 elif typ=='elasticsearch':
  settings['connections'][cid]={'mode':'read_only','databaseAccess':'all','databaseModes':{}};save()
  assert 'responses' in json.loads(c('execute_request',method='POST',path='/_msearch',body='{}\n{"size":0,"query":{"match_all":{}}}\n')['body'])
  rule('high_risk_write',names=['qc-mcp-fixture','qc-scope-new'],overrides={'qc-mcp-fixture':'high_risk_write','qc-scope-new':'high_risk_write'})
  deny('execute_request',code='CONFIRMATION_REQUIRED',method='PUT',path='/qc-scope-new',body='{}')
  c('execute_request',method='PUT',path='/qc-scope-new',body='{}',confirm_high_risk=True)
  c('execute_request',method='PUT',path='/qc-scope-new/_doc/1',body='{"index":"ordinary","script":"data","pipeline":"data"}')
  c('execute_request',method='PUT',path='/qc-scope-new/_mapping',body='{"properties":{"extra":{"type":"keyword"}}}',confirm_high_risk=True)
  settings['connections'][cid]['databaseModes']['qc-scope-new']='read_only';settings['connections'][cid]['mode']='high_risk_write';save()
  deny('execute_request',method='DELETE',path='/qc-scope-new',confirm_high_risk=True)
  deny('execute_request',method='POST',path='/qc-mcp-fixture/_bulk',body='{"index":{"_index":"qc-scope-new"}}\n{"v":1}\n',confirm_high_risk=True)
  settings['connections'][cid]['databaseModes']['qc-scope-new']='high_risk_write';save()
  c('execute_request',method='DELETE',path='/qc-scope-new',confirm_high_risk=True)
 elif typ=='kafka':
  rule('safe_write');c('send_message',topic='qc-mcp-fixture',value='')
  rule('read_only');deny('send_message',topic='qc-mcp-fixture',value='denied')
  settings['connections'][cid]['mode']='high_risk_write';save();deny('send_message',topic='qc-mcp-fixture',value='still denied')
 print('PASS '+typ+' scoped object-mode/confirmation/override permission cases',flush=True)

parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('executable',type=Path);parser.add_argument('--drivers-dir',type=Path,required=True);parser.add_argument('--drivers',default='mysql,pg,redis,es,kafka,doris');parser.add_argument('--stress',action='store_true',help='Keep MySQL/Doris alive for concurrent same-process HTTP checks and transaction cleanup')
parser.add_argument('--permission-matrix',action='store_true');parser.add_argument('--mysql-image',default='mysql:5.6');parser.add_argument('--redis-image',default='redis:7.4.2')
args=parser.parse_args();assert not args.stress or {'mysql','doris'} <= set(args.drivers.split(',')), '--stress requires mysql,doris';EXE=args.executable.resolve();drivers=args.drivers_dir.resolve();selected=args.drivers.split(',')
try:
 with tempfile.TemporaryDirectory(prefix='qc-mcp-live-') as temp:
  root=Path(temp)
  api=plistlib.loads((next(drivers.glob('*.querycraftdriver'))/'Contents/Info.plist').read_bytes())['QCDriverAPIVersion']
  shutil.copytree(drivers,root/f'DriverAPI-{api}'/'Drivers',symlinks=True,ignore=shutil.ignore_patterns('*.zip','*.json'))
  settings=mod.policy(5227);settings.update(allConnections=True,disabledTools=[],queryTimeoutSeconds=15)
  def save():(root/'mcp-policy.json').write_text(json.dumps(settings))
  save()
  checked=subprocess.run([str(EXE),'--check-drivers','--data-dir',temp],capture_output=True,text=True,check=True,timeout=30)
  required={'pg':'postgresql','es':'elasticsearch'}
  assert {required.get(kind,kind) for kind in selected} <= set(json.loads(checked.stdout)), 'Requested live drivers did not load: '+checked.stdout
  assert 'is implemented in both' not in checked.stderr,checked.stderr
  p=subprocess.Popen([str(EXE),'--stdio','--data-dir',temp],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  seq=1
  stress_connections={}
  def call(name,args={},error=False):
   global seq
   seq+=1
   r=mod.send(p,{'jsonrpc':'2.0','id':seq,'method':'tools/call','params':{'name':'querycraft_'+name,'arguments':args}})['result']
   if error:
    assert r.get('isError'),(name,r)
    return r
   assert not r.get('isError'),(name,r)
   return json.loads(r['content'][0]['text'])
  def mode(value):
   for rule in settings['connections'].values():rule['mode']=value
   save()
  try:
   mod.send(p,mod.INIT);mod.send(p,{'jsonrpc':'2.0','method':'notifications/initialized'},False)
   for kind,typ,internal,user,db in [('mysql','mysql',3306,'root','qc_mcp'),('pg','postgresql',5432,'postgres','postgres'),('redis','redis',6379,'','0'),('es','elasticsearch',9200,'',None),('kafka','kafka',9092,'',None),('doris','doris',9030,'root','qc_mcp')]:
    if kind not in selected:continue
    start(kind)
    mode('high_risk_write')
    cid=call('add_connection',{'name':'Integration '+typ,'type':typ,'host':'127.0.0.1','port':port(kind,internal),'username':user,'tls_mode':'disabled',**({'database':db} if db else {})})['connection_id']
    settings['connections'][cid]={'mode':'high_risk_write','databaseModes':{}};save()
    base={'connection_id':cid}
    if db:base['database']=db
    def c(name,**args):return call(name,{**base,**args})
    def q(sql,**args):return c('execute_query',sql=sql,**args)
    def rows(result):return result['results'][0]['result']['rows']
    if typ in ['mysql','postgresql']:
     if typ=='mysql':
      call('execute_query',{'connection_id':cid,'database':'mysql','sql':'CREATE DATABASE qc_mcp','confirm_high_risk':True})
     q('CREATE TABLE qc_items (id INTEGER PRIMARY KEY, note VARCHAR(500), amount DECIMAL(20,2))',confirm_high_risk=True)
     q("INSERT INTO qc_items VALUES (1, 'fixture', 123456789012345678.12), (2, NULL, 1.20)")
     assert any('qc_items' in t['name'] for t in c('list_tables'))
     table=next(t['name'] for t in c('list_tables') if 'qc_items' in t['name'])
     assert len(c('describe_table',table=table)[0]['columns'])==3
     assert 'qc_items' in json.dumps(c('get_schema_context'))
     mode('read_only');assert rows(q('SELECT id, note, amount FROM qc_items ORDER BY id'))[1][1] is None
     assert rows(q('SELECT amount FROM qc_items WHERE id = 1'))[0][0]=='123456789012345678.12'
     call('execute_query',{**base,'sql':"INSERT INTO qc_items VALUES (3, 'denied', 0)"},error=True)
     bounded=q('SELECT id FROM qc_items ORDER BY id',max_rows=1)['results'][0]['result'];assert bounded['truncated'] and bounded['returned_rows']==1
     session=c('open_session')['session_id'];call('begin_transaction',{'session_id':session});q('SELECT id FROM qc_items',session_id=session);call('rollback_transaction',{'session_id':session});call('close_session',{'session_id':session})
     mode('safe_write');session=c('open_session')['session_id'];call('begin_transaction',{'session_id':session});q("INSERT INTO qc_items VALUES (3, 'rollback', 0)",session_id=session);call('rollback_transaction',{'session_id':session});call('close_session',{'session_id':session});assert rows(q('SELECT id FROM qc_items WHERE id = 3'))==[]
     call('execute_batch',{**base,'sql':"INSERT INTO qc_items VALUES (4, 'atomic', 0); INSERT INTO qc_items VALUES (1, 'duplicate', 0)",'use_transaction':True},error=True);assert rows(q('SELECT id FROM qc_items WHERE id = 4'))==[]
     session=c('open_session')['session_id'];call('begin_transaction',{'session_id':session});q("INSERT INTO qc_items VALUES (5, 'commit', 0)",session_id=session);call('commit_transaction',{'session_id':session});call('close_session',{'session_id':session});assert rows(q('SELECT id FROM qc_items WHERE id = 5'))==[['5']]
     mode('high_risk_write');q('CREATE TABLE qc_added (id INTEGER)',confirm_high_risk=True);assert any('qc_added' in t['name'] for t in c('list_tables'))
     q('DROP TABLE qc_added',confirm_high_risk=True)
     settings['queryTimeoutSeconds']=1;save()
     timed=call('execute_query',{**base,'sql':'SELECT pg_sleep(3)' if typ=='postgresql' else 'SELECT SLEEP(3)'},error=True)
     assert timed['structuredContent']['error']['code']=='OPERATION_TIMEOUT',timed
     settings['queryTimeoutSeconds']=15;save();assert rows(q('SELECT id FROM qc_items WHERE id = 5'))==[['5']]
     print('PASS '+typ+' live metadata, readonly, NULL/decimal, limits, transactions/commit, atomic rollback, timeout recovery and DDL invalidation',flush=True)
    elif typ=='doris':
     call('execute_query',{'connection_id':cid,'database':'information_schema','sql':'CREATE DATABASE qc_mcp','confirm_high_risk':True})
     q('CREATE TABLE qc_items (id INT, note VARCHAR(100)) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ("replication_num"="1")',confirm_high_risk=True)
     q("INSERT INTO qc_items VALUES (1, 'hello')")
     mode('read_only');assert 'hello' in json.dumps(q('SELECT * FROM qc_items'))
     assert any(t['name']=='qc_items' for t in c('list_tables'))
     c('describe_table',table='qc_items');c('get_schema_context')
     call('execute_query',{**base,'sql':"INSERT INTO qc_items VALUES (2, 'denied')"},error=True)
     session=c('open_session')['session_id'];call('begin_transaction',{'session_id':session},error=True);call('close_session',{'session_id':session},error=True)
     print('PASS doris live DDL, insert, read, metadata, readonly denial and unsupported transaction rejection',flush=True)
    elif typ=='redis':
     c('execute_redis_command',arguments=['SET','qc:mcp:fixture','hello'])
     mode('read_only');r=c('execute_redis_command',arguments=['GET','qc:mcp:fixture']);assert 'hello' in json.dumps(r)
     call('execute_redis_command',{**base,'arguments':['SET','qc:mcp:denied','no']},error=True)
     c('execute_redis_command',arguments=['SCAN','0','COUNT','10']);c('list_tables')
     print('PASS redis live SET/GET/SCAN and readonly denial',flush=True)
    elif typ=='elasticsearch':
     c('execute_request',method='PUT',path='/qc-mcp-fixture',body='{"mappings":{"properties":{"note":{"type":"keyword"}}}}',confirm_high_risk=True)
     c('execute_request',method='PUT',path='/qc-mcp-fixture/_doc/1',body='{"note":"hello"}',confirm_high_risk=True)
     c('execute_request',method='POST',path='/qc-mcp-fixture/_refresh',confirm_high_risk=True)
     mode('read_only');assert 'hello' in json.dumps(c('execute_request',method='POST',path='/qc-mcp-fixture/_search',body='{"query":{"match_all":{}}}'))
     call('execute_request',{**base,'method':'DELETE','path':'/qc-mcp-fixture','confirm_high_risk':True},error=True)
     assert any(t['name']=='qc-mcp-fixture' for t in c('list_tables'))
     c('describe_table',table='qc-mcp-fixture')
     print('PASS elasticsearch live index, document, search, mapping and readonly denial',flush=True)
    elif typ=='kafka':
     c('send_message',topic='qc-mcp-fixture',value='hello')
     mode('read_only');r=c('peek_messages',topic='qc-mcp-fixture',max_rows=10);assert 'hello' in json.dumps(r),r
     call('send_message',{**base,'topic':'qc-mcp-fixture','value':'denied'},error=True)
     docker('exec',containers[kind],'/opt/kafka/bin/kafka-consumer-groups.sh','--bootstrap-server','localhost:19092','--group','qc-mcp-fixture-group','--topic','qc-mcp-fixture','--reset-offsets','--to-earliest','--execute')
     groups=c('consumer_groups',topic='qc-mcp-fixture');assert any(g['id']=='qc-mcp-fixture-group' and g['partitions'] for g in groups),groups
     assert any(t['name']=='qc-mcp-fixture' for t in c('list_tables'))
     print('PASS kafka live produce, peek, groups and readonly denial',flush=True)
    if args.permission_matrix:permission_cases(typ,cid,base,call,settings,save)
    settings['connections'][cid]={'databaseAccess':'none','databaseModes':{}};save();call('list_tables',base,error=True)
    if args.stress and kind in ['mysql','doris']:
     settings['connections'][cid]={'mode':'safe_write','databaseModes':{}};save();stress_connections[kind]=base
    else:
     docker('rm','-f','-v',containers[kind]);del containers[kind]
   if args.stress:
    spec=importlib.util.spec_from_file_location('lifecycle',ROOT/'scripts/test-mcp-lifecycle.py');life=importlib.util.module_from_spec(spec);spec.loader.exec_module(life)
    settings['http']['port']=freeport();mode('safe_write')
    http=life.launch_http(EXE,root,settings)
    try:
     def worker(index):
      client=life.HTTPClient(settings).connect()
      try:
       for iteration in range(5):
        for kind in ['mysql','doris']:
         base=stress_connections[kind]
         session=client.call('open_session',base)['session_id']
         result=client.call('execute_query',{**base,'session_id':session,'sql':f'SELECT {index * 10 + iteration} AS marker'})
         assert rows(result)==[[str(index * 10 + iteration)]],result
         client.call('close_session',{'session_id':session})
         assert any(t['name']=='qc_items' for t in client.call('list_tables',base))
      finally:client.close()
     with ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(worker,range(4)))
     print('PASS simultaneous MySQL/Doris: four HTTP clients, 40 independent sessions/queries and repeated metadata pooling',flush=True)
     base=stress_connections['mysql'];owner=life.HTTPClient(settings).connect();observer=life.HTTPClient(settings).connect()
     try:
      session=owner.call('open_session',base)['session_id'];owner.call('begin_transaction',{'session_id':session})
      owner.call('execute_query',{**base,'session_id':session,'sql':"INSERT INTO qc_items VALUES (101, 'disconnect rollback', 0)"})
      observer.call('execute_query',{**base,'session_id':session,'sql':'SELECT 1'},error=True)
      owner.close()
      assert rows(observer.call('execute_query',{**base,'sql':'SELECT id FROM qc_items WHERE id = 101'}))==[]
      print('PASS HTTP session ownership and DELETE rolls back pending MySQL transaction',flush=True)
     finally:observer.close()
    finally:
     life.stop(http)
     assert b'is implemented in both' not in http.stderr.read(), 'Duplicate runtime class registration'
    base=stress_connections['mysql'];session=call('open_session',base)['session_id'];call('begin_transaction',{'session_id':session})
    call('execute_query',{**base,'session_id':session,'sql':"INSERT INTO qc_items VALUES (102, 'EOF rollback', 0)"})
    p.stdin.close();assert p.wait(timeout=15)==0
    assert b'is implemented in both' not in p.stderr.read(), 'Duplicate runtime class registration'
    p=subprocess.Popen([str(EXE),'--stdio','--data-dir',temp],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    mod.send(p,mod.INIT);mod.send(p,{'jsonrpc':'2.0','method':'notifications/initialized'},False)
    assert rows(call('execute_query',{**base,'sql':'SELECT id FROM qc_items WHERE id = 102'}))==[]
    call('execute_query',{**base,'session_id':session,'sql':'SELECT 1'},error=True)
    print('PASS stdio EOF releases pending transaction; restarted client reloads profiles and rejects stale session',flush=True)
  finally:
   p.terminate()
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:p.kill();p.wait()
finally:
 for name in containers.values():
  subprocess.run([DOCKER,'rm','-f','-v',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
