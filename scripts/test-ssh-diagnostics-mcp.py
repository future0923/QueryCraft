#!/usr/bin/env python3
"""Isolated stdio diagnostics and loaded-versus-installed version acceptance."""
import argparse, getpass, importlib.util, json, os, plistlib, socket, subprocess, tempfile, time
from pathlib import Path

ap=argparse.ArgumentParser(description=__doc__)
for name in ['mcp','bundle','legacy-bundle']:ap.add_argument('--'+name,type=Path,required=True)
args=ap.parse_args()
spec=importlib.util.spec_from_file_location('protocol',Path(__file__).with_name('test-mcp-protocol.py'))
protocol=importlib.util.module_from_spec(spec);spec.loader.exec_module(protocol)
with tempfile.TemporaryDirectory(prefix='qc-diagnostics-') as temp:
    root=Path(temp);data=root/'QueryCraftDev';data.mkdir();process=server=None;sequence=0
    settings=protocol.policy(5226);settings['mode']='high_risk_write';settings['disabledTools']=[];settings['queryTimeoutSeconds']=5
    def policy():
        path=data/'.policy';path.write_text(json.dumps(settings));path.chmod(0o600);path.replace(data/'mcp-policy.json')
    def install(bundle):subprocess.run([str(args.mcp),'--data-dir',str(data),'--install-ssh-plugin',str(bundle.resolve())],check=True,stdout=subprocess.DEVNULL)
    def start():
        global process
        process=subprocess.Popen([str(args.mcp),'--stdio','--data-dir',str(data)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        protocol.send(process,protocol.INIT);protocol.send(process,{'jsonrpc':'2.0','method':'notifications/initialized'},False)
    def stop():
        if process and process.poll() is None:
            process.stdin.close()
            try:process.wait(timeout=10)
            except subprocess.TimeoutExpired:process.terminate();process.wait(timeout=5)
    def call(name,values={}):
        global sequence
        sequence+=1
        return protocol.send(process,{'jsonrpc':'2.0','id':sequence,'method':'tools/call','params':{'name':'querycraft_'+name,'arguments':values}})['result']
    def success(name,values={}):
        result=call(name,values);assert not result.get('isError'),result;return result['structuredContent']
    def change_link(link,target):
        stage=link.with_name('.next');stage.symlink_to(target);stage.replace(link)
    try:
        policy()
        mcp_current=data/'MCP/Current';mcp_current.parent.mkdir();mcp_current.symlink_to(args.mcp.resolve().parents[2])
        install(args.legacy_bundle);start()
        before=success('runtime_info');assert before['host']['loaded']['runtime_build'],before
        assert before['reconnect_required'] is False,before
        assert before['ssh']['loaded']['extensions']['diagnostics'] is None,before
        legacy_version=before['ssh']['loaded']['bundle']['version']
        install(args.bundle)
        after=success('runtime_info')
        assert after['ssh']['loaded']['bundle']['version']==legacy_version and after['ssh']['loaded']['extensions']['diagnostics'] is None,after
        assert after['ssh']['installed_metadata']['version']=='0.7.0' and after['ssh']['reconnect_required'] and after['reconnect_required'],after
        stop();start()
        fresh=success('runtime_info');assert fresh['reconnect_required'] is False and fresh['ssh']['loaded']['extensions']['diagnostics']==1,fresh
        plugins=success('plugin_list');ssh=next(p for p in plugins if p['id']=='ssh');assert ssh['runtime']==fresh['ssh']['loaded']
        # Current changes can have the same marketing version/build. A unique
        # packaged runtime build and immutable location still detect staleness.
        other=root/'replacement.app/Contents';other.mkdir(parents=True)
        info=plistlib.loads((args.mcp.resolve().parents[2]/'Contents/Info.plist').read_bytes());info['QCRuntimeBuild']='replacement-fixture'
        (other/'Info.plist').write_bytes(plistlib.dumps(info));change_link(mcp_current,other.parent)
        stale=success('runtime_info');assert stale['host']['reconnect_required'] and stale['host']['loaded']==fresh['host']['loaded'],stale
        assert stale['host']['installed']['runtime_build']=='replacement-fixture'
        change_link(mcp_current,args.mcp.resolve().parents[2]);assert success('runtime_info')['reconnect_required'] is False
        print('PASS stdio runtime versions/capabilities, old plugin actual capabilities, atomic upgrade without reload, reconnection and same-version host update detection',flush=True)

        for name in ['host','client']:subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(root/name)],check=True)
        with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        conf=root/'sshd.conf';conf.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {root}/host
