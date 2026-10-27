#!/usr/bin/env python3
"""Exercise partial-run recovery, immutable source matching and publication gates."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
import urllib.error

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('artifacts', ROOT / 'scripts/ci/release-artifact-plan.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
DRIVERS = ['mysql', 'postgresql', 'doris']
COMPLETE = {'querycraft-release-client-' + arch + '-v2' for arch in ['x86_64', 'arm64', 'update']}
COMPLETE |= {f'querycraft-release-driver-{kind}-{arch}' for kind in DRIVERS for arch in ['x86_64', 'arm64']}


class ArtifactPlanTests(unittest.TestCase):
    def test_fresh_release_builds_two_clients_update_and_only_selected_drivers(self):
        result = MODULE.plan(set(), DRIVERS, True)
        self.assertEqual(len(result['client_build_matrix']), 2)
        self.assertEqual(len(result['driver_build_matrix']), 6)
        self.assertTrue(result['build_update'])
        self.assertEqual({row['database'] for row in result['driver_build_matrix']}, set(DRIVERS))

    def test_failed_run_builds_missing_binaries_and_reassembles_update(self):
        missing = {'querycraft-release-client-x86_64-v2', 'querycraft-release-driver-doris-x86_64',
                   'querycraft-release-driver-postgresql-x86_64'}
        result = MODULE.plan(COMPLETE - missing, DRIVERS, True)
        self.assertEqual([row['architecture'] for row in result['client_build_matrix']], ['x86_64'])
        self.assertEqual([(row['database'], row['architecture']) for row in result['driver_build_matrix']],
                         [('postgresql', 'x86_64'), ('doris', 'x86_64')])
        self.assertTrue(result['build_update'])

    def test_legacy_zip_cache_cannot_satisfy_architecture_xz_release(self):
        legacy = {'querycraft-release-client-' + arch for arch in ('x86_64', 'arm64', 'update')}
        result = MODULE.plan(legacy, [], False)
        self.assertEqual({row['architecture'] for row in result['client_build_matrix']}, {'x86_64', 'arm64'})
        self.assertTrue(result['build_update'])

    def test_complete_source_does_not_rebuild_any_artifact(self):
        result = MODULE.plan(COMPLETE, DRIVERS, True)
        self.assertFalse(result['has_new_artifacts'])
        self.assertFalse(result['build_update'])
        self.assertEqual(result['client_build_matrix'], [])
        self.assertEqual(result['driver_build_matrix'], [])

    def test_driver_publication_disabled_never_builds_drivers(self):
        self.assertEqual(MODULE.plan(set(), DRIVERS, False)['driver_build_matrix'], [])

    def test_explicit_driver_rebuild_preserves_both_architectures(self):
        result = MODULE.plan(COMPLETE, ['postgresql'], True, 'postgresql')
        self.assertEqual({row['architecture'] for row in result['driver_build_matrix']}, {'x86_64', 'arm64'})
        self.assertEqual(result['client_build_matrix'], [])

    def test_other_release_commit_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'different release commit'):
            MODULE.validate_source(dict(head_sha='other'), 'release')

    def test_incomplete_or_unrelated_source_is_rejected(self):
        for changes in [dict(status='in_progress'), dict(path='.github/workflows/ci.yml')]:
            run = dict(head_sha='release', status='completed', path='.github/workflows/release.yml')
            run.update(changes)
            with self.assertRaises(ValueError):
                MODULE.validate_source(run, 'release')

    def test_failed_release_with_matching_source_is_reusable(self):
        MODULE.validate_source(dict(head_sha='release', status='completed', conclusion='failure',
                                    path='.github/workflows/release.yml'), 'release')

    def test_workflow_rechecks_cached_runtime_and_downloads_new_clients(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        runtime = workflow.split('\n  verify_runtime:', 1)[1].split('\n  publish:', 1)[0]
        self.assertNotIn("source_run_id == ''", runtime)
        self.assertIn('ref: ${{ needs.metadata.outputs.build_ref }}', runtime)
        self.assertIn('test-ssh-package.py --directory runtime-artifacts', runtime)
        self.assertIn('run-id: ${{ needs.metadata.outputs.source_run_id }}', runtime)
        self.assertIn("has_new_artifacts == 'true'", runtime)
        publish = workflow.split('\n  publish:', 1)[1]
        self.assertIn("needs.verify_runtime.result == 'success'", publish)
        new_downloads = publish.split('name: Download newly completed artifacts', 1)[1].split('name: Publish selected resources', 1)[0]
        self.assertIn('pattern: querycraft-release-*', new_downloads)


class SSHRepairRecoveryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Recovery test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.write('scripts/build-ssh-plugin.py', 'original')
        self.original = self.commit()
        self.write('scripts/build-ssh-plugin.py', 'fixed header search')
        self.repaired = self.commit()
        self.run = dict(head_sha=self.original, status='completed', conclusion='failure',
                        path='.github/workflows/release.yml')
        self.available = {'querycraft-release-driver-mysql-arm64'}

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, stderr=subprocess.STDOUT, text=True).strip()

    def write(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def validate(self, revision=None, available=None, **changes):
        MODULE.validate_driver_recovery(dict(self.run, **changes), revision or self.repaired,
                                        self.available if available is None else available, self.repo)

    def test_ssh_only_repair_reuses_drivers_but_builds_all_clients(self):
        self.validate()
        plan = MODULE.plan(self.available, ['mysql'], True)
        self.assertEqual(len(plan['client_build_matrix']), 2)
        self.assertEqual([row['architecture'] for row in plan['driver_build_matrix']], ['x86_64'])
        self.assertTrue(plan['build_update'])

    def test_any_other_build_input_change_rejects_reuse(self):
        for path in ['.github/workflows/release.yml', 'Config/Shared.xcconfig',
                     'QueryCraftPackage/Package.swift', 'QueryCraftPackage/Package.resolved',
                     'QueryCraftPackage/Sources/QueryCraftFeature/DriverAPI.swift',
                     'QueryCraftDrivers/MySQL/driver.swift', 'QueryCraftDrivers/MariaDBTransport/transport.swift',
                     'scripts/ci/build-release-artifacts.sh', 'scripts/driver-package-common.sh',
                     'Components/versions.json']:
            with self.subTest(path=path):
                self.git('reset', '--hard', self.repaired)
                self.write(path, 'changed build input')
                revision = self.commit()
                with self.assertRaisesRegex(ValueError, 'Driver build inputs changed'):
                    self.validate(revision)

    def test_client_update_unknown_or_empty_artifacts_are_rejected(self):
        for available in [set(), self.available | COMPLETE, {'querycraft-release-driver-unknown-arm64'},
                          self.available | {'querycraft-release-client-update-v2'}]:
            with self.subTest(available=available), self.assertRaisesRegex(ValueError, 'only driver artifacts'):
                self.validate(available=available)

    def test_successful_incomplete_and_unrelated_runs_are_rejected(self):
        for changes in [dict(conclusion='success'), dict(status='in_progress'),
                        dict(path='.github/workflows/ci.yml')]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.validate(**changes)

    def test_non_descendant_revision_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'descend'):
            self.validate(self.original, head_sha=self.repaired)

    def test_existing_release_even_draft_is_rejected(self):
        for release in [dict(draft=False), dict(draft=True)]:
            with self.assertRaisesRegex(ValueError, 'existing GitHub release'):
                MODULE.require_unpublished(lambda path: release, 'v0.1.13')

    def test_only_authoritative_not_found_allows_unpublished_recovery(self):
        def get(code):
            def request(path):
                raise urllib.error.HTTPError(path, code, 'fixture', {}, None)
            return request
        MODULE.require_unpublished(get(404), 'v0.1.13')
        for code in [401, 403, 500]:
            with self.assertRaises(urllib.error.HTTPError):
                MODULE.require_unpublished(get(code), 'v0.1.13')


if __name__ == '__main__':
    unittest.main()
