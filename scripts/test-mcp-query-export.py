#!/usr/bin/env python3
"""Accept a packaged MCP + MySQL driver using only a disposable loopback Docker DB.
Never reads desktop profiles, production credentials, or existing database data.
"""
import argparse
import csv
from datetime import datetime
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('protocol', ROOT / 'scripts/test-mcp-protocol.py')
protocol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocol)
NS = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('--drivers-dir', type=Path, required=True)
    parser.add_argument('--mysql-image', default='mysql:8.4')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    name = 'qc-export-' + uuid.uuid4().hex[:12]
    process = None

    def docker(*command, input=None):
        return subprocess.run(['docker', *command], input=input, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout.strip()

    try:
        docker('run', '-d', '--name', name, '-p', '127.0.0.1::3306', '-e', 'MYSQL_ALLOW_EMPTY_PASSWORD=yes', args.mysql_image)
        port = int(docker('port', name, '3306').split(':')[-1])
        for _ in range(120):
            try:
                docker('exec', name, 'mysqladmin', '-uroot', '--protocol=tcp', '-h127.0.0.1', 'ping')
                break
            except subprocess.CalledProcessError:
                time.sleep(.5)
        else:
            raise AssertionError('Disposable MySQL did not become ready')
        sql = """
CREATE DATABASE qc_export;
USE qc_export;
SET SESSION cte_max_recursion_depth=60000;
SET time_zone='+08:00';
CREATE TABLE users(id BIGINT UNSIGNED PRIMARY KEY,name VARCHAR(80),created_at DATETIME(6),phone VARCHAR(32),note TEXT) ENGINE=InnoDB;
INSERT INTO users WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<4404)
SELECT 9007199254740993+n, CONCAT('用户',n),'2026-10-01 12:34:56.123456','0013800000000',CASE WHEN n=1 THEN '=1+2' WHEN n=2 THEN NULL WHEN n=3 THEN '' ELSE '普通文本' END FROM seq;
CREATE TABLE records(id BIGINT UNSIGNED PRIMARY KEY,user_id BIGINT UNSIGNED,amount DECIMAL(30,6),booked_at TIMESTAMP) ENGINE=InnoDB;
INSERT INTO records WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<56945)
SELECT n,9007199254740994,'12345678901234567890.123400','2026-10-12 08:09:10' FROM seq;
CREATE TABLE nontransactional(id INT) ENGINE=MyISAM;
INSERT INTO nontransactional VALUES(1);
SET GLOBAL sql_select_limit=1000;
"""
        docker('exec', '-i', name, 'mysql', '-uroot', '--default-character-set=utf8mb4', input=sql)
        with tempfile.TemporaryDirectory(prefix='QueryCraftDev-export-') as temporary:
            root = Path(temporary)
            drivers = args.drivers_dir.resolve()
            bundle = next(drivers.glob('MySQL-*.querycraftdriver'))
            api = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())['QCDriverAPIVersion']
            shutil.copytree(bundle, root / f'DriverAPI-{api}' / 'Drivers' / bundle.name, symlinks=True)
            settings = protocol.policy(5227)
            settings.update(allConnections=True, disabledTools=[], queryTimeoutSeconds=60, maximumRows=1)

            def save():
                (root / 'mcp-policy.json').write_text(json.dumps(settings))
            save()
            checked = subprocess.run([str(args.executable.resolve()), '--check-drivers', '--data-dir', str(root)], capture_output=True, text=True, check=True)
            assert 'mysql' in json.loads(checked.stdout), checked.stdout + checked.stderr
            process = subprocess.Popen([str(args.executable.resolve()), '--stdio', '--data-dir', str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            protocol.send(process, protocol.INIT)
            protocol.send(process, {'jsonrpc': '2.0', 'method': 'notifications/initialized'}, False)
            sequence = 1

            def call(tool, values=None, error=False):
                nonlocal sequence
                sequence += 1
                response = protocol.send(process, {'jsonrpc': '2.0', 'id': sequence, 'method': 'tools/call', 'params': {'name': 'querycraft_' + tool, 'arguments': values or {}}})['result']
                if error:
                    assert response.get('isError'), response
                    return response
                assert not response.get('isError'), response
                return json.loads(response['content'][0]['text'])

            cid = call('add_connection', {'name': 'Disposable export fixture', 'type': 'mysql', 'host': '127.0.0.1', 'port': port, 'username': 'root', 'database': 'qc_export', 'tls_mode': 'disabled'})['connection_id']
            settings['connections'][cid] = {'mode': 'read_only', 'databases': ['qc_export'], 'databaseAccess': 'selected', 'databaseModes': {}}
            save()
            q1 = {'name': '住房宝用户', 'sql': 'SELECT id,name,created_at,phone,note FROM users ORDER BY id', 'expected_rows': 4404,
                  'columns': [{'source_index': i, 'title': title, 'type': 'text'} for i, title in enumerate(['用户ID', '姓名', '创建时间', '手机号', '备注'])]}
            q2 = {'name': '商机收支记录', 'sql': 'SELECT id,user_id,amount,booked_at FROM records ORDER BY id', 'expected_rows': 56945,
                  'columns': [{'source_index': 0, 'title': 'ID', 'type': 'integer'}, {'source_index': 1, 'title': '用户ID', 'type': 'text'}, {'source_index': 2, 'title': '金额', 'type': 'decimal'}, {'source_index': 3, 'title': '入账时间', 'type': 'datetime', 'date_format': 'yyyy-mm-dd hh:mm:ss'}]}
            request = {'connection_id': cid, 'database': 'qc_export', 'format': 'xlsx', 'filename': '2026-10.xlsx', 'timezone': '+08:00', 'consistency': 'single_snapshot', 'idempotency_key': str(uuid.uuid4()), 'queries': [q1, q2]}

            baseline_rss = int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(process.pid)], text=True).strip())
            peak_rss = baseline_rss

            def wait(submission, on_progress=None):
                nonlocal peak_rss
                key = {k: submission[k] for k in ['job_id', 'access_token']}
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    peak_rss = max(peak_rss, int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(process.pid)], text=True).strip()))
                    status = call('get_export_status', key)
                    if status['status'] not in ['queued', 'running', 'finalizing']:
                        return key, status
                    if on_progress:
                        on_progress(status)
                    time.sleep(.1)
                raise AssertionError('Export did not finish')

            started = time.monotonic()
            submission = call('export_query', request)
            assert call('export_query', request)['job_id'] == submission['job_id']
            mutated = False

            def mutate_during_first_sheet(status):
                nonlocal mutated
                if not mutated and status['current_query'] == 0 and status['total_rows'] > 0:
                    docker('exec', name, 'mysql', '-uroot', '-e', "UPDATE qc_export.records SET amount=42 WHERE id=1")
                    mutated = True

            key, status = wait(submission, mutate_during_first_sheet)
            export_seconds = time.monotonic() - started
            assert status['status'] == 'succeeded', status
            assert mutated, 'Fixture did not mutate the second table while the first sheet was streaming'
            assert status['total_rows'] == 61349 and [q['rows_written'] for q in status['queries']] == [4404, 56945]
            artifact = Path(status['artifact']['local_path'])
            assert artifact.stat().st_size == status['artifact']['size_bytes']
            assert hashlib.sha256(artifact.read_bytes()).hexdigest() == status['artifact']['sha256']
            with zipfile.ZipFile(artifact) as z:
                assert z.testzip() is None
                sheet1 = ET.fromstring(z.read('xl/worksheets/sheet1.xml'))
                sheet2 = ET.fromstring(z.read('xl/worksheets/sheet2.xml'))
                rows1 = sheet1.findall('s:sheetData/s:row', NS)
                rows2 = sheet2.findall('s:sheetData/s:row', NS)
                assert len(rows1) == 4405 and len(rows2) == 56946
                def cells(row):
                    return {c.attrib['r']: ''.join(c.itertext()) for c in row}
                assert cells(rows1[1])['A2'] == '9007199254740994'
                assert cells(rows1[1])['C2'] == '2026-10-01 12:34:56.123456'
                assert cells(rows1[1])['D2'] == '0013800000000'
                assert cells(rows1[1])['E2'] == '=1+2'
                assert 'E3' not in cells(rows1[2]) and cells(rows1[3])['E4'] == ''
                assert cells(rows2[1])['C2'] == '12345678901234567890.123400'
                timestamp = rows2[1].find("s:c[@r='D2']", NS)
                expected_serial = (datetime(2026, 10, 12, 8, 9, 10) - datetime(1899, 12, 30)).total_seconds() / 86400
                assert timestamp.attrib['t'] == 'n' and abs(float(cells(rows2[1])['D2']) - expected_serial) < 1e-9
                assert all(c.attrib.get('t') == 'inlineStr' for row in rows1 for c in row)
                assert not sheet1.findall('.//s:f', NS) and not sheet2.findall('.//s:f', NS)
                assert len({cells(row)['A' + row.attrib['r']] for row in rows1[1:]}) == 4404
                assert len({cells(row)['A' + row.attrib['r']] for row in rows2[1:]}) == 56945
                assert sheet1.find('s:autoFilter', NS) is not None
            shutil.copy2(artifact, args.output / '2026-10-fixture.xlsx')
            summary = {'status': 'passed', 'rows': 61349, 'size_bytes': artifact.stat().st_size, 'export_seconds': round(export_seconds, 3), 'sha256': status['artifact']['sha256'], 'loaded_driver': bundle.name, 'isolated': True, 'baseline_rss_kib': baseline_rss, 'sampled_peak_rss_kib': peak_rss}
            print('PASS native MySQL XLSX, counts, identities, full precision, NULL/text, snapshot, idempotency and global/chat limit bypass', flush=True)
            call('delete_export', key)
            assert not artifact.exists()
            docker('exec', name, 'mysql', '-uroot', '-e', "UPDATE qc_export.records SET amount=12345678901234567890.123400 WHERE id=1")

            csv_request = dict(request, format='csv', filename='2026-10.zip', idempotency_key=str(uuid.uuid4()))
            csv_key, csv_status = wait(call('export_query', csv_request))
            assert csv_status['status'] == 'succeeded', csv_status
            with zipfile.ZipFile(csv_status['artifact']['local_path']) as z:
                for filename, count in [('1-住房宝用户.csv', 4404), ('2-商机收支记录.csv', 56945)]:
                    body = z.read(filename)
                    assert body.startswith(b'\xef\xbb\xbf')
                    assert sum(1 for _ in csv.reader(io.StringIO(body.decode('utf-8-sig')))) == count + 1
                assert json.loads(z.read('manifest.json'))['rows'] == 61349
            call('delete_export', csv_key)
            print('PASS native multi-query CSV ZIP and manifest', flush=True)

            for sql in ['UPDATE users SET name=\'bad\'', 'SELECT * FROM mysql.user', "SELECT LOAD_FILE('/etc/passwd')"]:
                bad = dict(request, queries=[dict(name='bad', sql=sql)], idempotency_key=str(uuid.uuid4()))
                call('export_query', bad, error=True)
            for changes in [dict(limits={'max_rows': 100}, queries=[dict(name='limit', sql=q1['sql'])]), dict(limits={'max_file_bytes': 100}), dict(queries=[dict(name='engine', sql='SELECT * FROM nontransactional')]), dict(queries=[q1, dict(q2, expected_rows=56944)])]:
                bad = dict(request, **changes, idempotency_key=str(uuid.uuid4()))
                failed_key, failed = wait(call('export_query', bad))
                assert failed['status'] == 'failed' and 'artifact' not in failed, failed
                call('delete_export', failed_key)
            print('PASS read-only/scope checks, row limits, unsupported snapshot engine and second-sheet failure', flush=True)

            # Hold a metadata/table lock so cancellation must interrupt the native socket
            # while it is awaiting results, not merely stop a cooperative mock stream.
            blocker = subprocess.Popen(['docker', 'exec', name, 'mysql', '-uroot', '-e',
                'LOCK TABLES qc_export.users WRITE; SELECT SLEEP(60)'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    count = docker('exec', name, 'mysql', '-uroot', '-Nse',
                        "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO='SELECT SLEEP(60)'")
                    if count == '1':
                        break
                    time.sleep(.1)
                else:
                    raise AssertionError('Fixture could not hold table lock')
                blocked = dict(request, queries=[q1], idempotency_key=str(uuid.uuid4()))
                submitted = call('export_query', blocked)
                blocked_key = {k: submitted[k] for k in ['job_id', 'access_token']}
                for _ in range(100):
                    if call('get_export_status', blocked_key)['status'] == 'running':
                        break
                    time.sleep(.05)
                else:
                    raise AssertionError('Export did not start')
                cancelled_at = time.monotonic()
                call('cancel_export', blocked_key)
                _, cancelled = wait(submitted)
                assert cancelled['status'] == 'cancelled' and 'artifact' not in cancelled, cancelled
                assert time.monotonic() - cancelled_at < 10, 'Native cancellation did not stop promptly'
                call('delete_export', blocked_key)
                timeout_request = dict(blocked, limits={'timeout_seconds': 1}, idempotency_key=str(uuid.uuid4()))
                timed_key, timed = wait(call('export_query', timeout_request))
                assert timed['status'] == 'failed' and timed['error']['code'] == 'OPERATION_TIMEOUT' and 'artifact' not in timed, timed
                call('delete_export', timed_key)
            finally:
                # KILL only the lock-holder belonging to this disposable fixture.
                ids = docker('exec', name, 'mysql', '-uroot', '-Nse',
                    "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO='SELECT SLEEP(60)'")
                for connection in ids.splitlines():
                    docker('exec', name, 'mysql', '-uroot', '-e', 'KILL ' + str(int(connection)))
                blocker.wait(timeout=10)
            print('PASS native blocked-query cancellation and total timeout', flush=True)
            (args.output / 'summary.json').write_text(json.dumps(summary, indent=2))
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
        subprocess.run(['docker', 'rm', '-fv', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