PidFile {root}/sshd.pid
AuthorizedKeysFile {root}/client.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {getpass.getuser()}
AllowTcpForwarding yes
Subsystem sftp internal-sftp
LogLevel ERROR
''')
        log=(root/'sshd.log').open('wb');server=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(conf)],stdout=log,stderr=log)
        for _ in range(100):
            if server.poll() is not None:raise AssertionError('Owned sshd failed to start')
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.05):break
            except OSError:time.sleep(.02)
        pin=subprocess.check_output(['ssh-keygen','-lf',str(root/'host.pub'),'-E','sha256'],text=True).split()[1]
        common=dict(host='127.0.0.1',port=port,username=getpass.getuser(),host_fingerprint=pin,private_key_path=str(root/'client'))
        jump=success('ssh_add_connection',dict(common,name='jump'))['connection_id']
        middle=success('ssh_add_connection',dict(common,name='middle',jump_connection_id=jump))['connection_id']
        target=success('ssh_add_connection',dict(common,name='target',jump_connection_id=middle))['connection_id']
        settings['ssh']={'connectionIDs':[jump,middle,target],'executionConnectionIDs':[target],'fileReadConnectionIDs':[target],'fileTransferConnectionIDs':[target]};policy()
        success('ssh_test_connection',{'connection_id':target})
        accounts=data/'ssh-connections.json';original=json.loads(accounts.read_text())
        def update(id,**fields):
            changed=json.loads(json.dumps(original))
            next(p for p in changed['connections'] if p['id']==id).update(fields)
            stage=data/'.accounts';stage.write_text(json.dumps(changed));stage.chmod(0o600);stage.replace(accounts)
        def failure(index,phase,id,tool='ssh_test_connection',extra={}):
            result=call(tool,dict(connection_id=target,**extra));assert result.get('isError'),result
            error=result['structuredContent']['error'];diag=error['details']['ssh']
            assert (diag['endpoint_index'],diag['jump_count'],diag['phase'],diag['connection_id'])==(index,2,phase,id),error
            assert error['automatic_retry'] is False
            text=json.dumps(error);assert str(root/'client') not in text and pin not in text,error
            return diag
        wrong='SHA256:'+'A'*43
        update(middle,hostFingerprint=wrong);failure(2,'host_key',middle)
        update(target,hostFingerprint=wrong);failure(3,'host_key',target)
        update(jump,hostFingerprint=wrong);failure(1,'host_key',jump)
        update(target,privateKeyPath=str(root/'missing-key'));failure(3,'authentication',target)
        update(target,port=1);diag=failure(3,'forwarding',target);assert diag['via_connection_id']==middle
        update(middle,hostFingerprint=wrong)
        source=root/'source';source.write_bytes(b'owned diagnostic transfer')
        accepted=success('ssh_start_transfer',dict(connection_id=target,direction='upload',local_path=str(source),remote_path=str(root/'not-created'),confirm_high_risk=True))
        failure(2,'host_key',middle,'ssh_upload_file',dict(local_path=str(source),remote_path=str(root/'not-created-sync'),confirm_high_risk=True))
        query=dict(connection_id=target,transfer_id=accepted['transfer_id'])
        for _ in range(50):
            status=success('ssh_transfer_status',query)
            if status['state']=='failed':break
            time.sleep(.05)
        assert status['state']=='failed' and status['ssh_diagnostic']['endpoint_index']==2 and status['ssh_diagnostic']['phase']=='host_key',status
        assert not (root/'not-created').exists()
        stop();start();assert success('ssh_transfer_status',query)['ssh_diagnostic']==status['ssh_diagnostic']
        update(target)
        failure(3,'sftp',target,'ssh_stat_file',{'path':str(root/'missing')})
        settings['queryTimeoutSeconds']=1;policy()
        failure(3,'command',target,'ssh_execute',{'command':'sleep 5','confirm_high_risk':True})
        # Same host, legacy plugin: no diagnostic invented by the new bridge.
        stop();install(args.legacy_bundle);start();update(middle,hostFingerprint=wrong)
        legacy=call('ssh_test_connection',{'connection_id':target});assert legacy.get('isError') and 'details' not in legacy['structuredContent']['error'],legacy
        print('PASS actual stdio first/middle/target pin, target authentication, forwarding predecessor, SFTP, retained asynchronous transfer failure and command timeout details; legacy plugin honest fallback',flush=True)
    finally:
        stop()
        if server:server.terminate();server.wait(timeout=5);log.close()
