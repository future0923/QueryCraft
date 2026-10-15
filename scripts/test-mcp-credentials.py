#!/usr/bin/env python3
"""Exercise the signed MCP credential helper with fresh test-only Keychain items.

No existing credential is read or changed. All newly created test profiles/items
are removed before exit. The signed, versioned MCP helper may install itself.
"""
import argparse,importlib.util,json,sqlite3,subprocess,tempfile,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('protocol',ROOT/'scripts/test-mcp-protocol.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
a=argparse.ArgumentParser(description=__doc__);a.add_argument('executable',type=Path);args=a.parse_args()
with tempfile.TemporaryDirectory(prefix='qc-mcp-credentials-') as temp:
 root=Path(temp);policy=m.policy(5228);policy.update(mode='high_risk_write',allConnections=True,disabledTools=[])
 (root/'mcp-policy.json').write_text(json.dumps(policy))
 p=subprocess.Popen([str(args.executable.resolve()),'--stdio','--data-dir',temp],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 ids=[];seq=2;secret=uuid.uuid4().hex+uuid.uuid4().hex
 def call(name,arguments):
  global seq
  seq+=1;r=m.send(p,{'jsonrpc':'2.0','id':seq,'method':'tools/call','params':{'name':'querycraft_'+name,'arguments':arguments}})['result']
  assert not r.get('isError'),r
  return json.loads(r['content'][0]['text'])
 try:
  m.send(p,m.INIT);m.send(p,{'jsonrpc':'2.0','method':'notifications/initialized'},False)
  original=call('add_connection',{'type':'mysql','name':'Temporary credential integration test','host':'127.0.0.1','port':3306,'username':'fixture','password':secret})['connection_id'];ids.append(original)
  copy=call('duplicate_connection',{'connection_id':original,'name':'Temporary copied credential'})['connection_id'];ids.append(copy)
  result=subprocess.run([str(args.executable.resolve()),'--authorize-credentials','--data-dir',temp],text=True,capture_output=True,timeout=30)
  assert result.returncode==0 and 'Credential authorization complete' in result.stdout,'Test-only saved credential authorization failed'
  missing=call('add_connection',{'type':'mysql','name':'Missing test-only credential','host':'127.0.0.1','port':3306,'username':'fixture'})['connection_id'];ids.append(missing)
  with sqlite3.connect(root/'QueryCraft.sqlite') as database:
   changed=database.execute('UPDATE connectionProfile SET storesCredential = 1 WHERE id = ?', [uuid.UUID(missing).bytes])
   assert changed.rowcount==1,'Missing credential fixture was not updated'
  result=subprocess.run([str(args.executable.resolve()),'--authorize-credentials','--data-dir',temp],text=True,capture_output=True,timeout=30)
  assert result.returncode!=0 and json.loads(result.stdout)['credential_error']=='CREDENTIAL_UNAVAILABLE','Missing credential was reported as authorized'
  call('remove_connection',{'connection_id':missing,'confirm_high_risk':True});ids.remove(missing)
  result=subprocess.run([str(args.executable.resolve()),'--authorize-credentials','--data-dir',temp],text=True,capture_output=True,timeout=30)
  assert result.returncode==0,'Authorization failed to recover after missing fixture was removed'
  print('PASS real credential authorizer success, missing-credential typed failure and recovery using test-only profiles',flush=True)
  assert secret not in json.dumps(call('list_connections',{}))
  assert secret.encode() not in (root/'QueryCraft.sqlite').read_bytes()
  assert secret.encode() not in (root/'MCP/History/calls.sqlite').read_bytes()
  print('PASS signed helper save/read/copy with new Keychain items; profiles, MCP output and history contain no secret',flush=True)
 finally:
  failures=[]
  for cid in ids:
   try:call('remove_connection',{'connection_id':cid,'confirm_high_risk':True})
   except Exception:failures.append(cid)
  p.terminate()
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:p.kill();p.wait()
  assert not failures,'Test Keychain cleanup failed for these test-only UUIDs: '+','.join(failures)
  if ids:print('PASS all test Keychain items deleted',flush=True)
