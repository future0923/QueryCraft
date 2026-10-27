#!/usr/bin/env python3
"""Plan missing release builds and validate the provenance of reusable artifacts."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request

ARCHITECTURES = [('x86_64', 'macos-15-intel'), ('arm64', 'macos-15')]
DRIVERS = {'mysql', 'postgresql', 'doris', 'redis', 'elasticsearch', 'kafka'}
# A failed, unpublished SSH packaging repair may retain driver artifacts only
# when every other tracked input (including the workflow) is byte-identical.
SSH_REPAIR_PATHS = {
    'scripts/build-ssh-plugin.py',
    'scripts/ci/release-artifact-plan.py',
    'scripts/test-release-artifact-plan.py',
    'scripts/test-ssh-distribution.py',
    'docs/RELEASE_PROCESS.md',
}


def plan(available, drivers, publish_drivers, rebuild_driver='none'):
    clients = [dict(architecture=arch, runner=runner) for arch, runner in ARCHITECTURES
               if f'querycraft-release-client-{arch}-v2' not in available]
    update = bool(clients) or 'querycraft-release-client-update-v2' not in available
    driver_builds = [dict(database=driver, architecture=arch, runner=runner)
                     for driver in drivers for arch, runner in ARCHITECTURES
                     if publish_drivers and (driver == rebuild_driver
                         or f'querycraft-release-driver-{driver}-{arch}' not in available)]
    return dict(client_build_matrix=clients, driver_build_matrix=driver_builds,
                build_update=update, has_new_artifacts=bool(clients or update or driver_builds))


def validate_source(run, expected_commit):
    if run['head_sha'] != expected_commit:
        raise ValueError('Source artifacts belong to a different release commit')
    if run['status'] != 'completed':
        raise ValueError('Source run must finish before its artifacts can be reused')
    if run['path'] != '.github/workflows/release.yml':
        raise ValueError('Source run is not the release workflow')


def validate_driver_recovery(run, expected_commit, available, repository='.'):
    validate_source(run, run['head_sha'])
    if run.get('conclusion') not in {'failure', 'cancelled', 'timed_out'}:
        raise ValueError('Only a failed or cancelled release can use SSH repair recovery')
    valid_names = {f'querycraft-release-driver-{driver}-{arch}'
                   for driver in DRIVERS for arch, _ in ARCHITECTURES}
    if not available or not available <= valid_names:
        raise ValueError('SSH repair recovery accepts only driver artifacts; clients must be rebuilt')
    original = run['head_sha']
    if subprocess.run(['git', 'merge-base', '--is-ancestor', original, expected_commit],
                      cwd=repository, check=False).returncode:
        raise ValueError('SSH repair must descend from the failed release commit')
    changed = set(subprocess.check_output(
        ['git', 'diff', '--name-only', '--no-renames', '-z', original, expected_commit],
        cwd=repository).decode().strip('\0').split('\0'))
    if 'scripts/build-ssh-plugin.py' not in changed or not changed <= SSH_REPAIR_PATHS:
        raise ValueError('Driver build inputs changed; cached driver artifacts cannot be reused')


def require_unpublished(get, tag):
    try:
        get('/releases/tags/' + tag)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return
        raise
    raise ValueError('SSH repair recovery cannot replace an existing GitHub release')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--drivers', required=True)
    parser.add_argument('--publish-drivers', choices=['true', 'false'], required=True)
    parser.add_argument('--source-run', default='')
    parser.add_argument('--rebuild-driver', default='none')
    parser.add_argument('--github-output', type=Path, required=True)
    args = parser.parse_args()
    drivers = json.loads(args.drivers)
    if not isinstance(drivers, list) or any(driver not in DRIVERS for driver in drivers):
        raise ValueError('Invalid driver selection')
    available = set()
    build_ref = os.environ['GITHUB_SHA']
    if args.source_run:
        if not args.source_run.isdigit():
            raise ValueError('Source run ID must be numeric')
        tag = 'v' + args.version
        build_ref = subprocess.check_output(['git', 'rev-parse', tag + '^{commit}'], text=True).strip()
        if subprocess.run(['git', 'cat-file', '-e', tag + ':scripts/update-archives.py'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            raise ValueError('Legacy ZIP release: recover using the workflow from that release tag')
        config = subprocess.check_output(['git', 'show', tag + ':Config/Shared.xcconfig'], text=True)
        for key, expected in [('MARKETING_VERSION', args.version), ('CURRENT_PROJECT_VERSION', args.build)]:
            if not re.search(r'^' + key + r' = ' + re.escape(expected) + r'$', config, re.M):
                raise ValueError('Source release identity differs from requested version/build')
        api = 'https://api.github.com/repos/' + os.environ['GITHUB_REPOSITORY']
        headers = {'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json'}

        def get(path):
            with urllib.request.urlopen(urllib.request.Request(api + path, headers=headers), timeout=60) as response:
                return json.load(response)

        run = get('/actions/runs/' + args.source_run)
        page = 1
        while True:
            records = get(f'/actions/runs/{args.source_run}/artifacts?per_page=100&page={page}')['artifacts']
            available.update(item['name'] for item in records if not item['expired'] and item['size_in_bytes'] > 0)
            if len(records) < 100:
                break
            page += 1
        if run['head_sha'] == build_ref:
            validate_source(run, build_ref)
        else:
            require_unpublished(get, tag)
            validate_driver_recovery(run, build_ref, available)
            print('Verified SSH-only repair: all driver build inputs and identities are unchanged; rebuilding all clients.')
    result = plan(available, drivers, args.publish_drivers == 'true', args.rebuild_driver)
    result['build_ref'] = build_ref
    with args.github_output.open('a') as output:
        for key, value in result.items():
            encoded = json.dumps(value, separators=(',', ':')) if not isinstance(value, str) else value
            output.write(key + '=' + encoded + '\n')
    print(json.dumps(dict(source_run=args.source_run, reused=sorted(available), **result), indent=2))


if __name__ == '__main__':
    main()
