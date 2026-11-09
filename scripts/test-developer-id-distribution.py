#!/usr/bin/env python3
"""Failure-path regression gates; no Apple uploads or access to saved passwords."""
import base64
from contextlib import redirect_stderr
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


signer = module('developer_signer_test', 'developer-id-signing.py')
notary = module('notary_test', 'notarize.py')


class SigningTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, {}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)

    def test_wrong_or_missing_identity_never_falls_back(self):
        for identities in [b'', b'Apple Development: fixture', b'0 valid identities found']:
            with self.subTest(identities=identities), patch.object(signer, 'run', return_value=identities):
                with self.assertRaises(RuntimeError):
                    signer.activate()

    def test_signature_without_runtime_or_timestamp_is_rejected(self):
        for details in ['flags=0x0\nTimestamp=fixture', 'flags=0x10000(runtime)', 'flags=0x10000(runtime)\nTimestamp=none']:
            with self.subTest(details=details), patch.object(signer, 'run'), patch.object(signer.subprocess, 'run',
                return_value=subprocess.CompletedProcess([], 0, b'', details.encode())):
                with self.assertRaises(RuntimeError):
                    signer.verify(Path('fixture.app'))

    def test_apple_trust_failure_propagates(self):
        with patch.object(signer, 'run', side_effect=RuntimeError('wrong Team')):
            with self.assertRaisesRegex(RuntimeError, 'wrong Team'):
                signer.verify(Path('fixture.app'))

    def test_ci_import_cannot_run_against_local_keychain(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, 'CI import requires'):
                signer.provision(True)
            with self.assertRaisesRegex(RuntimeError, 'Cleanup is restricted'):
                signer.cleanup()

    def test_helper_renewal_uses_apple_team_and_shared_legacy_lock(self):
        source = signer.helper_source()
        self.assertNotIn('__PINNED_CERTIFICATE_SHA1__', source)
        callers = '\n'.join(line for line in source.splitlines() if line.startswith('let callerRequirement'))
        self.assertNotIn('certificate leaf = H', callers)
        self.assertIn('anchor apple generic', callers)
        self.assertIn(signer.configuration()['teamID'], callers)
        self.assertIn('deletingLastPathComponent().deletingLastPathComponent().appending(path: "vault.lock")', source)

    def test_release_excludes_legacy_hosts_and_cannot_overwrite_legacy_version(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'QUERYCRAFT_BUILD_MCP': 'true'}, clear=True):
            root = Path(temporary)
            (root/'Config').mkdir(); (root/'Components').mkdir()
            config = signer.configuration()
            config['lastLegacyAppVersion'] = '0.1.15'
            (root/'Config/DeveloperID.json').write_text(json.dumps(config))
            (root/'Config/Shared.xcconfig').write_text('MARKETING_VERSION = 0.1.15\n')
            (root/'Components/versions.json').write_text(json.dumps({'mcp': {'minimumAppVersion': '0.1.15'}}))
            with patch.object(signer, 'ROOT', root):
                with self.assertRaisesRegex(RuntimeError, 'new app version'):
                    signer.validate_release()
                (root/'Config/Shared.xcconfig').write_text('MARKETING_VERSION = 0.1.16\n')
                with self.assertRaisesRegex(RuntimeError, 'exclude legacy'):
                    signer.validate_release()
                (root/'Components/versions.json').write_text(json.dumps({'mcp': {'minimumAppVersion': '0.1.16'}}))
                signer.validate_release()


