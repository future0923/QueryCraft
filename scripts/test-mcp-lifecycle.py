#!/usr/bin/env python3
"""Verify standalone process exit, client reconnect and HTTP session lifecycle.

Uses isolated storage and only the supplied MCP executable. No desktop input,
user configuration, database, or computer restart is involved.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('protocol', ROOT / 'scripts/test-mcp-protocol.py')
protocol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocol)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


class HTTPClient:
    def __init__(self, settings):
        self.settings = settings
        self.session = None
        self.sequence = 1

    def request(self, payload=None, method='POST', headers=None):
        http = self.settings['http']
        fields = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream',
                  'Authorization': 'Bearer ' + http['token'], 'MCP-Protocol-Version': '2025-11-25'}
        if self.session:
            fields['MCP-Session-Id'] = self.session
        fields.update(headers or {})
        request = urllib.request.Request(f'http://127.0.0.1:{http["port"]}{http["path"]}',
                                         json.dumps(payload).encode() if payload else None, fields, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read().decode()
                if body.startswith(('event:', 'id:', 'data:')):
                    body = '\n'.join(line[5:].strip() for line in body.splitlines() if line.startswith('data:'))
                return response.status, response.headers, json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            return error.code, error.headers, None

    def connect(self):
        self.session = None
        status, headers, body = self.request(protocol.INIT)
        assert status == 200, (status, body)
        self.session = headers.get('MCP-Session-Id')
        assert self.session
        assert self.request({'jsonrpc': '2.0', 'method': 'notifications/initialized'})[0] == 202
        return self

    def call(self, name, arguments=None, error=False):
        self.sequence += 1
        status, _, body = self.request({'jsonrpc': '2.0', 'id': self.sequence, 'method': 'tools/call',
                                      'params': {'name': 'querycraft_' + name, 'arguments': arguments or {}}})
        assert status == 200, (status, body)
        result = body['result']
        assert bool(result.get('isError')) == error, result
        return result if error else json.loads(result['content'][0]['text'])

    def close(self):
        status, _, _ = self.request(method='DELETE')
        assert status == 200, status
        assert self.request({'jsonrpc': '2.0', 'id': 999, 'method': 'tools/list'})[0] == 404
        self.session = None


def launch_http(executable, directory, settings):
    process = subprocess.Popen([str(executable), '--http', '--data-dir', str(directory)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            assert process.poll() is None, process.stderr.read().decode()
            try:
                with socket.create_connection(('127.0.0.1', settings['http']['port']), timeout=.2):
                    return process
            except OSError:
                time.sleep(.1)
        raise AssertionError('HTTP did not become ready')
    except BaseException:
        stop(process)
        raise


def verify(executable):
    with tempfile.TemporaryDirectory(prefix='qc-mcp-lifecycle-') as temp:
        directory = Path(temp)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            settings = protocol.policy(sock.getsockname()[1])
        (directory / 'mcp-policy.json').write_text(json.dumps(settings))
        for _ in range(5):
            process = subprocess.Popen([str(executable), '--stdio', '--data-dir', temp],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                protocol.send(process, protocol.INIT)
                protocol.send(process, {'jsonrpc': '2.0', 'method': 'notifications/initialized'}, False)
                process.stdin.close()
                assert process.wait(timeout=10) == 0
                assert b'is implemented in both' not in process.stderr.read()
            finally:
                stop(process)
        print('PASS five stdio client connect / EOF / clean process exit cycles', flush=True)
        process = launch_http(executable, directory, settings)
        try:
            client = HTTPClient(settings).connect()
            assert client.call('list_connections') == []
            def reconnect(_):
                for _ in range(5):
                    peer = HTTPClient(settings).connect()
                    assert peer.call('list_connections') == []
                    peer.close()
            with ThreadPoolExecutor(max_workers=6) as pool:
                list(pool.map(reconnect, range(6)))
            assert client.call('list_connections') == []
            print('PASS 30 HTTP connect / DELETE / reconnect cycles across six concurrent clients; existing session survives', flush=True)
            stop(process)
            process = launch_http(executable, directory, settings)
            assert client.request({'jsonrpc': '2.0', 'id': 999, 'method': 'tools/list'})[0] == 404
            client.connect()
            assert client.call('list_connections') == []
            client.close()
            print('PASS standalone HTTP process restart; stale sessions rejected and fresh client reconnects using persisted settings', flush=True)
        finally:
            stop(process)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    verify(parser.parse_args().executable.resolve())
