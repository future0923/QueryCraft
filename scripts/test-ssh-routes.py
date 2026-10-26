#!/usr/bin/env python3
"""Native jump/agent extension acceptance, isolated sshd/agent fixtures only."""
import argparse, base64, ctypes as c, getpass, hashlib, importlib.util, os, socket, subprocess, tempfile, threading, time
from pathlib import Path
spec=importlib.util.spec_from_file_location('abi',Path(__file__).with_name('test-ssh-plugin.py'))
abi=importlib.util.module_from_spec(spec);spec.loader.exec_module(abi)
class Diagnostic(c.Structure):
    _fields_=[(name,c.c_uint32) for name in ["size","endpoint_index","hop_count","phase"]]
class Hop(c.Structure):
    _fields_=[('size',c.c_uint32),('connection',abi.Request),('agent_socket',c.c_char_p)]
class Options(c.Structure):
    _fields_=[('size',c.c_uint32),('agent_socket',c.c_char_p),('hops',c.POINTER(Hop)),('hop_count',c.c_uint32),('scan_host_key',c.c_uint32)]

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--bundle',type=Path,required=True);args=ap.parse_args()
    subprocess.run(['codesign','--verify','--deep','--strict',str(args.bundle)],check=True)
    lib=c.CDLL(str(args.bundle/'Contents/MacOS/QueryCraftSSH'))
    create=lib.querycraft_ssh_plugin_create;create.argtypes=[c.POINTER(abi.Request)];create.restype=c.c_void_p
    file_create=lib.querycraft_ssh_plugin_file_create;file_create.argtypes=[c.POINTER(abi.FileRequest)];file_create.restype=c.c_void_p
    run=lib.querycraft_ssh_plugin_run;run.argtypes=[c.c_void_p];run.restype=c.POINTER(abi.Result)
    destroy=lib.querycraft_ssh_plugin_destroy;destroy.argtypes=[c.c_void_p]
    cancel=lib.querycraft_ssh_plugin_cancel;cancel.argtypes=[c.c_void_p]
    configure=lib.querycraft_ssh_plugin_set_route;configure.argtypes=[c.c_void_p,c.POINTER(Options)];configure.restype=c.c_int32
    diagnostic=lib.querycraft_ssh_plugin_diagnostic;diagnostic.argtypes=[c.c_void_p];diagnostic.restype=c.POINTER(Diagnostic)
    assert lib.querycraft_ssh_plugin_diagnostic_version()==1
    observed=[]
    def expect_diagnostic(index,hops,phase):
        assert observed==[c.sizeof(Diagnostic),index,hops,phase],observed
    assert lib.querycraft_ssh_plugin_route_version()==1
    with tempfile.TemporaryDirectory(prefix='qc-route-') as temp:
        root=Path(temp);servers=[];agent=None;stop=threading.Event()
        try:
            for name,kind in [('jump-key','ed25519'),('target-key','ed25519'),('rsa-key','rsa')]:
                subprocess.run(['ssh-keygen','-q','-t',kind,'-N','','-f',str(root/name)],check=True)
            def start(name,authorized,forward=True):
                subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(root/(name+'-host'))],check=True)
                (root/(name+'-authorized')).write_bytes(b''.join((root/(key+'.pub')).read_bytes() for key in authorized))
                with socket.socket() as listener:listener.bind(('127.0.0.1',0));port=listener.getsockname()[1]
                config=root/(name+'.conf');config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {root}/{name}-host
