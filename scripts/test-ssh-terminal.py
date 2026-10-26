#!/usr/bin/env python3
"""Native PTY acceptance against an isolated loopback OpenSSH server. No remote dependencies."""
import argparse
import ctypes as c
import getpass
import importlib.util
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

spec = importlib.util.spec_from_file_location('native', Path(__file__).with_name('test-ssh-plugin.py'))
native = importlib.util.module_from_spec(spec); spec.loader.exec_module(native)

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--bundle', type=Path, required=True); args = parser.parse_args()
    lib = c.CDLL(str(args.bundle.resolve() / 'Contents/MacOS/QueryCraftSSH'))
    create = lib.querycraft_ssh_plugin_create; create.argtypes = [c.POINTER(native.Request)]; create.restype = c.c_void_p
    run = lib.querycraft_ssh_plugin_run; run.argtypes = [c.c_void_p]; run.restype = c.POINTER(native.Result)
    destroy = lib.querycraft_ssh_plugin_destroy; destroy.argtypes = [c.c_void_p]
    cancel = lib.querycraft_ssh_plugin_cancel; cancel.argtypes = [c.c_void_p]
    configure = lib.querycraft_ssh_plugin_set_terminal; configure.argtypes = [c.c_void_p, c.c_int32, c.c_uint32, c.c_uint32]
    resize = lib.querycraft_ssh_plugin_terminal_resize; resize.argtypes = [c.c_void_p, c.c_uint32, c.c_uint32]
    ready = lib.querycraft_ssh_plugin_terminal_ready; ready.argtypes = [c.c_void_p]; ready.restype = c.c_uint32
    assert lib.querycraft_ssh_plugin_terminal_version() == 1
    with tempfile.TemporaryDirectory(prefix='qc-pty-') as temporary:
        root = Path(temporary)
        for name in ['host', 'client']:
            subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(root/name)], check=True)
        fingerprint = subprocess.check_output(['ssh-keygen','-lf',str(root/'host.pub'),'-E','sha256'],text=True).split()[1]
        with socket.socket() as listener: listener.bind(('127.0.0.1',0)); port = listener.getsockname()[1]
        config = root/'sshd_config'; config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {root}/host
PidFile {root}/sshd.pid
AuthorizedKeysFile {root}/client.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {getpass.getuser()}
LogLevel ERROR
''')
        with (root/'sshd.log').open('w') as log:
            server = subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=log,stderr=log)
            active = []
            try:
                for _ in range(100):
                    try:
                        with socket.create_connection(('127.0.0.1',port),timeout=.1): break
                    except OSError: time.sleep(.03)
                def start(pin=fingerprint, timeout=5000):
                    req = native.Request(c.sizeof(native.Request),b'127.0.0.1',port,getpass.getuser().encode(),pin.encode(),str(root/'client').encode(),None,None,timeout,1)
                    task = create(c.byref(req)); assert task
                    client, peer = socket.socketpair(); client.settimeout(.2)
                    assert configure(task,peer.fileno(),100,30)==0
                    assert configure(task,peer.fileno(),100,30)==native_status_invalid
                    peer.close()
                    result = {}
                    def execute():
                        raw = run(task).contents; result.update(status=raw.status,exit=raw.exit_status)
                    thread = threading.Thread(target=execute); thread.start()
                    active.append((task,client,thread))
                    return task, client, thread, result
                def read_until(client, needle, timeout=8):
                    output = b''; end = time.monotonic()+timeout
                    while needle not in output and time.monotonic()<end:
                        try:
                            data=client.recv(65536)
                            if not data: break
                            output+=data
                        except socket.timeout: pass
                    assert needle in output, repr(output[-800:])
                    return output
                def send(client, command): client.sendall(command.encode()+b'\r')
                task, client, thread, result = start(timeout=1000)
                end=time.monotonic()+5
                while not ready(task) and time.monotonic()<end: time.sleep(.01)
                assert ready(task)
                send(client,"stty -echo; PS1='QC> '; printf '\\nREADY\\n'"); read_until(client,b'READY\r\n')
                # Session persists beyond setup timeout and cd changes subsequent commands.
                time.sleep(1.2)
                send(client,"cd /tmp; printf 'CWD='; pwd; printf 'TERM=%s\\n' \"$TERM\"; test -t 0 && printf 'TTY=yes\\n'")
                output=read_until(client,b'TTY=yes\r\n'); assert b'CWD=/tmp' in output and b'TERM=xterm-256color' in output
                resize(task,121,41); time.sleep(.08); send(client,"printf 'SIZE='; stty size")
                read_until(client,b'SIZE=41 121\r\n')
                # ANSI alternate screen, cursor movement, Unicode and a shell after Ctrl-C.
                send(client,"printf '\\033[?1049h\\033[2J\\033[H终端\\033[?1049lANSI_OK\\n'")
                output=read_until(client,b'ANSI_OK\r\n'); assert b'\x1b[?1049h' in output and '终端'.encode() in output
                send(client,'sleep 20'); time.sleep(.1); client.sendall(b'\x03'); time.sleep(.1)
                send(client,"printf 'AFTER_INTERRUPT\\n'"); read_until(client,b'AFTER_INTERRUPT\r\n',3)
                # Let output exceed local socket capacity before draining; no byte loss/deadlock.
                send(client,"i=0; while [ $i -lt 12000 ]; do printf '0123456789abcdef\\n'; i=$((i+1)); done; printf 'BULK_DONE\\n'")
                time.sleep(.25); output=read_until(client,b'BULK_DONE\r\n',15); assert output.count(b'0123456789abcdef\r\n')==12000
                send(client,'exit 7'); thread.join(5); assert not thread.is_alive() and result==dict(status=0,exit=7),result
                # Invalid pins fail before shell startup.
                task2,client2,thread2,result2=start('SHA256:'+'A'*43); thread2.join(5)
                assert not thread2.is_alive() and result2['status']==3 and not ready(task2),result2
                # Cancellation remains responsive when the UI stops reading large output.
                task3,client3,thread3,result3=start(); end=time.monotonic()+5
                while not ready(task3) and time.monotonic()<end: time.sleep(.01)
                send(client3,"stty -echo; yes BLOCKED"); time.sleep(.3); cancel(task3); thread3.join(3)
                assert not thread3.is_alive() and result3['status']==6,result3
                print('PASS PTY: persistent shell/cd, setup deadline, tty/TERM, resize, ANSI/Unicode, Ctrl-C, lossless backpressure, EOF/status, pin rejection, blocked-output cancellation')
            finally:
                for task,client,thread in active:
                    if thread.is_alive(): cancel(task); thread.join(5)
                    assert not thread.is_alive()
                    destroy(task); client.close()
                server.terminate(); server.wait(timeout=5)

native_status_invalid = 1
if __name__ == '__main__': main()
