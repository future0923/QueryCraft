#!/usr/bin/env python3
"""Verify SQL result metadata through real libpq/MariaDB clients and localhost protocol fixtures.

Build the MySQL and PostgreSQL dynamic driver schemes first. This does not use saved
connections or contact a real database. Doris shares the MariaDB transport.
"""
from pathlib import Path
import os
import platform
import socket
import struct
import threading
import subprocess

root = Path(__file__).resolve().parent.parent
dd = Path(os.environ.get('DERIVED_DATA', root / '.build/DerivedData'))

args=[ '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc', '-parse-as-library', '-target',platform.machine()+'-apple-macosx15.0', '-sdk',subprocess.check_output(['/usr/bin/xcode-select','-p'],text=True).strip()+'/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk', '-package-name','querycraftdrivers',str(root/'scripts/test-sql-query-metadata.swift'),'-I',str(dd/'Build/Products/Debug'),'-F',str(dd/'Build/Products/Debug/PackageFrameworks'),'-framework','QueryCraftFeature','-framework','QueryCraftPostgreSQLDriver','-framework','QueryCraftMySQLDriver','-o',str(root/'.build/test-sql-query-metadata'),'-Xlinker','-rpath','-Xlinker',str(dd/'Build/Products/Debug/PackageFrameworks')]
for name in ['TreeSitterJSON','TreeSitterSQL','TreeSitter','Internal']:
 args+=['-Xcc','-fmodule-map-file='+str(dd/f'Build/Intermediates.noindex/GeneratedModuleMaps/{name}.modulemap')]
for p in [dd/'SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap',root/'QueryCraftDrivers/Sources/CLibPQ/module.modulemap',root/'QueryCraftDrivers/Sources/CMariaDB/module.modulemap']:
 args+=['-Xcc','-fmodule-map-file='+str(p)]
for p in [root/'ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include',root/'ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include',dd/'SourcePackages/checkouts/tree-sitter/lib/include',dd/'SourcePackages/checkouts/TextStory/Sources/Internal',root/'ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include']:
 args+=['-Xcc','-I'+str(p)]
subprocess.run(args,check=True)
doris_args = []
index = 0
while index < len(args):
 if args[index] == '-framework' and args[index+1] in ('QueryCraftPostgreSQLDriver', 'QueryCraftMySQLDriver'):
  index += 2
  continue
 if args[index] == '-o':
  doris_args += ['-o', str(root / '.build/test-doris-overview')]
  index += 2
  continue
 doris_args.append(args[index])
 index += 1
doris_args += ['-D', 'DORIS_OVERVIEW_FIXTURE', '-framework', 'QueryCraftDorisDriver']
subprocess.run(doris_args,check=True)
errors=[]
def read(c,n):
 data=b''
 while len(data)<n:
  b=c.recv(n-len(data))
  if not b: raise EOFError()
  data+=b
 return data

def pg_send(c,t,p=b''): c.sendall(t+struct.pack('!I',len(p)+4)+p)
def pg_rows(c,fields,rows):
 desc=struct.pack('!H',len(fields))
 for name,oid,num,typ,mod in fields:
  desc+=name.encode()+b'\0'+struct.pack('!IhIhih',oid,num,typ,-1,mod,0)
 pg_send(c,b'T',desc)
 for row in rows:
  vals=struct.pack('!H',len(row))
  for v in row:
   if v is None: vals+=struct.pack('!i',-1)
   else:
    b=v.encode(); vals+=struct.pack('!i',len(b))+b
  pg_send(c,b'D',vals)
 pg_send(c,b'C',f'SELECT {len(rows)}'.encode()+b'\0'); pg_send(c,b'Z',b'I')
def pg_server(listener):
 try:
  with listener.accept()[0] as c:
   c.settimeout(30)
   n=struct.unpack('!I',read(c,4))[0]; startup=read(c,n-4)
   while startup in (struct.pack('!I',80877103), struct.pack('!I',80877104)):
    c.sendall(b'N'); n=struct.unpack('!I',read(c,4))[0]; startup=read(c,n-4)
   pg_send(c,b'R',struct.pack('!I',0))
   for k,v in [('server_version','18.6'),('client_encoding','UTF8'),('server_encoding','UTF8'),('DateStyle','ISO, MDY'),('standard_conforming_strings','on')]:
    pg_send(c,b'S',k.encode()+b'\0'+v.encode()+b'\0')
   pg_send(c,b'K',struct.pack('!II',1,1)); pg_send(c,b'Z',b'I')
   fail=False
   while True:
    t=read(c,1); n=struct.unpack('!I',read(c,4))[0]; q=read(c,n-4).rstrip(b'\0').decode()
    if t==b'X': break
    assert t==b'Q'
    if q.startswith('SET'):
     pg_send(c,b'C',b'SET\0'); pg_send(c,b'Z',b'I')
    elif 'pg_catalog.format_type' in q:
     assert '(0, 1043::oid, 24, 42::oid, 2)' in q
     assert '(2, 20::oid, -1, 0::oid, 0)' in q
     if fail:
      pg_send(c,b'E',b'SERROR\0C42501\0Mfixture metadata unavailable\0\0'); pg_send(c,b'Z',b'I')
     else:
      pg_rows(c,[(n,0,0,25,-1) for n in ['column_index','type','schema','table','column']], [['0','character varying(20)','hr','users','user_nick'],['1','integer','archive','users','id'],['2','bigint',None,None,None]])
    else:
     fail=q=='FAIL_METADATA'
     pg_rows(c,[('display_name',42,2,1043,24),('display_name',43,1,23,-1),('user_nick',0,0,20,-1)],[] if q=='EMPTY_FIXTURE' else [['Alice','1','2']])
 except Exception as e:
  errors.append(e); print('Fixture failure:', repr(e), flush=True)
 finally: listener.close()

