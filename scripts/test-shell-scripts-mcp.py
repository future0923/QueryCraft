#!/usr/bin/env python3
"""Exercise saved Shell CRUD over real stdio with isolated storage and no SSH plugin."""
import argparse
import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('protocol', ROOT / 'scripts/test-mcp-protocol.py')
protocol = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(protocol)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='qc-shell-stdio-') as temporary:
        root = Path(temporary)
        policy = protocol.policy(18788); policy['mode'] = 'high_risk_write'
        settings = root / 'mcp-policy.json'
        def save(): settings.write_text(json.dumps(policy))
        save()
        counter = 5
        def start():
            p = subprocess.Popen([str(args.executable.resolve()), '--stdio', '--data-dir', str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            protocol.send(p, protocol.INIT)
            protocol.send(p, {'jsonrpc':'2.0','method':'notifications/initialized'}, False)
            return p
        def close(p):
            p.stdin.close()
            try: p.wait(timeout=10)
            except subprocess.TimeoutExpired: p.kill(); p.wait(); raise
            assert p.returncode == 0, p.stderr.read().decode()
        def call(p, tool, values=None, error=None):
            nonlocal counter
            counter += 1
            result = protocol.send(p, {'jsonrpc':'2.0','id':counter,'method':'tools/call','params':{'name':'querycraft_'+tool,'arguments':values or {}}})['result']
            if error:
                assert result.get('isError') and result['structuredContent']['error']['code'] == error, result
            else:
                assert not result.get('isError'), result
                return result['structuredContent']
        p = start()
        try:
            assert call(p,'shell_list')['scripts'] == []
            scripts = call(p,'plugin_tools',{'plugin_id':'shell'})
            assert {s['name'] for s in scripts} == {'shell_list','shell_get','shell_create','shell_update','shell_delete'}
            body = "printf '%s\\n' '你好 👩‍💻'\n# literal body\n" * 200
            record = call(p,'shell_create',{'name':'健康检查','description':'saved, never executed','script':body})
            script_id = record['script_id']; assert record['revision'] == 1
            output = ''; offset = 0
            while True:
                chunk = call(p,'shell_get',{'script_id':script_id,'script_offset':offset,'max_chars':137})
                assert chunk['revision'] == 1
                output += chunk['script']
                if chunk['next_offset'] is None: break
                assert chunk['next_offset'] > offset
                offset = chunk['next_offset']
            assert output == body
            call(p,'shell_update',{'script_id':script_id,'expected_revision':1,'description':'revision two'})
            call(p,'shell_update',{'script_id':script_id,'expected_revision':1,'script':'stale'},error='SESSION_BUSY')
            call(p,'shell_delete',{'script_id':script_id,'expected_revision':1},error='SESSION_BUSY')
            assert stat.S_IMODE((root/'shell-scripts.json').stat().st_mode) == 0o600
        finally: close(p)
        p = start()
        try:
            persisted = call(p,'shell_get',{'script_id':script_id,'max_chars':65536})
            assert persisted['script'] == body and persisted['revision'] == 2
            policy['mode']='read_only'; save()
            call(p,'shell_list')
            call(p,'shell_create',{'name':'blocked','script':'false'},error='ACCESS_DENIED')
            policy['disabledTools'] = ['shell_get']; save()
            call(p,'plugin_call',{'plugin_id':'shell','tool':'shell_get','arguments':{'script_id':script_id}},error='ACCESS_DENIED')
            policy['mode']='high_risk_write'; policy['disabledTools']=[]; save()
            call(p,'plugin_call',{'plugin_id':'shell','tool':'shell_delete','arguments':{'script_id':script_id,'expected_revision':2}})
            assert call(p,'shell_list')['scripts'] == []
            assert not (root/'Plugins/SSH').exists()
        finally: close(p)
        print('PASS stdio saved Shell CRUD, Unicode windows, persistence, revision conflicts, private storage and delegated policy without SSH plugin')


if __name__ == '__main__': main()
