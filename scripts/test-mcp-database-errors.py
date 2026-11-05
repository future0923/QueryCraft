#!/usr/bin/env python3
"""Check packaged drivers with loopback protocol fixtures; no saved accounts or databases are used."""
from pathlib import Path
import argparse
import os
import platform
import socketserver
import struct
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('driver_directory', type=Path)
options = parser.parse_args()
dd = Path(os.environ.get('DERIVED_DATA', ROOT / '.build/DerivedData'))
products = dd / 'Build/Products/Debug'
frameworks = products / 'PackageFrameworks'
binary = ROOT / '.build/test-mcp-database-errors'
args = ['/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc',
        '-parse-as-library', '-target', platform.machine() + '-apple-macosx15.0',
        str(ROOT / 'scripts/test-mcp-database-errors.swift'), '-I', str(products), '-F', str(frameworks),
        '-framework', 'QueryCraftFeature', '-o', str(binary), '-Xlinker', '-rpath', '-Xlinker', str(frameworks)]
for name in ['TreeSitterJSON', 'TreeSitterSQL', 'TreeSitter', 'Internal', 'CQueryCraftSSHPluginAPI']:
    args += ['-Xcc', '-fmodule-map-file=' + str(dd / f'Build/Intermediates.noindex/GeneratedModuleMaps/{name}.modulemap')]
args += ['-Xcc', '-fmodule-map-file=' + str(dd / 'SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap')]
for path in [ROOT / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include',
             ROOT / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include',
             ROOT / 'QueryCraftPackage/Sources/CQueryCraftSSHPluginAPI/include',
             dd / 'SourcePackages/checkouts/tree-sitter/lib/include',
             dd / 'SourcePackages/checkouts/TextStory/Sources/Internal',
             ROOT / 'ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include']:
    args += ['-Xcc', '-I' + str(path)]
subprocess.run(args, check=True)


class Fixture(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        kind = self.server.kind
        if kind in ('mysql', 'doris'):
            payload = b'\xff' + struct.pack('<H', 1049) + b'#42000Unknown database fixture-secret'
            self.request.sendall(len(payload).to_bytes(3, 'little') + b'\x00' + payload)
        elif kind == 'postgresql':
            self.request.recv(4096)
            payload = b'SFATAL\x00C3D000\x00Mdatabase fixture-secret does not exist\x00\x00'
            self.request.sendall(b'E' + struct.pack('!I', len(payload) + 4) + payload)
        elif kind == 'redis':
            while self.request.recv(4096):
                self.request.sendall(b'-NOAUTH fixture-secret\r\n')
        elif kind == 'elasticsearch':
            self.request.recv(4096)
            body = b'{"error":"fixture-secret","status":401}'
            self.request.sendall(b'HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: '
                                  + str(len(body)).encode() + b'\r\n\r\n' + body)


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


for kind, name, expected in [
    ('mysql', 'MySQL', 'DATABASE_NOT_FOUND'), ('doris', 'Doris', 'DATABASE_NOT_FOUND'),
    ('postgresql', 'PostgreSQL', 'DATABASE_ERROR'), ('redis', 'Redis', 'AUTHENTICATION_FAILED'),
    ('elasticsearch', 'Elasticsearch', 'AUTHENTICATION_FAILED'), ('kafka', 'Kafka', 'load_only')
]:
    bundle = options.driver_directory.resolve() / f'{name}-{platform.machine()}.querycraftdriver'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True, capture_output=True)
    with tempfile.TemporaryDirectory(prefix='querycraft-diagnostics-') as directory:
        with Server(('127.0.0.1', 0), Fixture) as server:
            server.kind = kind
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                subprocess.run([str(binary), str(bundle), kind, str(server.server_address[1]), expected, directory], check=True, timeout=20)
            finally:
                server.shutdown()
                worker.join(timeout=5)
