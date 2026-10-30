#!/usr/bin/env python3
"""Exercise the actual MCP executable over stdio and authenticated HTTP in isolated storage."""
import argparse
import json
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

INIT = {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
    'protocolVersion': '2025-11-25',
    # Real Codex conversation capabilities differ from its settings health check.
    'capabilities': {'experimental': {'codex/auth-change': {}},
                     'extensions': {'openai/form': {}}, 'elicitation': {'form': {}, 'url': {}}},
    'clientInfo': {'name': 'codex-mcp-client', 'title': 'Codex', 'version': 'compatibility-regression'}}}

def policy(port):
    return {'version': 1, 'enabled': True, 'allConnections': False, 'connectionIDs': [], 'groupIDs': [],
            'groupModes': {}, 'connections': {}, 'disabledTools': ['remove_connection'],
            'queryTimeoutSeconds': 3, 'maximumRows': 1000, 'maximumResultBytes': 4194304,
            'sessionIdleSeconds': 1800, 'maximumSessions': 32,
            'http': {'host': '127.0.0.1', 'port': port, 'path': '/mcp', 'allowsRemote': False,
                     'allowedHosts': ['127.0.0.1', 'localhost', '[::1]'], 'allowedOrigins': [], 'token': 'test-' + 'a'*64}}

def read(process):
    if not select.select([process.stdout], [], [], 15)[0]: raise AssertionError('MCP did not respond within 15 seconds')
    line = process.stdout.readline()
    assert line, 'MCP exited: '+process.stderr.read().decode()
    return json.loads(line)

def send(process, obj, response=True):
    process.stdin.write(json.dumps(obj).encode()+b'\n'); process.stdin.flush()
    return read(process) if response else None

