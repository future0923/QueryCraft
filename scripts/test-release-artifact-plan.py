#!/usr/bin/env python3
"""Exercise partial-run recovery, immutable source matching and publication gates."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('artifacts', ROOT / 'scripts/ci/release-artifact-plan.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
DRIVERS = ['mysql', 'postgresql', 'doris']
COMPLETE = {'querycraft-release-client-' + arch for arch in ['x86_64', 'arm64', 'update']}
COMPLETE |= {f'querycraft-release-driver-{kind}-{arch}' for kind in DRIVERS for arch in ['x86_64', 'arm64']}


class ArtifactPlanTests(unittest.TestCase):
    def test_fresh_release_builds_two_clients_update_and_only_selected_drivers(self):
        result = MODULE.plan(set(), DRIVERS, True)
        self.assertEqual(len(result['client_build_matrix']), 2)
        self.assertEqual(len(result['driver_build_matrix']), 6)
        self.assertTrue(result['build_update'])
        self.assertEqual({row['database'] for row in result['driver_build_matrix']}, set(DRIVERS))

    def test_observed_failed_run_builds_only_three_missing_artifacts(self):
        missing = {'querycraft-release-client-x86_64', 'querycraft-release-driver-doris-x86_64',
                   'querycraft-release-driver-postgresql-x86_64'}
        result = MODULE.plan(COMPLETE - missing, DRIVERS, True)
        self.assertEqual([row['architecture'] for row in result['client_build_matrix']], ['x86_64'])
        self.assertEqual([(row['database'], row['architecture']) for row in result['driver_build_matrix']],
                         [('postgresql', 'x86_64'), ('doris', 'x86_64')])
        self.assertFalse(result['build_update'])

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
        self.assertIn('run-id: ${{ needs.metadata.outputs.source_run_id }}', runtime)
        self.assertIn("has_new_artifacts == 'true'", runtime)
        publish = workflow.split('\n  publish:', 1)[1]
        self.assertIn("needs.verify_runtime.result == 'success'", publish)
        new_downloads = publish.split('name: Download newly completed artifacts', 1)[1].split('name: Publish selected resources', 1)[0]
        self.assertIn('pattern: querycraft-release-*', new_downloads)


if __name__ == '__main__':
    unittest.main()
