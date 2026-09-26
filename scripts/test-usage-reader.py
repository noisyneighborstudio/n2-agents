#!/usr/bin/env python3
"""Exercise provider parsing without credentials or network access."""
import contextlib
import io
import sqlite3
import importlib.util
from pathlib import Path
import unittest
import os
import json
import tempfile
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("n2_usage", Path(__file__).resolve().parents[1] / "usage.py")
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)

class ReaderTests(unittest.TestCase):
    def test_success_and_failure_are_retained_with_original_times(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.dict(os.environ, {'N2_USAGE_ROOT': root, 'N2_USAGE_ORIGIN': 'fixture-peer'}), \
                 patch.object(u.sys, 'argv', ['usage.py', 'codex', 'Default=/fixture']), \
                 patch.object(u, 'codex', return_value=('ok', lambda: {'rate_limit': {'primary_window': {'used_percent': 12, 'limit_window_seconds': 18000}}})), \
                 contextlib.redirect_stdout(io.StringIO()):
                u.main()
            with patch.dict(os.environ, {'N2_USAGE_ROOT': root, 'N2_USAGE_ORIGIN': 'fixture-peer'}), \
                 patch.object(u.sys, 'argv', ['usage.py', 'codex', 'Default=/fixture']), \
                 patch.object(u, 'codex', side_effect=ValueError('synthetic')), \
                 contextlib.redirect_stdout(io.StringIO()):
                u.main()
            with sqlite3.connect(Path(root) / '.usage/events.sqlite') as db:
                events = [json.loads(row[0]) for row in db.execute('SELECT body FROM events ORDER BY at')]
            self.assertEqual([event['data']['status'] for event in events], ['ok', 'fetch-error'])
            self.assertEqual(events[0]['data']['windows'][0]['usedPercent'], 12)
            self.assertEqual(events[1]['data']['windows'], [])
            self.assertLessEqual(events[0]['at'], events[1]['at'])

    def test_live_output_respects_durable_rejection_and_journal_failure(self):
        import subprocess
        with tempfile.TemporaryDirectory() as root:
            subprocess.run(['python3', str(Path(__file__).resolve().parents[1] / 'usage-store.py'),
                            '--root', root, '--origin', 'fixture-peer', 'record', '--provider', 'codex',
                            '--profile', 'Default', '--kind', 'quota-rejected', '--data', '{"status":"restricted"}'],
                           check=True, capture_output=True)
            def read():
                output = io.StringIO()
                with patch.dict(os.environ, {'N2_USAGE_ROOT': root, 'N2_USAGE_ORIGIN': 'fixture-peer', 'N2_USAGE_FORMAT': 'json'}), \
                     patch.object(u.sys, 'argv', ['usage.py', 'codex', 'Default=/fixture']), \
                     patch.object(u, 'codex', return_value=('ok', lambda: {'rate_limit': {'primary_window': {'used_percent': 12, 'limit_window_seconds': 18000}}})), \
                     contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                    u.main()
                return json.loads(output.getvalue())
            result = read()
            self.assertEqual(result['status'], 'restricted')
            self.assertTrue(any(r['reason'] == 'quota-rejected' for r in result['restrictions']))
            database = Path(root) / '.usage/events.sqlite'
            database.rename(database.with_suffix('.saved'))
            database.symlink_to(database.with_suffix('.saved'))
            self.assertEqual(read()['status'], 'fetch-error', 'unreadable rejection state cannot advertise capacity')

    def test_native_workspace_identity_separates_users_and_workspaces(self):
        response = {'_native': True, 'account': {'email': 'one@example.invalid'},
                    'workspaceRouting': {'chatgptAccountId': 'workspace-one', 'backendOrigin': 'https://chatgpt.com'}}
        first = u.details('codex', response)['identity']
        self.assertEqual(first['status'], 'verified')
        response['workspaceRouting']['chatgptAccountId'] = 'workspace-two'
        self.assertNotEqual(first['accountHash'], u.details('codex', response)['identity']['accountHash'])
        response['workspaceRouting']['chatgptAccountId'] = 'workspace-one'
        response['account']['email'] = 'two@example.invalid'
        self.assertNotEqual(first['accountHash'], u.details('codex', response)['identity']['accountHash'])
        response['workspaceRouting'] = None
        self.assertEqual(u.details('codex', response)['identity']['status'], 'login-only')

    def test_claude_identity_uses_literal_route_and_provider_status(self):
        payload = {'loggedIn': True, 'authMethod': 'claude.ai', 'apiProvider': 'firstParty',
                   'email': 'fixture@example.invalid', 'orgId': 'fixture-org'}
        with patch.object(u.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(payload))) as run:
            identity = u.claude_identity('/literal/symlink/path')
        self.assertEqual(run.call_args.kwargs['env']['CLAUDE_CONFIG_DIR'], '/literal/symlink/path')
        self.assertEqual(identity['status'], 'verified')
        self.assertNotIn('fixture@example.invalid', json.dumps(identity))
        payload['authMethod'] = 'api_key'
        with patch.object(u.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(payload))):
            self.assertEqual(u.claude_identity('/fixture')['status'], 'conflicting')

    def test_claude_switch_between_token_and_identity_is_refused(self):
        with patch.object(u, 'claude_creds', side_effect=[({'accessToken': 'first'}, 'ok'), ({'accessToken': 'second'}, 'ok')]), \
             patch.object(u, 'claude_identity', return_value={'status': 'verified', 'accountHash': 'b' * 64}):
            status, request = u.claude('Default', '/fixture')
        self.assertEqual(status, 'fetch-error')
        self.assertIsNone(request)

    def test_weekly_only(self):
        row = u.codex_row({"rate_limit": {"primary_window": {
            "used_percent": 72, "limit_window_seconds": 604800, "reset_at": 1790411072}}})
        self.assertEqual(row, ('-', 72, '-', '2026-09-26T08:24'))

    def test_missing_muse_windows(self):
        self.assertEqual(u.muse_row({"is_subs_active": True}), ('-', '-', '-', '-'))

    def test_native_multiple_buckets_and_arbitrary_durations(self):
        response = {'_native': True, 'rateLimitsByLimitId': {
            'codex': {'primary': {'usedPercent': 25, 'windowDurationMins': 15, 'resetsAt': 1790411072}},
            'premium': {'secondary': {'usedPercent': 100, 'windowDurationMins': 10080},
                        'rateLimitReachedType': 'weeklyLimit'}}}
        measured = u.details('codex', response)
        self.assertEqual([w['durationSeconds'] for w in measured['windows']], [900, 604800])
        self.assertEqual(measured['restrictions'], [{'scope': 'premium', 'reason': 'weeklyLimit'}])
        self.assertEqual(u.codex_row(response)[:2], ('-', 100))

    def test_rejection_without_windows_survives(self):
        measured = u.details('codex', {'rate_limit': {'allowed': False, 'limit_reached': True}})
        self.assertTrue(measured['restrictions'])
        self.assertEqual(measured['windows'], [])

    def test_claude_model_limits_and_disabled_overage(self):
        measured = u.details('claude', {'five_hour': {'utilization': 10},
            'seven_day_opus': {'utilization': 100},
            'extra_usage': {'is_enabled': False, 'spend_limit_reached': True}})
        self.assertEqual([w['usedPercent'] for w in measured['windows']], [10, 100])
        self.assertEqual(measured['restrictions'], [], 'disabled overage does not block included usage')
        self.assertTrue(measured['credits']['overage']['spend_limit_reached'])

    def test_login_identity_is_not_a_workspace_identity(self):
        measured = u.details('codex', {'_native': True, 'account': {'email': 'test@example.com'},
                                      'access_token': 'DO-NOT-EXPOSE'})
        encoded = json.dumps(measured)
        self.assertNotIn('test@example.com', encoded)
        self.assertNotIn('DO-NOT-EXPOSE', encoded)
        self.assertEqual(measured['identity']['status'], 'login-only')
        self.assertNotIn('accountId', measured['identity'])

    def test_literal_claude_path_and_no_expiry_competition(self):
        credential = {'accessToken': 'synthetic', 'expiresAt': 9999999999999}
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            with patch.object(u.subprocess, 'run', return_value=SimpleNamespace(
                    returncode=0, stdout=json.dumps({'claudeAiOauth': credential}))) as run:
                got, status = u.claude_creds(directory, True)
            self.assertEqual(status, 'ok')
            self.assertEqual(got, credential)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][3], 'Claude Code-credentials-' + u.hashlib.sha256(directory.encode()).hexdigest()[:8])

    def test_locked_keychain_is_not_logged_out(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(u.subprocess, 'run',
                return_value=SimpleNamespace(returncode=36, stdout='')):
            self.assertEqual(u.claude_creds('/missing', True), (None, 'credential-store-unavailable'))

    def test_override_prevents_wrong_profile_measurement(self):
        with patch.dict(os.environ, {'ANTHROPIC_API_KEY': 'synthetic'}, clear=True):
            self.assertEqual(u.claude_creds('/missing', True), (None, 'credential-override'))

    def test_native_protocol_and_home_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'codex'
            capture = Path(directory) / 'requests'
            binary.write_text("""#!/usr/bin/python3
import json, os, sys
for line in sys.stdin:
    request = json.loads(line)
    with open(os.environ['N2_TEST_CAPTURE'], 'a') as f:
        f.write(json.dumps({'method': request['method'], 'home': os.environ.get('CODEX_HOME')}) + '\\n')
    if 'id' not in request:
        continue
    result = {}
    if request['method'] == 'account/read':
        result = {'account': {'type': 'chatgpt', 'email': 'fixture@example.com'}, 'workspaceRouting': {'chatgptAccountId': 'fixture-workspace', 'backendOrigin': 'https://chatgpt.com'}}
        if request.get('id') == 4 and os.environ.get('N2_TEST_SWITCH'):
            result['workspaceRouting']['chatgptAccountId'] = 'changed-workspace'
    elif request['method'] == 'account/rateLimits/read':
        result = {'rateLimitsByLimitId': {'fixture': {'primary': {'usedPercent': 12, 'windowDurationMins': 15}}}}
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
""")
            binary.chmod(0o700)
            with patch.dict(os.environ, {'PATH': directory + ':/usr/bin:/bin', 'N2_TEST_CAPTURE': str(capture)}):
                response = u.codex_native(directory + '/account-home')
            self.assertEqual(u.details('codex', response)['windows'][0]['durationSeconds'], 900)
            self.assertEqual(u.details('codex', response)['identity']['status'], 'verified')
            calls = [json.loads(line) for line in capture.read_text().splitlines()]
            self.assertEqual([c['method'] for c in calls], ['initialize', 'initialized', 'account/read', 'account/rateLimits/read', 'account/read'])
            self.assertTrue(all(c['home'] == directory + '/account-home' for c in calls))
            with patch.dict(os.environ, {'PATH': directory + ':/usr/bin:/bin', 'N2_TEST_CAPTURE': str(capture), 'N2_TEST_SWITCH': '1'}):
                with self.assertRaisesRegex(RuntimeError, 'account changed'):
                    u.codex_native(directory + '/account-home')

    def test_invalid_percentage_is_unknown(self):
        for value in [float('nan'), float('inf'), -1, 101, True, '10']:
            self.assertIsNone(u.number(value))

if __name__ == '__main__':
    unittest.main()