PidFile {root}/{name}.pid
AuthorizedKeysFile {root}/{name}-authorized
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {getpass.getuser()}
AllowTcpForwarding {'yes' if forward else 'no'}
LogLevel ERROR
Subsystem sftp internal-sftp
''')
                log=(root/(name+'.log')).open('wb');p=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=log,stderr=log);servers.append((p,log))
                for _ in range(100):
                    if p.poll() is not None:raise AssertionError((root/(name+'.log')).read_text())
                    try:
                        with socket.create_connection(('127.0.0.1',port),timeout=.05):break
                    except OSError:time.sleep(.02)
                else:raise AssertionError('sshd fixture did not start')
                pin=subprocess.check_output(['ssh-keygen','-lf',str(root/(name+'-host.pub')),'-E','sha256'],text=True).split()[1]
                return port,pin
            jump=start('jump',['jump-key']);target=start('target',['target-key','rsa-key']);denied=start('denied',['jump-key'],False)
            agent_path=root/'agent.sock';agent_log=(root/'agent.log').open('wb')
            agent=subprocess.Popen(['/usr/bin/ssh-agent','-D','-a',str(agent_path)],stdout=agent_log,stderr=agent_log)
            for _ in range(100):
                if agent_path.exists():break
                time.sleep(.02)
            env=dict(os.environ,SSH_AUTH_SOCK=str(agent_path))
            def add_key(key):subprocess.run(['/usr/bin/ssh-add',str(root/key)],env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            def clear():subprocess.run(['/usr/bin/ssh-add','-D'],env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            def request(endpoint=target,key='target-key',command='printf routed',timeout=5000,pin=None):
                return abi.Request(c.sizeof(abi.Request),b'127.0.0.1',endpoint[0],getpass.getuser().encode(),(pin or endpoint[1]).encode(),str(root/key).encode() if key else None,None,command.encode() if command else None,timeout,16384)
            def options(hops=(),agent_socket=None,scan=False):
                array=(Hop*len(hops))(*[Hop(c.sizeof(Hop),r,s.encode() if s else None) for r,s in hops])
                value=Options(c.sizeof(Options),str(agent_socket).encode() if agent_socket else None,array,len(hops),scan)
                value._array=array;return value
            def execute(req,opts=None,file=None):
                task=(file_create if file else create)(c.byref(file or req));assert task
                try:
                    if opts is not None:
                        assert configure(task,c.byref(opts))==0
                        assert configure(task,c.byref(opts))==1
                    result=run(task).contents
                    info=diagnostic(task).contents
                    observed[:]=[info.size,info.endpoint_index,info.hop_count,info.phase]
                    return result.status,c.string_at(result.stdout_data,result.stdout_length),result.output_bytes
                finally:destroy(task)
            add_key('target-key')
            assert execute(request(key=None),options(agent_socket=agent_path))[:2]==(0,b'routed')
            clear();add_key('rsa-key')
            assert execute(request(key=None),options(agent_socket=agent_path))[:2]==(0,b'routed')
            clear();assert execute(request(key=None),options(agent_socket=agent_path))[0]==17
            add_key('target-key');add_key('jump-key')
            hop=request(jump,'jump-key',command=None)
            route=options([(hop,None)])
            assert execute(request(),route)[:2]==(0,b'routed')
            assert execute(request(),options([(hop,None),(hop,None)]))[:2]==(0,b'routed')
            assert execute(request(),options([(hop,None)]*4))[:2]==(0,b'routed')
            descriptor_count=len(os.listdir('/dev/fd'))
            for _ in range(8): assert execute(request(),route)[0]==0
            assert len(os.listdir('/dev/fd'))==descriptor_count
            agent_hop=request(jump,key=None,command=None)
            assert execute(request(key=None),options([(agent_hop,str(agent_path))],agent_socket=agent_path))[:2]==(0,b'routed')
            assert execute(request(),options([(request(denied,'jump-key',command=None),None)]))[0]!=0, 'forwarding denial was bypassed'
            expect_diagnostic(2,1,7)
            wrong='SHA256:'+'A'*43
            assert execute(request(pin=wrong),route)[0]==3
            expect_diagnostic(2,1,5)
            assert execute(request(),options([(request(jump,'jump-key',command=None,pin=wrong),None)]))[0]==3
            expect_diagnostic(1,1,5)
            assert execute(request(),options([(request(jump,'target-key',command=None),None)]))[0]==4
            expect_diagnostic(1,1,6)
            assert execute(request(pin=wrong))[0]==3
            expect_diagnostic(1,0,5)
            assert execute(request(key='jump-key'))[0]==4
            expect_diagnostic(1,0,6)
            bad_dns=request();bad_dns.host=b'a'*1025
            assert execute(bad_dns)[0]==2
            expect_diagnostic(1,0,2)
            unreachable=request();unreachable.port=1
            assert execute(unreachable)[0]==2
            expect_diagnostic(1,0,3)
            assert execute(request(),options([(hop,None),(request(jump,'target-key',command=None),None)]))[0]==4
            expect_diagnostic(2,2,6)
            missing=abi.FileRequest(c.sizeof(abi.FileRequest),request(command=None),1,str(root/'absent').encode(),None,None,0,0,0,0)
            assert execute(None,route,missing)[0]==10
            expect_diagnostic(2,1,10)
            # Scanning authenticates the jump but neither reads nor sends target credentials.
            scan=request(key='missing-key',command=None,pin=wrong)
            assert execute(scan,options([(hop,None)],scan=True))[:2]==(0,target[1].encode())
            print('PASS agent Ed25519/RSA-SHA2/empty agent; one/two-hop/mixed agent routes; per-hop pins/auth; forwarding denial; unauthenticated target-key scan',flush=True)
            payload=bytes(range(256))*8192;source=root/'source';source.write_bytes(payload);remote=root/'remote';download=root/'download'
            def transfer(op,local):
                return abi.FileRequest(c.sizeof(abi.FileRequest),request(command=None),op,str(remote).encode(),str(local).encode(),str(root/('.stage-'+str(op))).encode(),0,67108864,100,0)
            uploaded=execute(None,route,transfer(4,source));assert uploaded==(0,hashlib.sha256(payload).hexdigest().encode(),len(payload))
            downloaded=execute(None,route,transfer(5,download));assert downloaded==uploaded and download.read_bytes()==payload
            assert execute(request(command='sleep 5',timeout=500),route)[0]==5
            expect_diagnostic(2,1,9)
            task=create(c.byref(request(command='sleep 10',timeout=15000)));assert configure(task,c.byref(route))==0
            values=[];worker=threading.Thread(target=lambda:values.append(run(task).contents.status));worker.start();time.sleep(.25);before=time.monotonic();cancel(task);worker.join(2)
            assert not worker.is_alive() and values==[6] and time.monotonic()-before<1.5;destroy(task)
            # A stuck or malicious local agent cannot stall the request or allocate unbounded data.
            def fake_agent(name,oversize=False):
                path=root/name;listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);listener.bind(str(path));listener.listen(8);listener.settimeout(.1)
                def serve():
                    clients=[]
                    try:
                        while not stop.is_set():
                            try:
                                conn,_=listener.accept();clients.append(conn)
                                if oversize:conn.sendall(b'\x7f\xff\xff\xff')
                            except socket.timeout:pass
                    finally:
                        for conn in clients:conn.close()
                        listener.close()
                worker=threading.Thread(target=serve);worker.start();return path,worker
            hung,hung_worker=fake_agent('hung.sock');bad,bad_worker=fake_agent('bad.sock',True)
            before=time.monotonic();assert execute(request(key=None,timeout=600),options(agent_socket=hung))[0]==5;assert time.monotonic()-before<2
            expect_diagnostic(1,0,6)
            assert execute(request(key=None),options(agent_socket=bad))[0]==17
            task=create(c.byref(request(key=None,timeout=15000)));hung_options=options(agent_socket=hung);assert configure(task,c.byref(hung_options))==0
            values=[];worker=threading.Thread(target=lambda:values.append(run(task).contents.status));worker.start();time.sleep(.3);cancel(task);worker.join(2);assert values==[6];destroy(task)
            stop.set();hung_worker.join(2);bad_worker.join(2)
            # Pool must not retain agent-authenticated sessions after identities disappear.
            pool_create=lib.querycraft_ssh_plugin_pool_create;pool_create.argtypes=[c.c_uint32,c.c_uint32,c.c_uint32];pool_create.restype=c.c_void_p
            pool_run=lib.querycraft_ssh_plugin_pool_run;pool_run.argtypes=[c.c_void_p,c.c_void_p,c.c_char_p];pool_run.restype=c.POINTER(abi.Result)
            pool_destroy=lib.querycraft_ssh_plugin_pool_destroy;pool_destroy.argtypes=[c.c_void_p]
            pool=pool_create(2,60000,300000)
            try:
                for expected in [0,17]:
                    task=create(c.byref(request(key=None)));agent_options=options(agent_socket=agent_path);assert configure(task,c.byref(agent_options))==0
                    try:assert pool_run(pool,task,b'agent-fixture').contents.status==expected
                    finally:destroy(task)
                    clear()
            finally:pool_destroy(pool)
            print('PASS routed binary SFTP/hash, timeout/cancel, hung/oversized agent bounds and agent-removal pool bypass',flush=True)
        finally:
            stop.set()
            if agent:
                agent.terminate();agent.wait(timeout=5);agent_log.close()
            for p,log in servers:p.terminate();p.wait(timeout=5);log.close()
if __name__=='__main__':main()
