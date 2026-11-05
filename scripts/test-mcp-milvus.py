#!/usr/bin/env python3
"""Verify a packaged MCP against an already authorized Milvus profile, read-only."""
import argparse
import importlib.util
import json
from pathlib import Path
import select
import subprocess

protocol_spec = importlib.util.spec_from_file_location('mcp_protocol', Path(__file__).with_name('test-mcp-protocol.py'))
protocol = importlib.util.module_from_spec(protocol_spec)
protocol_spec.loader.exec_module(protocol)


def verify(executable, directory, connection_id, database, collection):
    process = subprocess.Popen([str(executable), '--stdio', '--data-dir', str(directory)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    serial = 1

    def send(message, response=True):
        process.stdin.write(json.dumps(message).encode() + b'\n')
        process.stdin.flush()
        if not response:
            return None
        if not select.select([process.stdout], [], [], 75)[0]:
            raise AssertionError('MCP response timed out')
        line = process.stdout.readline()
        assert line, 'MCP exited before responding'
        result = json.loads(line)
        assert 'error' not in result, result.get('error')
        return result['result']

    def call(name, arguments, expected_error=None):
        nonlocal serial
        serial += 1
        result = send({'jsonrpc': '2.0', 'id': serial, 'method': 'tools/call',
                       'params': {'name': 'querycraft_' + name, 'arguments': arguments}})
        if expected_error:
            assert result.get('isError'), name + ' unexpectedly succeeded'
            assert result['structuredContent']['error']['code'] == expected_error, result
            return None
        assert not result.get('isError'), result
        return json.loads(result['content'][0]['text'])

    try:
        initialized = send(protocol.INIT)
        assert 'Milvus' in initialized['instructions']
        send({'jsonrpc': '2.0', 'method': 'notifications/initialized'}, False)
        runtime = call('runtime_info', {})
        assert runtime['reconnect_required'] is False, 'MCP loaded and installed identities differ'
        profiles = call('list_connections', {})
        profile = next(p for p in profiles if p['id'].upper() == connection_id.upper())
        assert profile['type'] == 'milvus', profile
        selector = {'connection_id': connection_id, 'database': database}
        tools = call('plugin_tools', {'connection_id': connection_id})
        assert any(t['name'] == 'execute_milvus_request' for t in tools)
        assert database in call('list_databases', {'connection_id': connection_id})
        objects = call('list_tables', selector)
        assert any(o['name'] == collection and o['kind'] == 'milvusCollection' for o in objects)
        schema = call('describe_table', dict(selector, table=collection))[0]['columns']
        context = call('get_schema_context', dict(selector, tables=[collection], format='detailed'))
        assert context['returned_tables'] == 1
        primary = next(c['name'] for c in schema if c['key'] == 'PRIMARY')
        vector = next(c['name'] for c in schema if c['type'].startswith('FloatVector('))

        def read(operation, body, expected_error=None):
            return call('execute_milvus_request', dict(selector, collection=collection,
                        operation=operation, body=json.dumps(body), max_rows=2), expected_error=expected_error)

        queried = read('query', {'filter': '', 'outputFields': [primary, vector], 'limit': 1})
        entity = json.loads(queried['body'])['data'][0]
        assert queried['returned_entities'] == 1
        identifier = entity[primary]
        assert isinstance(identifier, str), 'Int64 primary keys must retain their textual precision'
        got = read('get', {'id': [identifier], 'outputFields': [primary]})
        assert json.loads(got['body'])['data'][0][primary] == identifier
        searched = read('search', {'data': [entity[vector]], 'annsField': vector,
                                  'searchParams': {'metricType': 'COSINE'}, 'outputFields': [primary], 'limit': 2})
        hits = json.loads(searched['body'])['data']
        assert 0 < searched['returned_entities'] <= 2
        assert all('distance' in hit for hit in hits)
        assert all(isinstance(hit[primary], str) for hit in hits)
        read('query', {'collectionName': '__mcp_scope_override__'}, expected_error='INVALID_ARGUMENT')
        read('delete', {}, expected_error='INVALID_ARGUMENT')
        print(f'PASS live Milvus MCP discovery, databases, collections and {len(schema)} schema fields')
        print(f'PASS Query, Get, Search ({len(entity[vector])} dimensions, {len(hits)} scored hits) and Int64 precision')
        print('PASS collection override and write-route rejection')
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('--data-dir', required=True, type=Path)
    parser.add_argument('--connection-id', required=True)
    parser.add_argument('--database', default='default')
    parser.add_argument('--collection', required=True)
    args = parser.parse_args()
    verify(args.executable.resolve(), args.data_dir.resolve(), args.connection_id, args.database, args.collection)
