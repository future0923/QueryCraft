#!/usr/bin/env python3
"""Use an explicitly authorized SSH server as its own jump, in isolated storage."""
import argparse,getpass,hashlib,importlib.util,json,subprocess,tempfile,uuid
from pathlib import Path
ap=argparse.ArgumentParser(description=__doc__)
for name in ['mcp','bundle']:ap.add_argument('--'+name,type=Path,required=True)
for name in ['host','username','fingerprint']:ap.add_argument('--'+name,required=True)
args=ap.parse_args();secret=getpass.getpass('SSH password (hidden): ')
spec=importlib.util.spec_from_file_location('protocol',Path(__file__).with_name('test-mcp-protocol.py'));protocol=importlib.util.module_from_spec(spec);spec.loader.exec_module(protocol)
with tempfile.TemporaryDirectory(prefix='qc-real-jump-') as temp:
    root=Path(temp);settings=protocol.policy(5226);settings['mode']='high_risk_write';settings['disabledTools']=[];settings['queryTimeoutSeconds']=30;ids=[]
    def save():(root/'mcp-policy.json').write_text(json.dumps(settings))
    save();subprocess.run([str(args.mcp),'--data-dir',str(root),'--install-ssh-plugin',str(args.bundle.resolve())],check=True,stdout=subprocess.DEVNULL)
    p=subprocess.Popen([str(args.mcp),'--stdio','--data-dir',str(root)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    sequence=10;remote='/tmp/querycraft-jump-fixture-'+uuid.uuid4().hex
    def call(name,values,expected=None):
        global sequence
        sequence+=1
        result=protocol.send(p,{'jsonrpc':'2.0','id':sequence,'method':'tools/call','params':{'name':'querycraft_'+name,'arguments':values}})['result'];value=result['structuredContent']
        if expected:assert result.get('isError') and value['error']['code']==expected,value
        else:assert not result.get('isError'),value
        return value
    try:
        protocol.send(p,protocol.INIT);protocol.send(p,{'jsonrpc':'2.0','method':'notifications/initialized'},False)
        common=dict(host=args.host,username=args.username,host_fingerprint=args.fingerprint,password=secret)
        jump=call('ssh_add_connection',dict(common,name='owned jump fixture'))['connection_id'];ids.append(jump)
        target=call('ssh_add_connection',dict(common,name='owned target fixture',jump_connection_id=jump))['connection_id'];ids.append(target)
        settings['ssh']={'connectionIDs':[target],'executionConnectionIDs':[target],'fileReadConnectionIDs':[target],'fileTransferConnectionIDs':[target]};save()
        call('ssh_test_connection',{'connection_id':target},'ACCESS_DENIED')
        settings['ssh']['connectionIDs'].append(jump);save()
        call('ssh_test_connection',{'connection_id':target})
        value=call('ssh_execute',dict(connection_id=target,command="printf 'real-jump-ok\\n'; uname -s",confirm_high_risk=True))
        assert value['stdout'].startswith('real-jump-ok\n'),value
        source=root/'source';payload=bytes(range(256))*256;source.write_bytes(payload)
        transfer=dict(connection_id=target,local_path=str(source),remote_path=remote,confirm_high_risk=True)
        upload=call('ssh_upload_file',transfer);assert upload['sha256']==hashlib.sha256(payload).hexdigest()
        destination=root/'download';call('ssh_download_file',dict(transfer,local_path=str(destination)));assert destination.read_bytes()==payload
        call('ssh_execute',dict(connection_id=target,command='rm -- '+remote,confirm_high_risk=True))
        call('ssh_execute',dict(connection_id=jump,command='printf forbidden',confirm_high_risk=True),'ACCESS_DENIED')
        print('PASS authorized real-server password jump via Keychain, independent jump grants, remote exec and binary SFTP/SHA256',flush=True)
    finally:
        if ids:
            try:
                settings['ssh']={'connectionIDs':ids[:],'executionConnectionIDs':ids[:]};save()
                call('ssh_execute',dict(connection_id=ids[0],command='test ! -e '+remote+' || rm -- '+remote,confirm_high_risk=True))
                for id in reversed(ids):call('ssh_remove_connection',dict(connection_id=id,confirm_high_risk=True))
            finally:
                p.stdin.close();p.wait(timeout=10)
        else:p.stdin.close();p.wait(timeout=10)
        secret=''