def mysql_send(c,p,seq): c.sendall(len(p).to_bytes(3,'little')+bytes([seq])+p)
def mysql_read(c):
 h=read(c,4); return read(c,int.from_bytes(h[:3],'little'))
def le(s):
 b=s.encode(); assert len(b)<251; return bytes([len(b)])+b
def mysql_result(c, names, rows):
 seq=1; mysql_send(c,bytes([len(names)]),seq); seq+=1
 for name in names:
  field=b''.join(le(x) for x in ['def','','','',name,''])+b'\x0c'+struct.pack('<HIBHBH',45,255,253,0,0,0)
  mysql_send(c,field,seq); seq+=1
 eof=b'\xfe'+struct.pack('<HH',0,2)
 mysql_send(c,eof,seq); seq+=1
 for row in rows:
  mysql_send(c,b''.join(b'\xfb' if v is None else le(v) for v in row),seq); seq+=1
 mysql_send(c,eof,seq)

def mysql_server(listener, overview=False):
 try:
  with listener.accept()[0] as c:
   c.settimeout(30)
   caps=512|32768|524288|8192|8
   handshake=b'\x0a5.7.44\0'+struct.pack('<I',1)+b'12345678\0'+struct.pack('<H',caps&65535)+b'\x2d'+struct.pack('<H',2)+struct.pack('<H',caps>>16)+b'\x15'+b'\0'*10+b'abcdefghijkl\0mysql_native_password\0'
   mysql_send(c,handshake,0); mysql_read(c)
   ok=b'\0\0\0'+struct.pack('<HH',2,0); mysql_send(c,ok,2)
   while True:
    p=mysql_read(c)
    if p[0]==1: break
    if p[0]!=3: mysql_send(c,ok,1); continue
    q=p[1:].decode()
    if overview and 'FROM information_schema.TABLES t' in q:
     assert 'information_schema.COLUMNS' not in q and 'field_count' not in q
     if "'legacy'" in q or ("'partial'" in q and 't.TABLE_ROWS' in q) or ("'no_properties'" in q and 't.ENGINE' in q):
      mysql_send(c,b'\xff'+struct.pack('<H',1054)+b'#42S22fixture metadata unavailable',1)
      continue
     mysql_result(c, ['object_name','object_kind','object_comment','row_count','storage_bytes','engine','collation'],
                  [['users','BASE TABLE','员工资料',None if "'partial'" in q else '123456789',None if "'partial'" in q else '4294967296', 'OLAP' if 't.ENGINE' in q else None, 'utf8mb4_bin' if 't.TABLE_COLLATION' in q else None],
                   ['user_view','VIEW','昵称视图',None,None,None,None]])
     continue
    if overview and q.startswith('SHOW FULL TABLES'):
     mysql_result(c, ['Tables_in_legacy','Table_type'], [['users','BASE TABLE'],['user_view','VIEW']])
     continue
    if q not in ('SELECT_FIXTURE','EMPTY_FIXTURE'):
     mysql_send(c,ok,1); continue
    seq=1; mysql_send(c,b'\x03',seq); seq+=1
    for db,table,name,original,typ,flags in [('hr','users','display_name','user_nick',253,0),('archive','users','display_name','id',3,0),('','','user_nick','',8,32)]:
     f=b''.join(le(x) for x in ['def',db,table,table,name,original])+b'\x0c'+struct.pack('<HIBHBH',45,80,typ,flags,0,0)
     mysql_send(c,f,seq); seq+=1
    eof=b'\xfe'+struct.pack('<HH',0,2)
    mysql_send(c,eof,seq); seq+=1
    if q!='EMPTY_FIXTURE': mysql_send(c,le('Alice')+le('1')+le('2'),seq); seq+=1
    mysql_send(c,eof,seq)
 except Exception as e:
  errors.append(e); print('Fixture failure:', repr(e), flush=True)
 finally: listener.close()

listeners=[]; threads=[]
for worker in (pg_server,mysql_server,lambda listener: mysql_server(listener, overview=True)):
 s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(1); s.settimeout(30)
 listeners.append(s); t=threading.Thread(target=worker,args=(s,),daemon=True); t.start(); threads.append(t)
ports=[str(s.getsockname()[1]) for s in listeners]
try:
 subprocess.run([str(root/'.build/test-sql-query-metadata'),*ports[:2]],check=True,timeout=30)
 subprocess.run([str(root/'.build/test-doris-overview'),ports[2]],check=True,timeout=30)
finally:
 for s in listeners: s.close()
 for t in threads: t.join(timeout=2)
 if errors:
  raise RuntimeError(errors)
