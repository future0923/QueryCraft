#!/usr/bin/env python3
"""End-to-end stdio jump/agent tests with owned local sshd, agent and accounts."""
import argparse,hashlib,importlib.util,json,os,socket,subprocess,tempfile,time,getpass
from pathlib import Path
ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--mcp',type=Path,required=True);ap.add_argument('--bundle',type=Path,required=True);args=ap.parse_args()
spec=importlib.util.spec_from_file_location('protocol',Path(__file__).with_name('test-mcp-protocol.py'));protocol=importlib.util.module_from_spec(spec);spec.loader.exec_module(protocol)
with tempfile.TemporaryDirectory(prefix='qc-mcp-routes-') as temp:
    root=Path(temp);data=root/'data';data.mkdir();process=server=agent=None;ids=[];tasks=[]
    try:
        for name in ['host','client']:
            subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(root/name)],check=True)
        with socket.socket() as listener:listener.bind(('127.0.0.1',0));port=listener.getsockname()[1]
        config=root/'sshd_config';config.write_text(f'''Port {port}
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
LogLevel ERROR
Subsystem sftp internal-sftp
SetEnv PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
''')
        sshlog=(root/'sshd.log').open('wb');server=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=sshlog,stderr=sshlog)
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.05):break
            except OSError:time.sleep(.02)
        pin=subprocess.check_output(['ssh-keygen','-lf',str(root/'host.pub'),'-E','sha256'],text=True).split()[1]
        agent_path=root/'agent.sock';agentlog=(root/'agent.log').open('wb');agent=subprocess.Popen(['/usr/bin/ssh-agent','-D','-a',str(agent_path)],stdout=agentlog,stderr=agentlog)
        for _ in range(100):
            if agent_path.exists():break
            time.sleep(.02)
        env=dict(os.environ,SSH_AUTH_SOCK=str(agent_path));subprocess.run(['/usr/bin/ssh-add',str(root/'client')],env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        settings=protocol.policy(5226);settings['mode']='high_risk_write';settings['disabledTools']=[];settings['queryTimeoutSeconds']=15
        def save():
            staging=data/'.policy';staging.write_text(json.dumps(settings));staging.chmod(0o600);staging.replace(data/'mcp-policy.json')
        save()
        subprocess.run([str(args.mcp),'--data-dir',str(data),'--install-ssh-plugin',str(args.bundle.resolve())],check=True,stdout=subprocess.DEVNULL)
        process=subprocess.Popen([str(args.mcp),'--stdio','--data-dir',str(data)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        protocol.send(process,protocol.INIT);protocol.send(process,{'jsonrpc':'2.0','method':'notifications/initialized'},False)
        sequence=10
        def call(name,values):
            global sequence
            sequence+=1
            response=protocol.send(process,{'jsonrpc':'2.0','id':sequence,'method':'tools/call','params':{'name':'querycraft_'+name,'arguments':values}})['result']
            return response.get('isError',False),response['structuredContent']
        def success(name,values):
            error,result=call(name,values);assert not error,result;return result
        def failure(name,values,code):
            error,result=call(name,values);assert error and result['error']['code']==code,result
        common=dict(host='127.0.0.1',port=port,username=getpass.getuser(),host_fingerprint=pin)
        def add(name,**fields):
            profile=success('ssh_add_connection',dict(common,name=name,**fields));assert not profile['authorized'];ids.append(profile['connection_id']);return profile['connection_id']
        jump=add('jump',private_key_path=str(root/'client'))
        middle=add('middle',authentication='agent',agent_socket_path=str(agent_path),jump_connection_id=jump)
        target=add('target',authentication='agent',agent_socket_path=str(agent_path),jump_connection_id=middle)
        settings['ssh']={'connectionIDs':[target],'executionConnectionIDs':[target],'fileReadConnectionIDs':[target],'fileTransferConnectionIDs':[target]};save()
        selector={'connection_id':target}
        failure('ssh_test_connection',selector,'ACCESS_DENIED')
        settings['ssh']['connectionIDs']=[jump,middle,target];save()
        success('ssh_test_connection',selector)
        command=dict(selector,command='printf stdio-route-agent',confirm_high_risk=True)
        assert success('ssh_execute',command)['stdout']=='stdio-route-agent'
        failure('ssh_execute',dict(command,connection_id=jump),'ACCESS_DENIED')
        failure('ssh_remove_connection',dict(connection_id=jump,confirm_high_risk=True),'INVALID_ARGUMENT')
        payload=bytes(range(256))*4096;source=root/'source';source.write_bytes(payload);remote=root/'remote';destination=root/'download'
        transfer=dict(selector,local_path=str(source),remote_path=str(remote),confirm_high_risk=True)
        uploaded=success('ssh_upload_file',transfer);assert uploaded['sha256']==hashlib.sha256(payload).hexdigest() and remote.read_bytes()==payload
        status=success('ssh_transfer_status',dict(selector,transfer_id=uploaded['transfer_id']));assert status['state']=='completed'
        success('ssh_download_file',dict(transfer,local_path=str(destination)));assert destination.read_bytes()==payload
        task=success('ssh_start_task',dict(selector,command='printf routed-task; sleep 1',confirm_high_risk=True));tasks.append(task['task_id'])
        for _ in range(30):
            done=success('ssh_task_status',dict(selector,task_id=task['task_id']))
            if done['state']=='completed':break
            time.sleep(.1)
        assert done['state']=='completed',done
        output=success('ssh_task_output',dict(selector,task_id=task['task_id']));assert output['display_text']=='routed-task'
        success('ssh_remove_task',dict(selector,task_id=task['task_id'],confirm_high_risk=True));tasks.remove(task['task_id'])
        # Grant removal blocks new route use without granting commands on jumps.
        settings['ssh']['connectionIDs'].remove(middle);save();failure('ssh_execute',command,'ACCESS_DENIED')
        settings['ssh']['connectionIDs'].append(middle);save()
        subprocess.run(['/usr/bin/ssh-add','-D'],env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        failure('ssh_test_connection',selector,'CREDENTIAL_UNAVAILABLE')
        archive=json.loads((data/'ssh-connections.json').read_text());assert archive['version']==2
        profiles=archive['connections']
        assert all(not p['storesCredential'] for p in profiles)
        assert next(p for p in profiles if p['id']==target)['authentication']=='agent'
        print('PASS stdio agent/two-hop mixed authentication, independent hop grants, no jump shell grant, dependency-safe removal, routed SFTP/hash/results/tasks and agent-key removal',flush=True)
    finally:
        if process and process.poll() is None:
            try:
                if tasks:
                    subprocess.run(['/usr/bin/ssh-add',str(root/'client')],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                    settings['ssh']['connectionIDs']=ids[:];save()
                    for task in tasks:
                        success('ssh_cancel_task',dict(connection_id=target,task_id=task,confirm_high_risk=True));time.sleep(.3)
                        success('ssh_remove_task',dict(connection_id=target,task_id=task,confirm_high_risk=True))
                for id in reversed(ids):success('ssh_remove_connection',dict(connection_id=id,confirm_high_risk=True))
            finally:
                process.stdin.close()
                try:process.wait(timeout=10)
                except subprocess.TimeoutExpired:process.terminate();process.wait(timeout=5)
        if agent:agent.terminate();agent.wait(timeout=5);agentlog.close()
        if server:server.terminate();server.wait(timeout=5);sshlog.close()
