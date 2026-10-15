#!/usr/bin/env python3
"""Verify the installed Codex's actual conversation MCP client, without model calls.

All Codex configuration and ephemeral protocol contexts live in a temporary home.
Default MCP storage is isolated too. --data-dir permits read-only list_connections
against existing storage, without changing its policy, profiles or credentials.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import shutil
import socket
import subprocess
import tempfile
import threading
import time


class AppServer:
    def __init__(self, codex, home, environment=None):
        self.messages = queue.Queue()
        self.stderr = (home / 'app-server.log').open('wb')
        self.process = subprocess.Popen([str(codex), 'app-server', '--stdio'], cwd=home,
            env={**os.environ, **(environment or {}), 'CODEX_HOME': str(home)}, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=self.stderr)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.request_id = 0

    def _read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        finally:
            self.messages.put(None)

    def notify(self, method):
        self.process.stdin.write((json.dumps({'method': method}) + '\n').encode())
        self.process.stdin.flush()

    def call(self, method, params):
        self.request_id += 1
        request_id = self.request_id
        self.process.stdin.write((json.dumps({'id': request_id, 'method': method, 'params': params}) + '\n').encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            message = self.messages.get(timeout=max(.1, deadline - time.monotonic()))
            assert message is not None, 'Codex app-server exited before responding'
            if message.get('id') == request_id:
                assert 'error' not in message, message
                return message['result']
        raise TimeoutError(method)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.reader.join(timeout=2)
        self.stderr.close()


def verify(codex, executable, data_directory, home, isolated, cycles, transport):
    config = ('[mcp_servers.querycraft]\ncommand = ' + json.dumps(str(executable), ensure_ascii=False)
              + '\nargs = ["--stdio", "--data-dir", ' + json.dumps(str(data_directory), ensure_ascii=False)
              + ']\nstartup_timeout_sec = 30\n')
    listener = None
    environment = {}
    if isolated:
        spec = importlib.util.spec_from_file_location('protocol', Path(__file__).with_name('test-mcp-protocol.py'))
        protocol = importlib.util.module_from_spec(spec); spec.loader.exec_module(protocol)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        settings = protocol.policy(port)
        (data_directory / 'mcp-policy.json').write_text(json.dumps(settings))
    if transport == 'http':
        assert isolated, 'HTTP tests require isolated data; do not start a service against personal storage'
        environment['QUERYCRAFT_MCP_TEST_TOKEN'] = settings['http']['token']
        config = ('[mcp_servers.querycraft]\nurl = "http://127.0.0.1:' + str(port)
                  + '/mcp"\nbearer_token_env_var = "QUERYCRAFT_MCP_TEST_TOKEN"\nstartup_timeout_sec = 30\n')
        listener = subprocess.Popen([str(executable), '--http', '--data-dir', str(data_directory)],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (home / 'config.toml').write_text(config)
    (home / 'config.toml').chmod(0o600)
    app = None
    try:
        if listener:
            deadline = time.monotonic() + 20
            while True:
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.2): break
                except OSError:
                    assert listener.poll() is None, 'HTTP listener exited'
                    assert time.monotonic() < deadline, 'HTTP listener did not become ready'
                    time.sleep(.1)
        app = AppServer(codex, home, environment)
        app.call('initialize', {'clientInfo': {'name': 'QueryCraft Compatibility Test', 'version': '1'},
                               'capabilities': {'experimentalApi': True, 'extensions': {'openai/form': {}}}})
        app.notify('initialized')
        inventory = app.call('mcpServerStatus/list', {'serverName': 'querycraft'})['data']
        assert len(inventory) == 1 and 'querycraft_list_connections' in inventory[0]['tools'], inventory
        print('PASS Codex settings discovery', flush=True)
        for cycle in range(cycles):
            # This initializes the real conversation MCP runtime without a turn
            # or a model request. The settings scan above uses different caps.
            thread = app.call('thread/start', {'ephemeral': True, 'cwd': str(home),
                                              'approvalPolicy': 'never'})['thread']['id']
            status = app.call('mcpServerStatus/list', {'serverName': 'querycraft', 'threadId': thread})['data'][0]
            assert status['runtimeStatus'] == 'connected', {key: status.get(key) for key in ('runtimeStatus', 'toolsError')}
            assert 'querycraft_list_connections' in status['tools'], status
            result = app.call('mcpServer/tool/call', {'server': 'querycraft', 'threadId': thread,
                            'tool': 'querycraft_list_connections', 'arguments': {}})
            assert result.get('isError') is not True, result
            connections = json.loads(next(c['text'] for c in result['content'] if c.get('type') == 'text'))
            assert isinstance(connections, list), 'list_connections must return an array'
            if isolated:
                assert connections == [], connections
            print(f'PASS Codex conversation {cycle+1}: ready, {len(status["tools"])} tools, '
                  f'list_connections returned {len(connections)} authorized connections', flush=True)
            if isolated and cycle == 0:
                params = {'server': 'querycraft', 'threadId': thread,
                          'tool': 'querycraft_list_connections', 'arguments': {}}
                settings['disabledTools'].append('list_connections')
                (data_directory / 'mcp-policy.json').write_text(json.dumps(settings))
                denied = app.call('mcpServer/tool/call', params)
                assert denied.get('isError') is True, denied
                assert denied['structuredContent']['error']['code'] == 'ACCESS_DENIED', denied
                settings['disabledTools'].remove('list_connections')
                (data_directory / 'mcp-policy.json').write_text(json.dumps(settings))
                restored = app.call('mcpServer/tool/call', params)
                assert restored.get('isError') is not True, restored
                print('PASS Codex existing conversation observes revocation and restored authorization', flush=True)
            # A new ephemeral context is used each cycle; do not persist test chats.
            app.call('thread/unsubscribe', {'threadId': thread})
    finally:
        if app:
            app.close()
        if listener:
            listener.terminate()
            try:
                listener.wait(timeout=5)
            except subprocess.TimeoutExpired:
                listener.kill(); listener.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('--codex', type=Path, default=shutil.which('codex') or
        '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex')
    parser.add_argument('--data-dir', type=Path)
    parser.add_argument('--cycles', type=int, default=3)
    parser.add_argument('--transport', choices=['stdio', 'http'], default='stdio')
    args = parser.parse_args()
    assert args.cycles > 0
    with tempfile.TemporaryDirectory(prefix='querycraft-codex-check-') as temporary:
        root = Path(temporary); root.chmod(0o700)
        data = args.data_dir.resolve() if args.data_dir else root / 'data'
        data.mkdir(parents=True, exist_ok=True)
        verify(args.codex.resolve(), args.executable.resolve(), data, root,
               isolated=args.data_dir is None, cycles=args.cycles, transport=args.transport)
