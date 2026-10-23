#!/usr/bin/env python3
"""Exercise the packaged shell supervisor with isolated HOME and real subprocesses."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

SOURCE = Path(__file__).resolve().parents[1] / 'QueryCraftPackage/Sources/QueryCraftFeature/Resources/SSH/ssh_task.sh'
source = SOURCE.read_text()
with tempfile.TemporaryDirectory(prefix='qc-task-supervisor-') as home:
    poison = Path(home) / 'bin'; poison.mkdir()
    for executable in ('python', 'python3'):
        stub = poison / executable
        stub.write_text('#!/bin/sh\n: > "$HOME/python-was-called"\nexit 99\n'); stub.chmod(0o700)
    env = dict(os.environ, HOME=home, PATH=str(poison) + ':/usr/bin:/bin:/usr/sbin:/sbin')
    def call(action, task, **payload):
        enc = lambda value: base64.b64encode(value.encode()).decode()
        fields = [action, task, enc(source) if action == 'start' else '', enc(payload.get('command', '')),
                  enc(payload.get('working_directory', '')), str(payload.get('task_timeout_seconds', 20)),
                  str(payload.get('max_log_bytes', 4096)), payload.get('stream', 'stdout'),
                  str(payload.get('offset', 0)), str(payload.get('max_bytes', 16384))]
        result = subprocess.run(['/bin/bash', '-c', source, '--', *fields], env=env, capture_output=True, timeout=10)
        return result.returncode, json.loads(result.stdout)
    def wait(task):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            code, value = call('status', task)
            assert code == 0, value
            if value['state'] in ('completed', 'cancelled', 'timed_out', 'failed'):
                return value
            time.sleep(.1)
        raise AssertionError('task never finished')
    live = str(uuid.uuid4()).upper()
    assert call('start', live, command="printf 'live\\n'; printf 'liveerr\\n' >&2; sleep 60")[0] == 0
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            out = base64.b64decode(call('output', live)[1]['content_base64'])
            err = base64.b64decode(call('output', live, stream='stderr')[1]['content_base64'])
            if out == b'live\n' and err == b'liveerr\n': break
            time.sleep(.1)
        else: raise AssertionError('Short live output was buffered until EOF')
        assert call('status', live)[1]['state'] == 'running'
    finally:
        call('cancel', live); wait(live); call('remove', live)
    print('PASS short stdout/stderr visible while command is still running')
    a = str(uuid.uuid4()).upper()
    assert call('start', a, command="printf 'hello\n'; printf 'error\n' >&2; sleep .3; exit 7")[0] == 0
    assert call('remove', a)[0] != 0
    assert call('start', a, command='exit 0')[0] != 0
    done = wait(a); assert done['state'] == 'completed' and done['exit_code'] == 7, done
    assert base64.b64decode(call('output', a, offset=1, max_bytes=3)[1]['content_base64']) == b'ell'
    assert base64.b64decode(call('output', a, stream='stderr')[1]['content_base64']) == b'error\n'
    assert call('output', a, stream='../../etc/passwd')[0] != 0
    assert call('remove', a)[1]['removed']
    b = str(uuid.uuid4()).upper()
    assert call('start', b, command='head -c 2560000 /dev/zero', max_log_bytes=1024)[0] == 0
    done = wait(b); assert done['truncated'] and done['stdout_bytes'] == 2560000 and done['stdout_retained_bytes'] == 1024, done
    assert base64.b64decode(call('output', b, offset=7, max_bytes=31)[1]['content_base64']) == bytes(31)
    assert call('output', b, offset=9007199254740991, max_bytes=31)[1]['bytes_read'] == 0
    assert call('remove', b)[0] == 0
    c = str(uuid.uuid4()).upper()
    assert call('start', c, command='sleep 60')[0] == 0
    assert call('cancel', c)[1]['state'] == 'cancellation_requested'
    assert wait(c)['state'] == 'cancelled'
    assert call('remove', c)[0] == 0
    d = str(uuid.uuid4()).upper()
    assert call('start', d, command='sleep 60', task_timeout_seconds=1)[0] == 0
    assert wait(d)['state'] == 'timed_out'
    assert call('remove', d)[0] == 0
    e = str(uuid.uuid4()).upper()
    assert call('start', e, command='echo unreachable', working_directory='/nonexistent-querycraft-fixture')[0] == 0
    assert wait(e)['state'] == 'failed'
    directory = Path(home) / '.querycraft-ssh-tasks/shell-v1' / e
    old_state = (directory / 'state').read_bytes()
    old_heartbeat = (directory / 'heartbeat').read_bytes()
    (directory / 'state').write_text('running null 1 1 0\n'); (directory / 'heartbeat').write_text('0\n')
    assert call('status', e)[1]['state'] == 'unknown'
    orphan_output = call('output', e)[1]
    assert orphan_output['state'] == 'unknown' and not orphan_output['final']
    assert call('cancel', e)[0] != 0 and call('remove', e)[0] != 0
    (directory / 'state').write_bytes(old_state); (directory / 'heartbeat').write_bytes(old_heartbeat)
    outside = Path(home) / 'keep-me'; outside.write_text('preserve')
    (directory / 'unexpected').symlink_to(outside)
    assert call('remove', e)[0] != 0 and outside.read_text() == 'preserve'
    (directory / 'unexpected').unlink()
    assert call('remove', e)[0] == 0
    legacy = str(uuid.uuid4()).upper()
    (Path(home) / '.querycraft-ssh-tasks' / legacy).mkdir(mode=0o700)
    assert call('status', legacy)[0] != 0
    mixed = str(uuid.uuid4()).upper()
    assert call('start', mixed, command='head -c 8192 /dev/zero; head -c 8192 /dev/zero >&2', max_log_bytes=1024)[0] == 0
    done = wait(mixed)
    assert done['stdout_bytes'] + done['stderr_bytes'] == 16384 and done['stdout_retained_bytes'] + done['stderr_retained_bytes'] <= 1024
    assert call('remove', mixed)[0] == 0
    assert not (Path(home) / 'python-was-called').exists(), 'Remote backend invoked Python'
    print('PASS no Python invocation; detached lifecycle, exact exit code, stdout/stderr windows, cap/drain, cancel, timeout, launch collision, active-removal refusal, invalid stream and cwd')
