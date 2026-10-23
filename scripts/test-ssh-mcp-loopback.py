#!/usr/bin/env python3
"""Run full stdio/SFTP/background-task acceptance against disposable loopback sshd."""
import argparse
import getpass
from pathlib import Path
import socket
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--mcp', type=Path, required=True)
parser.add_argument('--bundle', type=Path, required=True)
parser.add_argument('--expect-reuse', action='store_true')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='qc-ssh-mcp-loopback-') as temp:
    root = Path(temp)
    for name in ('host', 'client'):
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root / name)], check=True)
    fingerprint = subprocess.check_output(['ssh-keygen', '-lf', str(root / 'host.pub'), '-E', 'sha256'], text=True).split()[1]
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0)); port = listener.getsockname()[1]
    config = root / 'sshd_config'
    config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {root}/host
PidFile {root}/sshd.pid
AuthorizedKeysFile {root}/client.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
AllowUsers {getpass.getuser()}
LogLevel ERROR
Subsystem sftp internal-sftp
SetEnv PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
''')
    with (root / 'sshd.log').open('w') as log:
        server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)], stdout=log, stderr=log)
        try:
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError((root / 'sshd.log').read_text())
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1): break
                except OSError: time.sleep(.05)
            else: raise RuntimeError('SSH fixture did not start')
            subprocess.run(['python3', str(Path(__file__).with_name('test-ssh-mcp.py')), '--mcp', str(args.mcp.resolve()),
                '--bundle', str(args.bundle.resolve()), '--host', '127.0.0.1', '--port', str(port), '--username', getpass.getuser(),
                '--fingerprint', fingerprint, '--private-key-path', str(root / 'client'), '--extended'] + (['--expect-reuse'] if args.expect_reuse else []), check=True)
        finally:
            server.terminate()
            try: server.wait(timeout=5)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
