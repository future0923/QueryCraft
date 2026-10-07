#!/usr/bin/env python3
"""Remove obsolete QueryCraft CDHash authorizations, keeping passwords and current access."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
SERVICE = 'io.github.future0923.QueryCraft.connection-profile'


def current_hashes():
    candidates = [
        (Path('/Applications/QueryCraft.app'), 'io.github.future0923.QueryCraft'),
        (Path('/Applications/QueryCraftDev.app'), 'io.github.future0923.QueryCraft.Dev'),
        (Path.home() / 'Library/Application Support/QueryCraftCredentials/v1/QueryCraft Credentials.app',
         'io.github.future0923.QueryCraft.CredentialHelper'),
    ]
    hashes = set()
    for app, expected_id in candidates:
        if not app.exists():
            continue
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info['CFBundleIdentifier'] != expected_id:
            raise RuntimeError('Unexpected installed application identifier.')
        subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True, capture_output=True)
        result = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], check=True, capture_output=True, text=True)
        matches = re.findall(r'^CandidateCDHash \S+=([0-9a-f]{40})$', result.stderr, re.M)
        hashes.update('cdhash:' + value for value in matches)
    if not hashes:
        raise RuntimeError('No signed installed QueryCraft version found; nothing will be removed.')
    return hashes


def metadata():
    with tempfile.TemporaryDirectory(prefix='querycraft-acl-') as directory:
        executable = Path(directory) / 'read-metadata'
        subprocess.run(['swiftc', '-suppress-warnings', str(ROOT / 'scripts/keychain-authorization-metadata.swift'),
                        '-o', str(executable)], check=True)
        result = subprocess.run([str(executable)], check=True, capture_output=True)
    return json.loads(result.stdout)


def plan(rows, hashes):
    changes = []
    for row in rows:
        account = str(uuid.UUID(row['account'])).upper()
        previous = row['partitions']
        # Do not lock out an older-only credential or introduce new authorizations.
        if not hashes.intersection(previous):
            continue
        kept = [value for value in previous if not value.startswith('cdhash:') or value in hashes]
        if previous != kept and kept:
            changes.append(dict(account=account, before=previous, after=kept))
    return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Apply the displayed scoped cleanup; macOS requests authentication locally.')
    args = parser.parse_args()
    hashes = current_hashes()
    rows = metadata()
    if len({row['account'] for row in rows}) != len(rows):
        raise RuntimeError('检测到重复凭据账号；为避免改动其他钥匙串，未执行清理。')
    changes = plan(rows, hashes)
    removed = sum(len(row['before']) - len(row['after']) for row in changes)
    print(f'将清理 {len(changes)} 条凭据中的 {removed} 条旧版本授权。数据库密码不会被读取或删除。', flush=True)
    old_only = sum(any(value.startswith('cdhash:') for value in row['partitions'])
                   and not hashes.intersection(row['partitions']) for row in rows)
    if old_only:
        print(f'另有 {old_only} 条凭据尚无当前版本授权，暂时保留；用新版本打开对应连接后可再次清理。', flush=True)
    if not args.apply or not changes:
        return
    if not os.isatty(0):
        raise RuntimeError('请在本机终端执行；钥匙串密码只能在本机终端的安全提示中输入。')
    backup_dir = ROOT / '.build/keychain-auth-backups' / (datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8])
    backup_dir.mkdir(parents=True, mode=0o700)
    backup = backup_dir / 'authorization-metadata.json'
    with os.fdopen(os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'w') as file:
        json.dump(dict(service=SERVICE, changes=changes), file, indent=2)
    print('授权元数据备份：' + str(backup), flush=True)
    print('如提示密码，请输入“登录”钥匙串密码（通常是 Mac 登录密码）；输入时不会显示。', flush=True)
    completed = 0
    for row in changes:
        # No -k: security prompts securely; the password never enters argv or our Python process.
        subprocess.run(['/usr/bin/security', 'set-generic-password-partition-list',
                        '-s', SERVICE, '-a', row['account'], '-S', ','.join(row['after'])],
                       check=True, stdout=subprocess.DEVNULL)
        completed += 1
        print(f'已清理 {completed}/{len(changes)} 条凭据的旧授权。', flush=True)
    remaining = plan(metadata(), hashes)
    if remaining:
        raise RuntimeError('仍有旧授权未清理，请保留备份并查看终端错误。')
    print('清理完成。当前版本授权和保存的数据库密码均保留。', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
