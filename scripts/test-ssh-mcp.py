#!/usr/bin/env python3
"""Test a signed MCP runtime + SSH plugin against an explicitly chosen SSH host.

Password is read through hidden terminal input, never from command arguments.
By default only bounded read-only commands and short sleeps run. --extended also
creates owned UUID file fixtures and bounded tasks, then cleans them up.
Connections, grants and credentials use an isolated temporary data directory.
"""
import argparse
import base64
import hashlib
import shlex
import time
import uuid
import getpass
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mcp', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--host', required=True)
    parser.add_argument('--username', required=True)
    parser.add_argument('--fingerprint', required=True, help='Independently verified fingerprint of the negotiated host key')
    parser.add_argument('--port', type=int, default=22)
    parser.add_argument('--expect-reuse', action='store_true', help='Require optional pool capability and prove same authenticated TCP connection across calls')
    parser.add_argument('--extended', action='store_true', help='Create and remove owned temporary SFTP fixtures and bounded background jobs')
    parser.add_argument('--private-key-path', type=Path, help='Use a fixture private key instead of a password')
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('protocol', ROOT / 'scripts/test-mcp-protocol.py')
    protocol = importlib.util.module_from_spec(spec); spec.loader.exec_module(protocol)
    secret = '' if args.private_key_path else getpass.getpass('SSH password (hidden): ')
    with tempfile.TemporaryDirectory(prefix='querycraft-ssh-mcp-') as temporary:
        root = Path(temporary)
        settings = protocol.policy(5226)
        settings['disabledTools'] = []

        def save():
            path = root / 'mcp-policy.json'
            staging = root / '.policy'
            staging.write_text(json.dumps(settings)); staging.chmod(0o600); staging.replace(path)

        save()
        subprocess.run([str(args.mcp), '--data-dir', str(root), '--install-ssh-plugin', str(args.bundle.resolve())],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        active = (root / 'Plugins/SSH/Current').resolve()
        # A mutated package must never displace a working plugin.
        corrupt = root / 'corrupt/QueryCraftSSH.bundle'
        shutil.copytree(args.bundle, corrupt, symlinks=True)
        binary = corrupt / 'Contents/MacOS/QueryCraftSSH'
        # The signature blob's trailing padding is not sealed executable data.
        # Change a byte inside a signed code page instead.
        value = bytearray(binary.read_bytes()); value[4096] ^= 1; binary.write_bytes(value)
        assert subprocess.run(['codesign', '--verify', '--strict', str(corrupt)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode != 0
        rejected = subprocess.run([str(args.mcp), '--data-dir', str(root), '--install-ssh-plugin', str(corrupt)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert rejected.returncode != 0 and (root / 'Plugins/SSH/Current').resolve() == active
        subprocess.run([str(args.mcp), '--data-dir', str(root), '--check-ssh-plugin'],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        process = subprocess.Popen([str(args.mcp), '--stdio', '--data-dir', str(root)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        sequence = 10
        connection = None
        remote_fixture = '/tmp/querycraft-mcp-fixture-' + uuid.uuid4().hex
        tasks = []

        def call(name, arguments):
            nonlocal sequence
            sequence += 1
            result = protocol.send(process, {'jsonrpc': '2.0', 'id': sequence, 'method': 'tools/call',
                'params': {'name': 'querycraft_' + name, 'arguments': arguments}})
            assert 'result' in result, result
            value = result['result']
            structured = value.get('structuredContent')
            return value, structured if structured is not None else json.loads(value['content'][0]['text'])

        def success(name, arguments):
            raw, value = call(name, arguments)
            assert not raw.get('isError'), value
            return value

        def failure(name, arguments, code):
            raw, value = call(name, arguments)
            assert raw.get('isError') and value['error']['code'] == code, value
            assert value['error']['automatic_retry'] is False
            return value

        try:
            protocol.send(process, protocol.INIT)
            protocol.send(process, {'jsonrpc': '2.0', 'method': 'notifications/initialized'}, False)
            names = {tool['name'] for tool in protocol.send(process, {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})['result']['tools']}
            expected = {'ssh_list_connections', 'ssh_add_connection', 'ssh_remove_connection', 'ssh_test_connection', 'ssh_execute'}
            assert {'querycraft_' + name for name in expected} <= names
            assert any(plugin['id'] == 'ssh' for plugin in success('plugin_list', {}))
            assert {tool['name'] for tool in success('plugin_tools', {'plugin_id': 'ssh'})} >= expected
            created = success('ssh_add_connection', {'name': 'isolated SSH MCP fixture', 'host': args.host,
                'port': args.port, 'username': args.username, 'host_fingerprint': args.fingerprint, **({'private_key_path': str(args.private_key_path.resolve())} if args.private_key_path else {'password': secret})})
            connection = created['connection_id']; assert not created['authorized']
            assert success('ssh_list_connections', {}) == []
            failure('ssh_test_connection', {'connection_id': connection}, 'ACCESS_DENIED')
            settings['ssh'] = {'connectionIDs': [connection], 'executionConnectionIDs': []}; save()
            assert success('ssh_test_connection', {'connection_id': connection})['status'] == 'connected'
            command = {'connection_id': connection, 'command': "printf 'querycraft-mcp-ok\\n'; id -u; uname -s; printf 'stderr-ok\\n' >&2", 'confirm_high_risk': True}
            failure('ssh_execute', command, 'ACCESS_DENIED')
            settings['ssh']['executionConnectionIDs'] = [connection]; save()
            failure('ssh_execute', dict(command, confirm_high_risk=False), 'CONFIRMATION_REQUIRED')
            result = success('ssh_execute', command)
            assert result['exit_code'] == 0 and result['stdout'].startswith('querycraft-mcp-ok\n') and result['stderr'] == 'stderr-ok\n', result
            indirect = success('plugin_call', {'plugin_id': 'ssh', 'connection_id': connection, 'tool': 'ssh_execute',
                                             'arguments': {'command': 'exit 7', 'confirm_high_risk': True}})
            assert indirect['exit_code'] == 7
            if args.expect_reuse:
                probe = dict(command, command='printf "%s" "$SSH_CONNECTION"')
                ports = []; durations = []
                for _ in range(3):
                    started = time.monotonic(); ports.append(success('ssh_execute', probe)['stdout']); durations.append(time.monotonic() - started)
                assert ports[0] and len(set(ports)) == 1, 'Host did not reuse its authenticated connection'
                print('PASS stdio connection reuse; three warm calls average %.1f ms' % (1000 * sum(durations) / len(durations)), flush=True)
            failure('ssh_execute', dict(command, command='sleep 2', timeout_seconds=1), 'OPERATION_TIMEOUT')
            if args.expect_reuse:
                after_timeout = success('ssh_execute', probe)['stdout']
                assert after_timeout != ports[0] and success('ssh_execute', probe)['stdout'] == after_timeout
                print('PASS timed-out connection discarded; next explicit stdio operation reconnects without replay', flush=True)
            if args.extended:
                expected |= {'ssh_create_directory', 'ssh_move_path', 'ssh_remove_path', 'ssh_list_transfers', 'ssh_inspect_transfer', 'ssh_cleanup_transfer', 'ssh_forget_task', 'ssh_list_files', 'ssh_stat_file', 'ssh_read_file', 'ssh_upload_file', 'ssh_download_file',
                             'ssh_start_transfer', 'ssh_transfer_status', 'ssh_cancel_transfer', 'ssh_forget_transfer', 'ssh_start_task', 'ssh_list_tasks', 'ssh_task_status', 'ssh_task_output', 'ssh_cancel_task', 'ssh_remove_task'}
                assert {tool['name'] for tool in success('plugin_tools', {'plugin_id': 'ssh'})} == expected
                selector = {'connection_id': connection}
                def execute(text):
                    value = success('ssh_execute', dict(selector, command=text, confirm_high_risk=True))
                    assert value['exit_code'] == 0, value
                    return value
                execute('mkdir -m 700 ' + remote_fixture)
                remote = remote_fixture + '/binary.dat'
                source = root / 'upload.bin'; content = bytes(range(256)) * 8192; source.write_bytes(content)
                digest = hashlib.sha256(content).hexdigest()
                failure('ssh_stat_file', dict(selector, path=remote_fixture), 'ACCESS_DENIED')
                settings['ssh']['fileReadConnectionIDs'] = [connection]; save()
                assert success('ssh_stat_file', dict(selector, path=remote_fixture))['type'] == 'directory'
                transfer = dict(selector, local_path=str(source), remote_path=remote, confirm_high_risk=True)
                failure('ssh_upload_file', transfer, 'ACCESS_DENIED')
                settings['ssh']['fileTransferConnectionIDs'] = [connection]; save()
                failure('ssh_upload_file', dict(transfer, confirm_high_risk=False), 'CONFIRMATION_REQUIRED')
                oversized = root / 'oversized.jar'
                with oversized.open('wb') as handle: handle.truncate(221054869)
                before_limits = success('ssh_list_transfers', selector)['total_records']
                for tool, extra in [('ssh_upload_file', {}), ('ssh_start_transfer', {'direction': 'upload'})]:
                    error = failure(tool, dict(transfer, local_path=str(oversized), **extra), 'CAPACITY_EXCEEDED')['error']
                    assert error['details']['reason'] == 'transfer_byte_limit', error
                    assert error['details']['size_bytes'] == 221054869 and error['details']['max_transfer_bytes'] == 67108864, error
                    assert error['details']['destination_outcome'] == 'not_started', error
                    assert 'max_transfer_bytes' in error['recovery'] and 'Close unused sessions' not in error['recovery'], error
                assert success('ssh_list_transfers', selector)['total_records'] == before_limits
                small_limit = failure('ssh_upload_file', dict(transfer, max_transfer_bytes=1024), 'CAPACITY_EXCEEDED')['error']
                assert small_limit['details']['size_bytes'] == len(content) and small_limit['details']['max_transfer_bytes'] == 1024
                uploaded = success('ssh_upload_file', dict(transfer, max_transfer_bytes=len(content)))
                assert uploaded['sha256'] == digest and uploaded['bytes_transferred'] == len(content), uploaded
                completed_id = uploaded['transfer_id']
                completed = success('ssh_transfer_status', dict(selector, transfer_id=completed_id))
                assert completed['state'] == 'completed' and completed['result']['sha256'] == digest
                # A separate stdio process can query the same durable result.
                reader = subprocess.Popen([str(args.mcp), '--stdio', '--data-dir', str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    protocol.send(reader, protocol.INIT)
                    protocol.send(reader, {'jsonrpc': '2.0', 'method': 'notifications/initialized'}, False)
                    response = protocol.send(reader, {'jsonrpc': '2.0', 'id': 71, 'method': 'tools/call', 'params': {
                        'name': 'querycraft_ssh_transfer_status', 'arguments': dict(selector, transfer_id=completed_id)}})['result']
                    assert response['structuredContent']['result']['sha256'] == digest
                finally:
                    reader.stdin.close(); reader.wait(timeout=10)
                failure('ssh_upload_file', transfer, 'INVALID_ARGUMENT')
                listing = success('ssh_list_files', dict(selector, path=remote_fixture, max_entries=1))
                assert listing['entries'][0]['name'] == 'binary.dat', listing
                read = success('ssh_read_file', dict(selector, path=remote, offset=7, max_bytes=31, encoding='base64'))
                assert base64.b64decode(read['content']) == content[7:38] and read['next_offset'] == 38, read
                destination = root / 'download.bin'
                download = dict(selector, local_path=str(destination), remote_path=remote, confirm_high_risk=True)
                downloaded = success('ssh_download_file', download)
                assert downloaded['sha256'] == digest and destination.read_bytes() == content
                failure('ssh_download_file', download, 'INVALID_ARGUMENT')
                destination.write_bytes(b'preserve-me')
                download_error = failure('ssh_download_file', dict(download, overwrite=True, max_transfer_bytes=1024), 'CAPACITY_EXCEEDED')['error']
                assert download_error['details']['reason'] == 'transfer_byte_limit' and download_error['details']['max_transfer_bytes'] == 1024
                assert 'max_transfer_bytes' in download_error['recovery'] and 'Close unused sessions' not in download_error['recovery']
                failed_record = next(item for item in success('ssh_list_transfers', selector)['transfers'] if item['local_path'] == str(destination))
                retained = success('ssh_transfer_status', dict(selector, transfer_id=failed_record['transfer_id']))['error']
                assert retained['details'] == download_error['details'] and retained['recovery'] == download_error['recovery']
                assert destination.read_bytes() == b'preserve-me'
                success('ssh_download_file', dict(download, overwrite=True)); assert destination.read_bytes() == content
                # A transfer grant must not acquire arbitrary file deletion rights.
                managed = remote_fixture + '/managed directory'
                failure('ssh_create_directory', dict(selector, path=managed, confirm_high_risk=True), 'ACCESS_DENIED')
                settings['ssh']['fileManagementConnectionIDs'] = [connection]; save()
                failure('ssh_create_directory', dict(selector, path=managed, confirm_high_risk=False), 'CONFIRMATION_REQUIRED')
                success('ssh_create_directory', dict(selector, path=managed, confirm_high_risk=True))
                moved = managed + '/renamed.dat'
                success('ssh_move_path', dict(selector, path=remote, destination_path=moved, confirm_high_risk=True))
                failure('ssh_remove_path', dict(selector, path=managed, kind='empty_directory', confirm_high_risk=True), 'OUTCOME_UNKNOWN')
                success('ssh_move_path', dict(selector, path=moved, destination_path=remote, confirm_high_risk=True))
                success('ssh_remove_path', dict(selector, path=managed, kind='empty_directory', confirm_high_risk=True))
                for invalid in ('/', remote_fixture + '/../other', remote_fixture + '//other'):
                    failure('ssh_remove_path', dict(selector, path=invalid, kind='file', confirm_high_risk=True), 'INVALID_ARGUMENT')
                # Construct a failed upload fixture, then inspect its registered staging path.
                recovery_destination = remote_fixture + '/recover-upload'
                failure('ssh_upload_file', dict(selector, local_path=str(root / 'missing-local-file'), remote_path=recovery_destination, confirm_high_risk=True), 'INVALID_ARGUMENT')
                record = next(item for item in success('ssh_list_transfers', selector)['transfers'] if item['remote_path'] == recovery_destination)
                staging = record['staging_path']
                execute('printf partial > ' + shlex.quote(staging) + '; printf preserve > ' + shlex.quote(recovery_destination))
                recovery = dict(selector, transfer_id=record['transfer_id'])
                inspected = success('ssh_inspect_transfer', recovery)
                assert inspected['metadata']['staging']['exists'] and inspected['metadata']['destination']['exists'], inspected
                cleanup = dict(recovery, inspection_token=inspected['inspection_token'], confirm_high_risk=True, acknowledge_outcome_unknown=True)
                failure('ssh_cleanup_transfer', dict(cleanup, acknowledge_outcome_unknown=False), 'CONFIRMATION_REQUIRED')
                execute('printf changed >> ' + shlex.quote(staging))
                failure('ssh_cleanup_transfer', cleanup, 'INVALID_ARGUMENT')
                fresh = success('ssh_inspect_transfer', recovery); cleanup['inspection_token'] = fresh['inspection_token']
                settings['ssh']['fileManagementConnectionIDs'] = []; save()
                success('ssh_cleanup_transfer', cleanup)
                assert execute('cat ' + shlex.quote(recovery_destination))['stdout'] == 'preserve'
                assert execute('test ! -e ' + shlex.quote(staging))['exit_code'] == 0
                # Failed download recovery is local-only and preserves its destination.
                recovery_local = root / 'recover-local.bin'
                failure('ssh_download_file', dict(selector, local_path=str(recovery_local), remote_path=remote_fixture + '/missing-remote', confirm_high_risk=True), 'INVALID_ARGUMENT')
                record = next(item for item in success('ssh_list_transfers', selector)['transfers'] if item['local_path'] == str(recovery_local))
                local_stage = Path(record['staging_path']); local_stage.write_bytes(b'partial'); recovery_local.write_bytes(b'preserve-local')
                recovery = dict(selector, transfer_id=record['transfer_id'])
                inspected = success('ssh_inspect_transfer', recovery)
                success('ssh_cleanup_transfer', dict(recovery, inspection_token=inspected['inspection_token'], confirm_high_risk=True, acknowledge_outcome_unknown=True))
                assert recovery_local.read_bytes() == b'preserve-local' and not local_stage.exists()
                settings['ssh']['fileManagementConnectionIDs'] = [connection]; save()
                success('ssh_remove_path', dict(selector, path=recovery_destination, kind='file', confirm_high_risk=True))
                transfer_timeout = settings['queryTimeoutSeconds']
                settings['queryTimeoutSeconds'] = 60; save()
                asynchronous_source = root / 'async-source.bin'
                with asynchronous_source.open('wb') as stream:
                    for _ in range(16): stream.write(content)
                asynchronous_remote = remote_fixture + '/async.dat'
                async_args = dict(selector, direction='upload', local_path=str(asynchronous_source), remote_path=asynchronous_remote, confirm_high_risk=True, timeout_seconds=60)
                accepted = success('ssh_start_transfer', async_args)
                assert accepted['state'] == 'accepted'
                observed = []
                for _ in range(400):
                    state = success('ssh_transfer_status', dict(selector, transfer_id=accepted['transfer_id']))
                    observed.append(state)
                    if state['state'] in ('completed', 'failed', 'cancelled', 'unknown'): break
                    time.sleep(.02)
                assert state['state'] == 'completed', state
                assert state['result']['bytes_transferred'] == len(content) * 16
                assert state['result']['sha256'] == hashlib.sha256(content * 16).hexdigest()
                if accepted['progress_available']:
                    actual = [item['bytes_transferred'] for item in observed if item['bytes_transferred'] is not None]
                    assert actual == sorted(actual) and actual[-1] == len(content) * 16
                success('ssh_forget_transfer', dict(selector, transfer_id=accepted['transfer_id'], confirm_high_risk=True))
                shutdown_remote = remote_fixture + '/shutdown.dat'
                shutting_down = success('ssh_start_transfer', dict(async_args, remote_path=shutdown_remote))
                process.stdin.close(); process.wait(timeout=15)
                process = subprocess.Popen([str(args.mcp), '--stdio', '--data-dir', str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                protocol.send(process, protocol.INIT)
                protocol.send(process, {'jsonrpc': '2.0', 'method': 'notifications/initialized'}, False)
                stopped_transfer = success('ssh_transfer_status', dict(selector, transfer_id=shutting_down['transfer_id']))
                assert stopped_transfer['state'] in ('completed', 'cancelled', 'failed'), stopped_transfer
                execute('if test -f ' + shlex.quote(shutdown_remote) + '; then rm -- ' + shlex.quote(shutdown_remote) + '; fi')
                print('PASS stdio owner shutdown leaves a queryable terminal transfer result without automatic resume')
                success('ssh_remove_path', dict(selector, path=asynchronous_remote, kind='file', confirm_high_risk=True))
                settings['queryTimeoutSeconds'] = transfer_timeout; save()
                print('PASS MCP asynchronous transfer/status, actual byte snapshots, retained SHA256 result, cross-process query and local-only forgetting')
                success('ssh_remove_path', dict(selector, path=remote, kind='file', confirm_high_risk=True))
                success('ssh_remove_path', dict(selector, path=remote_fixture, kind='empty_directory', confirm_high_risk=True))
                print('PASS file management/default-deny grant/no recursive delete and token-checked remote/local staging cleanup with destinations preserved')

                def start(text, **limits):
                    task = success('ssh_start_task', dict(selector, command=text, confirm_high_risk=True, **limits))
                    assert task['state'] in ('starting', 'running'), task
                    tasks.append(task['task_id']); return task['task_id']
                def terminal(task):
                    for _ in range(100):
                        value = success('ssh_task_status', dict(selector, task_id=task))
                        if value['state'] in ('completed', 'cancelled', 'timed_out', 'failed'):
                            return value
                        time.sleep(.1)
                    raise AssertionError('Task did not finish')
                task = start("printf 'persistent-output\\n'; printf 'task-error\\n' >&2; sleep 2; exit 7")
                process.stdin.close(); process.wait(timeout=10)
                process = subprocess.Popen([str(args.mcp), '--stdio', '--data-dir', str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                protocol.send(process, protocol.INIT)
                protocol.send(process, {'jsonrpc': '2.0', 'method': 'notifications/initialized'}, False)
                assert task in [item['task_id'] for item in success('ssh_list_tasks', selector)]
                done = terminal(task); assert done['state'] == 'completed' and done['exit_code'] == 7, done
                output = success('ssh_task_output', dict(selector, task_id=task, max_bytes=10, offset=1))
                assert base64.b64decode(output['content_base64']) == b'ersistent-', output
                assert success('ssh_task_output', dict(selector, task_id=task, stream='stderr'))['display_text'] == 'task-error\n'
                settings['disabledTools'] = ['ssh_cancel_task']; save()
                success('ssh_task_status', dict(selector, task_id=task))
                failure('ssh_cancel_task', dict(selector, task_id=task, confirm_high_risk=True), 'ACCESS_DENIED')
                settings['disabledTools'] = []; save()
                active = start('sleep 60')
                failure('ssh_remove_task', dict(selector, task_id=active, confirm_high_risk=True), 'DRIVER_FAILURE')
                failure('ssh_cancel_task', dict(selector, task_id=active, confirm_high_risk=False), 'CONFIRMATION_REQUIRED')
                success('ssh_cancel_task', dict(selector, task_id=active, confirm_high_risk=True))
                assert terminal(active)['state'] == 'cancelled'
                deadline = start('sleep 60', task_timeout_seconds=1)
                assert terminal(deadline)['state'] == 'timed_out'
                capped = start('head -c 2560000 /dev/zero', max_log_bytes=1024)
                done = terminal(capped)
                assert done['truncated'] and done['stdout_bytes'] == 2560000 and done['stdout_retained_bytes'] == 1024, done
                saved_task_record = json.loads((root / 'ssh-tasks.json').read_text())[0]
                for task in list(tasks):
                    success('ssh_remove_task', dict(selector, task_id=task, confirm_high_risk=True)); tasks.remove(task)
                orphan = str(uuid.uuid4()).upper()
                registry = root / 'ssh-tasks.json'
                records = json.loads(registry.read_text())
                # Obtain the same account binding from a finished task record before cleanup via stored copy.
                orphan_record = dict(saved_task_record, id=orphan)
                records.append(orphan_record); registry.write_text(json.dumps(records))
                failure('ssh_forget_task', dict(selector, task_id=orphan, confirm_high_risk=True), 'CONFIRMATION_REQUIRED')
                forgotten = success('ssh_forget_task', dict(selector, task_id=orphan, confirm_high_risk=True, acknowledge_task_may_be_running=True))
                assert forgotten['local_record_removed'] and not forgotten['remote_task_stopped'] and not forgotten['remote_files_removed']
                assert success('ssh_list_tasks', selector) == []
                print('PASS real SFTP roundtrip/hash/read/permissions/overwrite/limits and remote tasks/reconnect/exit/log cap/cancel/deadline/cleanup')
            profile_path = root / 'ssh-connections.json'
            profiles = json.loads(profile_path.read_text())
            profiles[0]['hostFingerprint'] = 'SHA256:' + 'A' * 43
            profile_path.write_text(json.dumps(profiles))
            failure('ssh_test_connection', {'connection_id': connection}, 'ACCESS_DENIED')
            profiles[0]['hostFingerprint'] = args.fingerprint; profile_path.write_text(json.dumps(profiles))
            for path in root.rglob('*.json'):
                assert not secret or secret not in path.read_text(), 'Credential leaked to a JSON file'
            success('ssh_remove_connection', {'connection_id': connection, 'confirm_high_risk': True})
            connection = None
            assert success('ssh_list_connections', {}) == []
            print(json.dumps({'host': args.host, 'passed': ['signed installation', 'mutated package rejection with old version retained',
                'MCP handshake/tool schemas/plugin routes', ('key authentication' if args.private_key_path else 'Keychain credential save/read/delete'), 'independent SSH grants',
                ('private-key authentication' if args.private_key_path else 'password authentication'), 'per-account execution grant', 'exact-command confirmation gate',
                'remote stdout/stderr/exit status', 'indirect execution/exit 7', 'timeout/unknown outcome',
                'host fingerprint mismatch', 'no secrets in JSON', 'connection cleanup']}, indent=2))
        finally:
            if connection and process.poll() is None:
                try:
                    settings['ssh'] = {'connectionIDs': [connection], 'executionConnectionIDs': [connection]}; save()
                    for task in tasks:
                        try:
                            success('ssh_cancel_task', {'connection_id': connection, 'task_id': task, 'confirm_high_risk': True})
                            time.sleep(.3)
                            success('ssh_remove_task', {'connection_id': connection, 'task_id': task, 'confirm_high_risk': True})
                        except Exception: pass
                    if args.extended:
                        owned = [remote_fixture + '/binary.dat', remote_fixture + '/async.dat', remote_fixture + '/shutdown.dat', remote_fixture + '/recover-upload', remote_fixture + '/managed directory/renamed.dat']
                        registry = root / 'ssh-transfers.json'
                        if registry.exists():
                            owned += [item['stagingPath'] for item in json.loads(registry.read_text()) if item['upload'] and item['stagingPath'].startswith(remote_fixture + '/')]
                        cleanup = 'for owned in ' + ' '.join(shlex.quote(path) for path in owned) + '; do test ! -e "$owned" || rm -- "$owned"; done; rmdir -- ' + shlex.quote(remote_fixture + '/managed directory') + ' 2>/dev/null; rmdir -- ' + shlex.quote(remote_fixture) + ' 2>/dev/null; true'
                        success('ssh_execute', {'connection_id': connection, 'command': cleanup, 'confirm_high_risk': True})
                    settings['ssh'] = {'connectionIDs': [connection], 'executionConnectionIDs': []}; save()
                    success('ssh_remove_connection', {'connection_id': connection, 'confirm_high_risk': True})
                except Exception:
                    print('Fixture connection cleanup failed; inspect the isolated test Keychain vault before deleting it.')
            secret = ''
            if process.poll() is None:
                process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.terminate(); process.wait(timeout=5)


if __name__ == '__main__':
    main()
