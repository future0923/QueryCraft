#!/usr/bin/env python3
"""Exercise long query waiting and cancellation against a loopback MySQL wire fixture.

Build QueryCraftMySQLDriver first. Never contacts saved or production connections.
"""
from pathlib import Path
import os
import argparse
import platform
import socket
import struct
import threading
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle', type=Path, help='Exercise this installed driver instead of the direct transport')
options = parser.parse_args()

root = Path(__file__).resolve().parent.parent
dd = Path(os.environ.get('DERIVED_DATA', root / '.build/DerivedData'))

args=[ '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc', '-parse-as-library', '-target',platform.machine()+'-apple-macosx15.0', '-sdk',subprocess.check_output(['/usr/bin/xcode-select','-p'],text=True).strip()+'/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk', '-package-name','querycraftdrivers',str(root/'scripts/test-sql-waiting.swift'),'-I',str(dd/'Build/Products/Debug'),'-F',str(dd/'Build/Products/Debug/PackageFrameworks'),'-framework','QueryCraftFeature','-framework','QueryCraftMariaDBTransportV4','-o',str(root/'.build/test-sql-waiting'),'-Xlinker','-rpath','-Xlinker',str(dd/'Build/Products/Debug/PackageFrameworks')]
for name in ['CQueryCraftSSHPluginAPI','TreeSitterJSON','TreeSitterSQL','TreeSitter','Internal','CNIODarwin','CNIOLinux','CNIOOpenBSD','CNIOPosix','CNIOAtomics','CNIOLLHTTP','CNIOSHA1','CNIOWindows','CNIOWASI','_AtomicsShims']:
 modulemap=dd/f'Build/Intermediates.noindex/GeneratedModuleMaps/{name}.modulemap'
 if modulemap.exists():args+=['-Xcc','-fmodule-map-file='+str(modulemap)]
for p in [dd/'SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap',root/'QueryCraftDrivers/Sources/CLibPQ/module.modulemap',root/'QueryCraftDrivers/MariaDBTransport/Sources/CMariaDB/module.modulemap']:
 args+=['-Xcc','-fmodule-map-file='+str(p)]
for p in list((dd/'SourcePackages/checkouts/swift-nio/Sources').glob('*/include/module.modulemap')) + [dd/'SourcePackages/checkouts/swift-atomics/Sources/_AtomicsShims/include/module.modulemap']:
 if p.exists():args+=['-Xcc','-fmodule-map-file='+str(p)]
for p in [root/'ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include',root/'ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include',dd/'SourcePackages/checkouts/tree-sitter/lib/include',dd/'SourcePackages/checkouts/TextStory/Sources/Internal',root/'ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include']:
 args+=['-Xcc','-I'+str(p)]
if options.bundle:
    framework = args.index('QueryCraftMariaDBTransportV4')
    del args[framework - 1:framework + 1]
    args += ['-D', 'PACKAGED_DRIVER']
subprocess.run(args,check=True)

import concurrent.futures
import time


def read(connection, count):
    data = b''
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        if not chunk:
            raise EOFError()
        data += chunk
    return data


def receive(connection):
    header = read(connection, 4)
    return read(connection, int.from_bytes(header[:3], 'little'))


def send(connection, payload, sequence):
    connection.sendall(len(payload).to_bytes(3, 'little') + bytes([sequence]) + payload)


cancelled = threading.Event()
errors = []


def serve(connection):
    try:
        with connection:
            connection.settimeout(40)
            caps = 512 | 32768 | 524288 | 8192
            handshake = (b'\x0a5.7.44\0' + struct.pack('<I', 42) + b'12345678\0'
                + struct.pack('<H', caps & 65535) + b'\x2d' + struct.pack('<H', 2)
                + struct.pack('<H', caps >> 16) + b'\x15' + b'\0' * 10
                + b'abcdefghijkl\0mysql_native_password\0')
            send(connection, handshake, 0)
            receive(connection)
            ok = b'\0\0\0' + struct.pack('<HH', 2, 0)
            send(connection, ok, 2)
            while True:
                packet = receive(connection)
                if packet[0] == 1:
                    return
                if packet[0] != 3:
                    send(connection, ok, 1)
                    continue
                sql = packet[1:].decode()
                if sql in ('SELECT SLEEP(12)', 'SELECT SLEEP(12) /* stream */'):
                    time.sleep(12)
                if sql.startswith('KILL QUERY'):
                    cancelled.set()
                if sql == 'SELECT SLEEP(60)':
                    assert cancelled.wait(10), 'Manual cancellation did not issue KILL QUERY'
                    send(connection, b'\xff' + struct.pack('<H', 1317) + b'#70100Query interrupted', 1)
                else:
                    send(connection, ok, 1)
    except BaseException as error:
        errors.append(error)


with socket.socket() as listener, concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    listener.settimeout(40)
    def accept():
        for _ in range(2):
            connection, _ = listener.accept()
            executor.submit(serve, connection)
    accept_thread = threading.Thread(target=accept)
    accept_thread.start()
    command = [str(root / '.build/test-sql-waiting'), str(listener.getsockname()[1])]
    if options.bundle:
        command.append(str(options.bundle.resolve()))
    result = subprocess.run(command,
        capture_output=True, text=True, timeout=45)
    accept_thread.join(timeout=1)
    print(result.stdout, end='')
    if result.returncode:
        raise SystemExit(result.stderr or 'Native SQL waiting check failed')
    assert not errors, errors
