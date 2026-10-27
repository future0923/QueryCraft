#!/usr/bin/env python3
"""All existing MobileRedis suites on a physical device and an owned LAN Redis."""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid

p = argparse.ArgumentParser()
p.add_argument('--device-id', required=True)
p.add_argument('--host', required=True)
p.add_argument('--team-id', required=True)
p.add_argument('--image', default='redis:7.4.2')
p.add_argument('--expect-field-ttl', required=True, choices=['0', '1'])
p.add_argument('--output-dir', required=True)
p.add_argument('--derived-data-path', required=True)
p.add_argument('--suite', action='append', help='Limit a repair recheck to named Redis suites; default runs all')
a = p.parse_args()
if not ipaddress.ip_address(a.host).is_private:
    p.error('Use a private LAN address')
root = Path(__file__).resolve().parents[1]
out = root / a.output_dir
out.mkdir(parents=True, exist_ok=True)
docker = shutil.which('docker')
if not docker:
    p.error('Docker is required')
owner = str(uuid.uuid4())
name = 'qc-redis-physical-' + uuid.uuid4().hex[:12]
label_key = 'querycraft.redis.physical.acceptance'
created = False
removed = False
try:
    subprocess.run([docker, 'run', '--detach', '--rm', '--name', name, '--label', label_key + '=' + owner,
        '--publish', a.host + '::6379', a.image], check=True, stdout=subprocess.DEVNULL)
    created = True
    rq = [docker, 'exec', name, 'redis-cli', '--raw']
    for attempt in range(100):
        if subprocess.run(rq + ['PING'], capture_output=True, text=True).stdout.strip() == 'PONG':
            break
        time.sleep(.2)
    else:
        raise RuntimeError('Redis fixture did not become ready')
    port = subprocess.check_output([docker, 'port', name, '6379/tcp'], text=True).strip().rsplit(':', 1)[1]
    info = subprocess.check_output(rq + ['INFO', 'server'], text=True)
    version = next(l.split(':', 1)[1].strip() for l in info.splitlines() if l.startswith('redis_version:'))
    capability = json.loads(subprocess.check_output([docker, 'exec', name, 'redis-cli', '--json', 'COMMAND', 'INFO', 'HPTTL'], text=True))
    supports_ttl = bool(capability and capability[0] is not None)
    assert supports_ttl == (a.expect_field_ttl == '1'), ('Unexpected field-TTL capability', version)
    suites = sorted({m for f in (root / 'QueryCraftMobile/Tests').glob('MobileRedis*Tests.swift')
        for m in re.findall(r'\b(?:struct|class)\s+(MobileRedis\w+Tests)\b', f.read_text())})
    declarations = sum(len(re.findall(r'@Test(?:\(|\s)', f.read_text())) +
        len(re.findall(r'\bfunc\s+test\w+\s*\(', f.read_text()))
        for f in (root / 'QueryCraftMobile/Tests').glob('MobileRedis*Tests.swift'))
    all_suites = suites
    if a.suite:
        assert set(a.suite) <= set(suites), 'Unknown Redis suite'
        suites = sorted(set(a.suite))
    env = {'PROOF_SERVER_HOST': a.host, 'PROOF_REDIS_PORT': port,
        'PROOF_REDIS_FIELD_TTL': a.expect_field_ttl,
        'QUERYCRAFT_PHYSICAL_REDIS_ACCEPTANCE': '1', 'QUERYCRAFT_PHYSICAL_REDIS_OWNER': owner,
        'QUERYCRAFT_PHYSICAL_REDIS_HOST': a.host, 'QUERYCRAFT_PHYSICAL_REDIS_PORT': port}
    metadata = {'owner': owner, 'device': a.device_id, 'image': a.image, 'serverVersion': version,
        'fieldTTL': supports_ttl, 'suites': suites, 'allRedisSuites': suites == all_suites,
        'testDeclarations': declarations if suites == all_suites else None}
    (out / 'scope.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('READY Redis', version, 'field TTL:', supports_ttl, 'suites:', len(suites), flush=True)
    command = ['xcodebuildmcp', 'device', 'test', '--project-path', str(root / 'QueryCraftMobile/QueryCraftMobile.xcodeproj'),
        '--scheme', 'QueryCraftMobileProof', '--device-id', a.device_id, '--derived-data-path', a.derived_data_path,
        '--output', 'json', '--json', json.dumps({'testRunnerEnv': env}), '--extra-args', 'CODE_SIGNING_ALLOWED=YES',
        'CODE_SIGN_STYLE=Automatic', 'DEVELOPMENT_TEAM=' + a.team_id, 'CODE_SIGN_IDENTITY=Apple Development',
        '-allowProvisioningUpdates', '-parallel-testing-enabled', 'NO']
    command += ['-only-testing:QueryCraftMobileProofTests/' + suite for suite in suites]
    with (out / 'tests.json').open('w') as stream:
        run = subprocess.run(command, cwd=root, stdout=stream)
    report = json.loads((out / 'tests.json').read_text())
    summary = report.get('data', {}).get('summary', {})
    print(json.dumps(summary), flush=True)
    if run.returncode or report.get('didError') or summary.get('status') != 'SUCCEEDED':
        raise RuntimeError('Redis physical acceptance failed; inspect tests.json')
    counts = summary.get('counts', {})
    assert sum(counts.get(k, 0) for k in ['passed', 'failed', 'skipped']) >= (declarations if suites == all_suites else 1), 'Selected tests were not discovered'
    if supports_ttl:
        assert counts.get('skipped', 0) == 0, 'A Redis 7.4 test was unexpectedly skipped'
    exists = subprocess.check_output(rq + ['EXISTS', '__querycraft_ios_acceptance__:' + owner], text=True).strip()
    assert exists == '0', 'Physical UI test key remained'
    keyspace = subprocess.check_output(rq + ['INFO', 'keyspace'], text=True)
    remaining = [line for line in keyspace.splitlines() if re.match(r'db\d+:', line)]
    metadata.update(summary=summary, physicalKeyAbsent=True, remainingKeyspace=remaining)
    (out / 'verification.json').write_text(json.dumps(metadata, indent=2) + '\n')
    assert not remaining, 'Test fixture keys remained; inspect verification.json'
    print('PASS all selected Redis suites; physical owned key absent; keyspace:', remaining, flush=True)
finally:
    if created:
        state = subprocess.run([docker, 'inspect', '--format', '{{ index .Config.Labels "' + label_key + '" }}', name], capture_output=True, text=True)
        if state.returncode == 0 and state.stdout.strip() == owner:
            subprocess.run([docker, 'rm', '--force', '--volumes', name], check=True, stdout=subprocess.DEVNULL)
            removed = True
    (out / 'cleanup.json').write_text(json.dumps({'owner': owner, 'container': name, 'created': created, 'removed': removed}, indent=2) + '\n')
    if created and not removed:
        raise RuntimeError('Owned fixture cleanup was not confirmed')