def stdio(executable, root, settings):
    process = subprocess.Popen([str(executable), '--stdio', '--data-dir', str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        initialized = send(process, INIT)['result']
        assert initialized['serverInfo']['name'] == 'QueryCraft'
        assert 'next_offset' in initialized['instructions']
        send(process, {'jsonrpc':'2.0','method':'notifications/initialized'}, False)
        tools = send(process, {'jsonrpc':'2.0','id':2,'method':'tools/list'})['result']['tools']
        names = {t['name'] for t in tools}
        assert 'querycraft_execute_query' in names and 'querycraft_remove_connection' not in names
        resources = send(process, {'jsonrpc':'2.0','id':3,'method':'resources/list'})['result']['resources']
        assert resources[0]['uri']=='querycraft://connections'
        result = send(process, {'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'querycraft_list_connections','arguments':{}}})['result']
        assert not result.get('isError'), result
        assert json.loads(result['content'][0]['text']) == []
        schema = next(t for t in tools if t['name'] == 'querycraft_get_schema_context')
        assert schema['annotations']['readOnlyHint'] is True
        assert schema['inputSchema']['properties']['max_tables']['type'] == 'integer'
        assert schema['inputSchema']['properties']['table_offset']['type'] == 'integer'
        batch = next(t for t in tools if t['name'] == 'querycraft_execute_batch')
        assert batch['inputSchema']['properties']['result_mode']['enum'] == ['summary', 'detailed']
        details = next(t for t in tools if t['name'] == 'querycraft_get_batch_results')
        assert details['annotations']['readOnlyHint'] is True
        assert details['inputSchema']['required'] == ['connection_id', 'batch_id']
        bad = send(process, {'jsonrpc':'2.0','id':40,'method':'tools/call','params':{'name':'querycraft_execute_query','arguments':{'connection_id':'invalid','sql':'private-protocol-secret'}}})['result']
        assert bad['isError'] is True
        assert bad['structuredContent']['error']['code'] == 'CONNECTION_NOT_FOUND'
        assert bad['structuredContent']['error']['automatic_retry'] is False
        settings['optimizations']={'discovery':'lazy','metadataCacheSeconds':30,'maximumIdleConnections':4,'recordsHistory':True}
        settings['disabledTools'].append('list_tables')
        (root/'mcp-policy.json').write_text(json.dumps(settings))
        lazy = send(process, {'jsonrpc':'2.0','id':41,'method':'tools/list'})['result']['tools']
        assert len(lazy) < len(tools)
        print(f'Discovery schema payload: {len(tools)} tools / {len(json.dumps(tools).encode())} bytes -> {len(lazy)} tools / {len(json.dumps(lazy).encode())} bytes in lazy mode')
        assert 'querycraft_execute_query' not in {t['name'] for t in lazy}
        assert 'querycraft_plugin_tools' in {t['name'] for t in lazy}
        templates = send(process, {'jsonrpc':'2.0','id':42,'method':'resources/templates/list'})['result']['resourceTemplates']
        assert all(t['name'] != 'tables' for t in templates)
        settings['disabledTools'].remove('list_tables')
        settings['optimizations']['discovery']='both'
        settings['enabled']=False; (root/'mcp-policy.json').write_text(json.dumps(settings))
        result = send(process, {'jsonrpc':'2.0','id':5,'method':'tools/call','params':{'name':'querycraft_list_connections','arguments':{}}})['result']
        assert result['isError'] is True
        assert result['structuredContent']['error']['code'] == 'ACCESS_DENIED'
        settings['enabled']=True; (root/'mcp-policy.json').write_text(json.dumps(settings))
        import sqlite3
        with sqlite3.connect(root/'MCP/History/calls.sqlite') as history:
            records=history.execute('SELECT tool,errorCode FROM mcpCall').fetchall()
            assert any(code == 'CONNECTION_NOT_FOUND' for _,code in records)
        assert b'private-protocol-secret' not in (root/'MCP/History/calls.sqlite').read_bytes()
        print('PASS stdio instructions, tool hints, lazy discovery, scoped Resources, typed errors, private history and live revocation')
    finally:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait()

def http(executable, root, settings):
    process = subprocess.Popen([str(executable), '--http', '--data-dir', str(root)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    url=f'http://127.0.0.1:{settings["http"]["port"]}/mcp'
    def request(payload, token=True, extra=None):
        headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream'}
        if token:headers['Authorization']='Bearer '+settings['http']['token']
        headers.update(extra or {})
        req=urllib.request.Request(url, json.dumps(payload).encode(), headers)
        try:
            with urllib.request.urlopen(req, timeout=5) as response:
                body=response.read().decode(); response_headers=dict(response.headers)
                if body.startswith('event:') or body.startswith('id:') or body.startswith('data:'):
                    body='\n'.join(l[5:].strip() for l in body.splitlines() if l.startswith('data:') and l[5:].strip())
                return response.status, response_headers, json.loads(body) if body else None
        except urllib.error.HTTPError as e:return e.code, dict(e.headers), None
    try:
        for _ in range(60):
            try:
                code,_,_=request(INIT, token=False)
                break
            except urllib.error.URLError:time.sleep(.1)
        else:raise AssertionError('HTTP listener failed to start')
        assert code==401,code
        assert request(INIT,extra={'Origin':'https://untrusted.example'})[0]==403
        code,headers,body=request(INIT)
        assert code==200,(code,body)
        session=headers.get('MCP-Session-Id') or headers.get('mcp-session-id')
        assert session,headers
        extra={'MCP-Session-Id':session,'MCP-Protocol-Version':'2025-11-25'}
        assert request({'jsonrpc':'2.0','method':'notifications/initialized'},extra=extra)[0]==202
        code,_,body=request({'jsonrpc':'2.0','id':2,'method':'tools/list'},extra=extra)
        assert code==200 and body['result']['tools'],(code,body)
        settings['http']['token']='rotated-'+('b'*64)
        (root/'mcp-policy.json').write_text(json.dumps(settings))
        old={'Authorization':'Bearer test-'+('a'*64),**extra}
        assert request({'jsonrpc':'2.0','id':3,'method':'tools/list'},extra=old)[0]==401
        print('PASS HTTP auth, Origin rejection, initialization, session routing, live token rotation')
    finally:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait()

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('executable',type=Path);args=parser.parse_args()
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix='querycraft-mcp-test-') as temporary:
        root=Path(temporary);settings=policy(port);(root/'mcp-policy.json').write_text(json.dumps(settings))
        stdio(args.executable.resolve(),root,settings);http(args.executable.resolve(),root,settings)
