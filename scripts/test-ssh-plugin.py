#!/usr/bin/env python3
"""Exercise the plugin ABI against an isolated loopback OpenSSH server on macOS."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import ctypes as c
import getpass
import hashlib
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


class Request(c.Structure):
    _fields_ = [('size', c.c_uint32), ('host', c.c_char_p), ('port', c.c_uint16),
                ('username', c.c_char_p), ('host_fingerprint', c.c_char_p),
                ('private_key_path', c.c_char_p), ('secret', c.c_char_p), ('command', c.c_char_p),
                ('timeout_ms', c.c_uint32), ('maximum_output_bytes', c.c_uint32)]


class Result(c.Structure):
    _fields_ = [('size', c.c_uint32), ('status', c.c_int32), ('exit_status', c.c_int32),
                ('command_may_have_run', c.c_uint8), ('truncated', c.c_uint8),
                ('stdout_data', c.c_void_p), ('stdout_length', c.c_size_t),
                ('stderr_data', c.c_void_p), ('stderr_length', c.c_size_t), ('output_bytes', c.c_uint64)]


class FileRequest(c.Structure):
    _fields_ = [('size', c.c_uint32), ('connection', Request), ('operation', c.c_uint32),
                ('remote_path', c.c_char_p), ('local_path', c.c_char_p), ('temporary_path', c.c_char_p),
                ('offset', c.c_uint64), ('maximum_transfer_bytes', c.c_uint64),
                ('maximum_entries', c.c_uint32), ('overwrite', c.c_uint32)]


class Progress(c.Structure):
    _fields_ = [('size', c.c_uint32), ('phase', c.c_uint32), ('transferred', c.c_uint64), ('total', c.c_uint64), ('total_known', c.c_uint32)]
ProgressCallback = c.CFUNCTYPE(None, c.c_void_p, c.POINTER(Progress))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    args = parser.parse_args()
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.bundle)], check=True)
    lib = c.CDLL(str(args.bundle / 'Contents/MacOS/QueryCraftSSH'))
    version = lib.querycraft_ssh_plugin_version; version.restype = c.c_uint32
    assert version() == 1
    create = lib.querycraft_ssh_plugin_create; create.argtypes = [c.POINTER(Request)]; create.restype = c.c_void_p
    run = lib.querycraft_ssh_plugin_run; run.argtypes = [c.c_void_p]; run.restype = c.POINTER(Result)
    cancel = lib.querycraft_ssh_plugin_cancel; cancel.argtypes = [c.c_void_p]
    destroy = lib.querycraft_ssh_plugin_destroy; destroy.argtypes = [c.c_void_p]
    file_create = lib.querycraft_ssh_plugin_file_create; file_create.argtypes = [c.POINTER(FileRequest)]; file_create.restype = c.c_void_p
    pool_create = lib.querycraft_ssh_plugin_pool_create; pool_create.argtypes = [c.c_uint32, c.c_uint32, c.c_uint32]; pool_create.restype = c.c_void_p
    pool_run = lib.querycraft_ssh_plugin_pool_run; pool_run.argtypes = [c.c_void_p, c.c_void_p, c.c_char_p]; pool_run.restype = c.POINTER(Result)
    pool_invalidate = lib.querycraft_ssh_plugin_pool_invalidate; pool_invalidate.argtypes = [c.c_void_p, c.c_char_p]
    pool_prune = lib.querycraft_ssh_plugin_pool_prune; pool_prune.argtypes = [c.c_void_p]
    pool_destroy = lib.querycraft_ssh_plugin_pool_destroy; pool_destroy.argtypes = [c.c_void_p]
    assert lib.querycraft_ssh_plugin_progress_version() == 1
    set_progress = lib.querycraft_ssh_plugin_set_progress; set_progress.argtypes = [c.c_void_p, ProgressCallback, c.c_void_p]
    with tempfile.TemporaryDirectory(prefix='querycraft-ssh-test-') as temporary:
        root = Path(temporary)
        for name, password in [('host', ''), ('client', ''), ('encrypted', 'fixture-passphrase')]:
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', password, '-f', str(root / name)], check=True)
        (root / 'authorized_keys').write_bytes((root / 'client.pub').read_bytes() + (root / 'encrypted.pub').read_bytes())
        fingerprint = subprocess.check_output(['ssh-keygen', '-lf', str(root / 'host.pub'), '-E', 'sha256'], text=True).split()[1]
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0)); port = listener.getsockname()[1]
        config = root / 'sshd_config'
        config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {root}/host
PidFile {root}/sshd.pid
AuthorizedKeysFile {root}/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
AllowUsers {getpass.getuser()}
LogLevel ERROR
Subsystem sftp internal-sftp
''')
        with (root / 'server.log').open('w') as output:
            server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)], stdout=output, stderr=output)
            try:
                for _ in range(100):
                    if server.poll() is not None:
                        raise RuntimeError((root / 'server.log').read_text())
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            break
                    except OSError:
                        time.sleep(.05)
                else:
                    raise RuntimeError('SSH fixture did not start')

                def request(command=None, key='client', secret=None, pin=fingerprint, timeout=5000, cap=16384, host='127.0.0.1'):
                    value = Request(c.sizeof(Request), host.encode(), port, getpass.getuser().encode(), pin.encode(),
                                    str(root / key).encode() if key else None, secret.encode() if secret else None,
                                    command.encode() if command is not None else None, timeout, cap)
                    return value

                def execute(value, files=False, pool=None, scope="account-a", progress=None, cancel_after_bytes=False):
                    task = (file_create if files else create)(c.byref(value)); assert task
                    def report(context, pointer):
                        item = pointer.contents
                        progress.append((item.phase, item.transferred, item.total, bool(item.total_known), item.size))
                        if cancel_after_bytes and item.transferred: cancel(task)
                    callback = ProgressCallback(report)
                    if progress is not None: set_progress(task, callback, None)
                    try:
                        raw = (pool_run(pool, task, scope.encode()) if pool else run(task)).contents
                        assert raw.size == c.sizeof(Result)
                        return {'status': raw.status, 'exit': raw.exit_status, 'may_run': bool(raw.command_may_have_run),
                                'truncated': bool(raw.truncated), 'stdout': c.string_at(raw.stdout_data, raw.stdout_length),
                                'stderr': c.string_at(raw.stderr_data, raw.stderr_length), 'bytes': raw.output_bytes}
                    finally:
                        destroy(task)

                def file(operation, remote, local=None, offset=0, cap=16384, maximum=67108864, entries=100, overwrite=False, temporary=None, pool=None, progress=None, cancel_after_bytes=False):
                    remote = str(remote)
                    value = FileRequest(c.sizeof(FileRequest), request(cap=cap), operation, remote.encode(),
                        str(local).encode() if local else None, str(temporary).encode() if temporary else ((remote + '.querycraft-staging').encode() if operation == 4 else None),
                        offset, maximum, entries, overwrite)
                    return execute(value, files=True, pool=pool, progress=progress, cancel_after_bytes=cancel_after_bytes)

                assert not pool_create(0, 60000, 300000) and not pool_create(9, 60000, 300000)
                pool = pool_create(2, 60000, 300000); assert pool
                identity = 'printf "%s" "$SSH_CONNECTION"'
                try:
                    one = execute(request(identity), pool=pool)
                    two = execute(request(identity), pool=pool)
                    assert one['status'] == two['status'] == 0 and one['stdout'] == two['stdout'], (one, two)
                    other = execute(request(identity), pool=pool, scope='account-b')
                    assert other['stdout'] != two['stdout'], other
                    # A different key/passphrase cannot borrow the authenticated session.
                    encrypted = execute(request(identity, key='encrypted', secret='fixture-passphrase'), pool=pool)
                    assert encrypted['status'] == 0 and encrypted['stdout'] != one['stdout']
                    assert execute(request(identity, key='encrypted', secret='incorrect'), pool=pool)['status'] == 4
                    restored = execute(request(identity), pool=pool)
                    assert restored['status'] == 0 and restored['stdout'] != one['stdout']
                    assert execute(request(identity, pin='SHA256:' + 'A' * 43), pool=pool)['status'] == 3
                    repaired = execute(request(identity), pool=pool)
                    assert repaired['status'] == 0 and repaired['stdout'] != restored['stdout']
                    rotating = root / 'rotating'
                    rotating.write_bytes((root / 'client').read_bytes())
                    key_before = execute(request(identity, key='rotating', secret='fixture-passphrase'), pool=pool)
                    rotating.write_bytes((root / 'encrypted').read_bytes())
                    key_after = execute(request(identity, key='rotating', secret='fixture-passphrase'), pool=pool)
                    assert key_before['status'] == key_after['status'] == 0 and key_before['stdout'] != key_after['stdout']
                    pool_invalidate(pool, b'account-a')
                    fresh = execute(request(identity), pool=pool)
                    assert fresh['stdout'] != repaired['stdout']
                    # A submitted command is never replayed, including a channel failure.
                    marker = root / 'pool-no-replay'
                    failed = execute(request('printf x >> ' + str(marker) + '; kill -KILL $$'), pool=pool)
                    assert failed['status'] != 0 and failed['may_run'] and marker.read_bytes() == b'x', failed
                    next_call = execute(request(identity), pool=pool)
                    assert next_call['status'] == 0 and next_call['stdout'] != fresh['stdout']
                    # Timeout and cancellation poison only their leased session.
                    assert execute(request('sleep 2', timeout=100), pool=pool)['status'] == 5
                    after_timeout = execute(request(identity), pool=pool)
                    assert after_timeout['status'] == 0 and after_timeout['stdout'] != next_call['stdout']
                    task = create(c.byref(request('sleep 10'))); assert task
                    with ThreadPoolExecutor(max_workers=1) as workers:
                        running = workers.submit(pool_run, pool, task, b'account-a')
                        time.sleep(.15); cancel(task)
                        assert running.result(timeout=5).contents.status == 6
                    destroy(task)
                    after_cancel = execute(request(identity), pool=pool)
                    assert after_cancel['status'] == 0 and after_cancel['stdout'] != after_timeout['stdout']
                    # Kill the server-side authenticated connection; next explicit call recovers.
                    died = execute(request('kill -KILL "$PPID"'), pool=pool)
                    assert died['status'] != 0 and died['may_run'], died
                    time.sleep(.1)
                    recovered = execute(request(identity), pool=pool)
                    assert recovered['status'] == 0 and recovered['stdout'] != after_cancel['stdout'], recovered
                    pool_prune(pool)
                    concurrent = [request('sleep .2; ' + identity), request('sleep .2; ' + identity)]
                    with ThreadPoolExecutor(max_workers=2) as workers:
                        results = list(workers.map(lambda v: execute(v, pool=pool), concurrent))
                    assert all(v['status'] == 0 for v in results) and results[0]['stdout'] != results[1]['stdout'], results
                    pool_invalidate(pool, None)
                finally:
                    pool_destroy(pool)
                bounded = pool_create(1, 60000, 300000); assert bounded
                try:
                    ready = root / 'lease-ready'
                    with ThreadPoolExecutor(max_workers=1) as workers:
                        active = workers.submit(execute, request('touch ' + str(ready) + '; sleep 1; ' + identity), pool=bounded)
                        deadline = time.monotonic() + 3
                        while not ready.exists() and time.monotonic() < deadline: time.sleep(.01)
                        assert ready.exists()
                        assert execute(request(identity), pool=bounded, scope='account-b')['status'] == 9
                        pool_invalidate(bounded, None)
                        old = active.result(timeout=5)
                    new = execute(request(identity), pool=bounded)
                    assert old['status'] == new['status'] == 0 and old['stdout'] != new['stdout']
                finally: pool_destroy(bounded)
                print('PASS bounded capacity and invalidation during a busy lease prevents return to idle pool')
                for idle, lifetime in [(150, 300000), (60000, 150)]:
                    pool = pool_create(1, idle, lifetime); assert pool
                    try:
                        before = execute(request(identity), pool=pool)
                        time.sleep(.2); pool_prune(pool)
                        after = execute(request(identity), pool=pool)
                        assert before['status'] == after['status'] == 0 and before['stdout'] != after['stdout']
                    finally: pool_destroy(pool)
                print('PASS pool reuse/account-auth-pin isolation/invalidate/no replay/dead peer/concurrent exclusive leases/cancel/timeout/idle and max-age expiry')
                directory = root / 'sftp'; directory.mkdir()
                payload = bytes(range(256)) * 8192
                source = root / 'source.bin'; source.write_bytes(payload)
                remote = directory / "space ' 引号.bin"
                upload_progress = []
                uploaded = file(4, remote, source, progress=upload_progress)
                assert uploaded['status'] == 0 and uploaded['bytes'] == len(payload), uploaded
                assert uploaded['stdout'].decode() == hashlib.sha256(payload).hexdigest() and remote.read_bytes() == payload
                assert file(4, remote, source)['status'] == 12
                stat = file(1, remote); assert stat['status'] == 0 and int(stat['stderr'].split(b'\t')[1]) == len(payload), stat
                window = file(3, remote, offset=7, cap=31)
                assert window['status'] == 0 and window['stdout'] == payload[7:38] and window['truncated'], window
                listed = file(2, directory)
                names = [base64.b64decode(row.split(b'\t')[0]).decode() for row in listed['stdout'].splitlines()]
                assert remote.name in names
                (directory / 'second\nline').write_text('fixture')
                page = file(2, directory, entries=1); assert page['status'] == 0 and page['truncated']
                assert file(2, directory, offset=1, entries=1)['status'] == 0
                destination = root / 'downloaded.bin'
                download_progress = []
                downloaded = file(5, remote, destination, progress=download_progress)
                assert downloaded['status'] == 0 and downloaded['bytes'] == len(payload) and destination.read_bytes() == payload, downloaded
                assert downloaded['stdout'] == uploaded['stdout']
                for events in [upload_progress, download_progress]:
                    assert {e[0] for e in events} == {1, 2, 3}, events[-3:]
                    assert [e[1] for e in events] == sorted(e[1] for e in events)
                    assert all(e[2:] == (len(payload), True, c.sizeof(Progress)) for e in events)
                    assert any(0 < e[1] < len(payload) for e in events)
                    assert events[-1][:2] == (3, len(payload))
                cancelled_progress = []
                cancelled_target = directory / 'cancelled-upload'
                cancelled = file(4, cancelled_target, source, progress=cancelled_progress, cancel_after_bytes=True)
                assert cancelled['status'] == 6 and not cancelled_target.exists()
                assert not any(e[0] == 3 for e in cancelled_progress)
                empty_source = root / 'empty'; empty_source.write_bytes(b'')
                empty_target = directory / 'empty'; empty_progress = []
                assert file(4, empty_target, empty_source, progress=empty_progress)['status'] == 0
                assert all(e[1] == e[2] == 0 and e[3] for e in empty_progress)
                empty_target.unlink()
                print('PASS optional progress ABI actual monotonic bytes/known totals/verification/publication/empty file/cancel before publication')
                assert file(5, remote, destination)['status'] == 12 and destination.read_bytes() == payload
                source.write_bytes(b'replacement'); assert file(4, remote, source, overwrite=True)['status'] == 0
                assert remote.read_bytes() == b'replacement'
                assert file(5, remote, destination, overwrite=True)['status'] == 0 and destination.read_bytes() == b'replacement'
                source.write_bytes(payload)
                assert file(4, directory / 'over-limit', source, maximum=100)['status'] == 14
                assert not (directory / 'over-limit').exists()
                assert file(5, remote, root / 'over-limit-local', maximum=3)['status'] == 14
                assert not (root / 'over-limit-local').exists()
                assert file(1, directory / 'missing')['status'] == 10
                os.mkfifo(root / 'local-fifo')
                assert file(4, directory / 'fifo', root / 'local-fifo')['status'] == 16
                (root / 'local-symlink').symlink_to(source)
                assert file(4, directory / 'symlink', root / 'local-symlink')['status'] == 16
                assert file(5, remote, root / 'local-symlink', overwrite=True)['status'] == 16
                assert source.read_bytes() == payload
                (directory / 'remote-symlink').symlink_to(remote)
                assert file(4, directory / 'remote-symlink', source, overwrite=True)['status'] == 1
                assert remote.read_bytes() == b'replacement'
                print('PASS SFTP stat/list/byte windows, streamed binary SHA256 roundtrip, explicit overwrite, atomic target preservation, limits, missing paths and FIFO/symlink rejection')
                reuse = pool_create(2, 60000, 300000); assert reuse
                try:
                    before = execute(request(identity), pool=reuse)
                    assert file(1, remote, pool=reuse)['status'] == 0
                    assert file(2, directory, pool=reuse)['status'] == 0
                    assert file(3, remote, cap=3, pool=reuse)['stdout'] == b'rep'
                    after = execute(request(identity), pool=reuse)
                    assert before['stdout'] == after['stdout'], (before, after)
                    assert file(1, directory / 'missing', pool=reuse)['status'] == 10
                    assert execute(request(identity), pool=reuse)['stdout'] != before['stdout']
                finally: pool_destroy(reuse)
                print('PASS command/SFTP session reuse with clean subsystem shutdown; file errors discard session')

                newdir = directory / 'create space 雪'
                assert file(6, newdir)['status'] == 0 and newdir.is_dir()
                assert newdir.stat().st_mode & 0o777 == 0o700
                assert file(6, newdir)['status'] != 0
                moved = newdir / 'renamed.bin'
                assert file(7, remote, temporary=moved)['status'] == 0 and moved.read_bytes() == b'replacement'
                existing = newdir / 'existing'; existing.write_bytes(b'preserve')
                assert file(7, moved, temporary=existing)['status'] == 12
                assert existing.read_bytes() == b'preserve' and moved.exists()
                assert file(9, newdir)['status'] != 0 and newdir.exists()
                assert file(8, newdir)['status'] != 0
                link = newdir / 'link'; link.symlink_to(moved)
                assert file(8, link)['status'] == 0 and moved.exists() and not link.exists()
                local_stage = root / '.download-stage'
                downloaded = root / 'download-exact-stage'
                assert file(5, moved, downloaded, temporary=local_stage)['status'] == 0
                assert downloaded.read_bytes() == b'replacement' and not local_stage.exists()
                local_stage.write_bytes(b'not-owned-by-this-operation')
                downloaded.unlink()
                assert file(5, moved, downloaded, temporary=local_stage)['status'] != 0
                assert local_stage.read_bytes() == b'not-owned-by-this-operation' and not downloaded.exists()
                assert file(8, moved)['status'] == 0 and file(8, existing)['status'] == 0
                assert file(9, newdir)['status'] == 0 and not newdir.exists()
                assert file(6, '/')['status'] != 0
                print('PASS management mkdir0700/move/no-overwrite/unlink/empty-only-rmdir/symlink target preservation and exclusive exact download staging')

                assert execute(request())['status'] == 0
                mixed = execute(request("printf 'out'; printf 'err' >&2; exit 7"))
                assert mixed == {'status': 0, 'exit': 7, 'may_run': True, 'truncated': False, 'stdout': b'out', 'stderr': b'err', 'bytes': 6}, mixed
                assert execute(request('cat'))['exit'] == 0  # stdin EOF, no interactive hang
                assert execute(request("printf encrypted", key='encrypted', secret='fixture-passphrase'))['stdout'] == b'encrypted'
                assert execute(request(key='encrypted', secret='wrong'))['status'] == 4
                assert execute(request(key=None, secret='fixture-password'))['status'] == 4
                os.mkfifo(root / 'fifo')
                before = time.monotonic()
                assert execute(request(key='fifo'))['status'] == 4
                assert time.monotonic() - before < 2
                wrong = 'SHA256:' + 'A' * 43
                mismatch = execute(request('printf forbidden', pin=wrong))
                assert mismatch['status'] == 3 and not mismatch['may_run'], mismatch
                large = execute(request('head -c 2097152 /dev/zero; head -c 2097152 /dev/zero >&2', cap=31))
                assert large['status'] == 0 and large['truncated'] and large['bytes'] == 4194304, large
                assert len(large['stdout']) + len(large['stderr']) == 31
                before = time.monotonic()
                timeout = execute(request('sleep 5; printf late', timeout=300))
                assert timeout['status'] == 5 and timeout['may_run'], timeout
                assert time.monotonic() - before < 2
                with ThreadPoolExecutor(max_workers=4) as pool:
                    task = create(c.byref(request('sleep 5', timeout=10000)))
                    assert task
                    try:
                        future = pool.submit(run, task)
                        time.sleep(.2); before = time.monotonic(); cancel(task)
                        result = future.result(timeout=2).contents
                        assert result.status == 6 and time.monotonic() - before < 1
                    finally:
                        destroy(task)
                    # Four resolver workers are the intentional global limit.
                    results = list(pool.map(lambda i: execute(request(f'printf concurrent-{i}')), range(12)))
                    assert all(value['status'] == 0 and value['stdout'] == f'concurrent-{i}'.encode() for i, value in enumerate(results)), results
                print(json.dumps({'passed': ['ABI/signature', 'pinned host key', 'key authentication', 'encrypted key authentication',
                    'wrong passphrase', 'password rejection', 'non-regular private-key rejection', 'host-key mismatch before command', 'stdout/stderr/exit status',
                    'stdin EOF', '4 MiB output drainage with 31-byte cap', 'timeout/unknown outcome', 'prompt cancellation',
                    '12 concurrent isolated commands']}, indent=2))
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill(); server.wait()


if __name__ == '__main__':
    main()