class NotarizationTests(unittest.TestCase):
    def test_transient_ticket_network_error_is_retried_without_logging_arguments(self):
        failure = subprocess.CompletedProcess([], 68, '', 'Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."')
        success = subprocess.CompletedProcess([], 0, 'Ticket validated', '')
        output = io.StringIO()
        with patch.object(notary.subprocess, 'run', side_effect=[failure, success]) as command, \
             patch.object(notary.time, 'sleep') as delay, redirect_stderr(output):
            self.assertEqual(notary.run('xcrun', 'stapler', 'validate', 'private-fixture.app'), 'Ticket validated')
        self.assertEqual(command.call_count, 2)
        delay.assert_called_once_with(5)
        self.assertNotIn('private-fixture.app', output.getvalue())

    def test_persistent_network_failure_still_fails_after_bounded_retries(self):
        failure = subprocess.CompletedProcess([], 68, '', 'Error Domain=NSURLErrorDomain Code=-1005')
        with patch.object(notary.subprocess, 'run', return_value=failure) as command, \
             patch.object(notary.time, 'sleep') as delay, redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, 'NSURLErrorDomain'):
                notary.run('xcrun', 'stapler', 'validate', 'fixture.app')
        self.assertEqual(command.call_count, 4)
        self.assertEqual([call.args[0] for call in delay.call_args_list], [5, 15, 30])

    def test_authentication_and_invalid_ticket_fail_without_retry(self):
        for args, message in [
            (('xcrun', 'notarytool', 'history'), 'HTTP status code: 401 Unauthorized'),
            (('xcrun', 'stapler', 'validate', 'fixture.app'), 'The validate action failed! Error 65. Invalid ticket')]:
            with self.subTest(message=message), patch.object(notary.subprocess, 'run',
                 return_value=subprocess.CompletedProcess([], 1, '', message)) as command, \
                 patch.object(notary.time, 'sleep') as delay:
                with self.assertRaises(RuntimeError):
                    notary.run(*args)
                self.assertEqual(command.call_count, 1)
                delay.assert_not_called()

    def test_upload_is_not_duplicated_after_ambiguous_network_failure(self):
        failure = subprocess.CompletedProcess([], 1, '', 'Error Domain=NSURLErrorDomain Code=-1005')
        with patch.object(notary.subprocess, 'run', return_value=failure) as command, \
             patch.object(notary.time, 'sleep') as delay:
            with self.assertRaises(RuntimeError):
                notary.run('xcrun', 'notarytool', 'submit', 'fixture.zip')
            self.assertEqual(command.call_count, 1)
            delay.assert_not_called()

    def test_idempotent_notary_reads_and_stapling_can_recover(self):
        for operation in [('notarytool', 'history'), ('notarytool', 'log'), ('stapler', 'staple')]:
            with self.subTest(operation=operation), patch.object(notary.subprocess, 'run', side_effect=[
                 subprocess.CompletedProcess([], 1, '', 'Error Domain=NSURLErrorDomain Code=-1001'),
                 subprocess.CompletedProcess([], 0, 'fixture', '')]) as command, \
                 patch.object(notary.time, 'sleep'), redirect_stderr(io.StringIO()):
                self.assertEqual(notary.run('xcrun', *operation), 'fixture')
                self.assertEqual(command.call_count, 2)

    def test_existing_apple_id_notarization_credentials_work_in_ci(self):
        team = signer.configuration()['teamID']
        environment = {'CI': 'true', 'QUERYCRAFT_NOTARY_APPLE_ID': 'fixture@example.invalid',
                       'QUERYCRAFT_NOTARY_APP_PASSWORD': 'fixture-password', 'QUERYCRAFT_NOTARY_TEAM_ID': team}
        with patch.dict(os.environ, environment, clear=True), notary.credentials() as args:
            self.assertEqual(args, ['--apple-id', 'fixture@example.invalid', '--password', 'fixture-password', '--team-id', team])

    def test_wrong_team_and_partial_apple_id_credentials_are_rejected(self):
        for environment in [
            {'QUERYCRAFT_NOTARY_APPLE_ID': 'fixture@example.invalid'},
            {'QUERYCRAFT_NOTARY_APPLE_ID': 'fixture@example.invalid', 'QUERYCRAFT_NOTARY_APP_PASSWORD': 'fixture',
             'QUERYCRAFT_NOTARY_TEAM_ID': 'WRONGTEAM1'}]:
            with self.subTest(environment=environment), patch.dict(os.environ, environment, clear=True):
                with self.assertRaises(RuntimeError), notary.credentials():
                    pass

    def test_missing_ci_secrets_and_partial_secrets_fail_closed(self):
        for environment in [{'CI': 'true'}, {'QUERYCRAFT_NOTARY_KEY_ID': 'fixture'}]:
            with self.subTest(environment=environment), patch.dict(os.environ, environment, clear=True):
                with self.assertRaises(RuntimeError), notary.credentials():
                    pass

    def test_private_key_is_private_and_removed(self):
        environment = {'QUERYCRAFT_NOTARY_KEY_ID': 'fixture', 'QUERYCRAFT_NOTARY_ISSUER_ID': 'fixture',
                       'QUERYCRAFT_NOTARY_PRIVATE_KEY_BASE64': base64.b64encode(b'fixture').decode()}
        with patch.dict(os.environ, environment, clear=True):
            with notary.credentials() as args:
                key = Path(args[1])
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                self.assertEqual(key.read_bytes(), b'fixture')
            self.assertFalse(key.exists())

    def exercise(self, status, suffix='.app', fail=None):
        calls = []
        def run(*args):
            calls.append(args)
            if args[1:3] == ('notarytool', 'submit'):
                if fail:
                    raise RuntimeError(fail)
                return json.dumps({'id': 'fixture-id', 'status': status})
            if args[1:3] == ('notarytool', 'log'):
                return json.dumps({'status': status})
            return ''
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=True), patch.object(notary, 'run', side_effect=run):
            path = Path(temporary) / ('fixture' + suffix)
            path.mkdir() if suffix == '.app' else path.touch()
            if status != 'Accepted' or fail:
                with self.assertRaises(RuntimeError):
                    notary.notarize(path)
            else:
                notary.notarize(path)
        return calls

    def test_rejection_and_timeout_never_staple_or_assess(self):
        for status, fail in [('Invalid', None), ('In Progress', None), ('Accepted', 'timeout')]:
            calls = self.exercise(status, fail=fail)
            self.assertFalse(any('stapler' in call or call[0] == 'spctl' for call in calls))

    def test_accepted_app_and_dmg_require_staple_validate_and_gatekeeper(self):
        for suffix in ['.app', '.dmg']:
            calls = self.exercise('Accepted', suffix)
            self.assertTrue(any(call[1:3] == ('stapler', 'staple') for call in calls))
            self.assertTrue(any(call[1:3] == ('stapler', 'validate') for call in calls))
            self.assertTrue(any(call[0] == 'spctl' for call in calls))

    def test_plugin_zip_has_no_unsupported_staple(self):
        calls = self.exercise('Accepted', '.zip')
        self.assertTrue(any(call[1:3] == ('notarytool', 'log') for call in calls))
        self.assertFalse(any('stapler' in call for call in calls))


if __name__ == '__main__':
    unittest.main()
