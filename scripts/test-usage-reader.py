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

    def test_reserve_is_policy_not_provider_rejection(self):
        fixtures = [
            ('claude', {'five_hour': {'utilization': 20}, 'seven_day_opus': {'utilization': 96}}),
            ('codex', {'_native': True, 'rateLimitsByLimitId': {
                'custom': {'primary': {'usedPercent': 96, 'windowDurationMins': 15}}}}),
        ]
        for vendor, data in fixtures:
            with self.subTest(vendor=vendor), tempfile.TemporaryDirectory() as root:
                def read(fmt):
                    output = io.StringIO()
                    with patch.dict(os.environ, {'N2_USAGE_ROOT': root, 'N2_USAGE_ORIGIN': 'fixture-peer', 'N2_USAGE_FORMAT': fmt}), \
                         patch.object(u.sys, 'argv', ['usage.py', vendor, 'Default=/fixture']), \
                         patch.object(u, vendor, return_value=('ok', lambda: data)), contextlib.redirect_stdout(output):
                        u.main()
                    return output.getvalue()
                measured = json.loads(read('json'))
                self.assertEqual(measured['status'], 'ok')
                self.assertEqual(measured['restrictions'], [])
                self.assertEqual(max(w['usedPercent'] for w in measured['windows']), 96)
                self.assertEqual(read('tsv').strip().split('\t')[4], 'local-reserve')
                with sqlite3.connect(Path(root) / '.usage/events.sqlite') as db:
                    events = [json.loads(row[0]) for row in db.execute('SELECT body FROM events')]
                self.assertTrue(all(event['data']['status'] == 'ok' for event in events))
                self.assertTrue(all(event['data']['restrictions'] == [] for event in events))

    def test_incomplete_model_bucket_cannot_hide_behind_healthy_general_window(self):
        for fmt in ('json', 'tsv'):
            output = io.StringIO()
            with tempfile.TemporaryDirectory() as root, \
                 patch.dict(os.environ, {'N2_USAGE_ROOT': root, 'N2_USAGE_FORMAT': fmt}), \
                 patch.object(u.sys, 'argv', ['usage.py', 'claude', 'Default=/fixture']), \
                 patch.object(u, 'claude', return_value=('ok', lambda: {
                     'five_hour': {'utilization': 20}, 'seven_day_opus': {'utilization': 'unreadable'}})), \
                 contextlib.redirect_stdout(output):
                u.main()
            status = json.loads(output.getvalue())['status'] if fmt == 'json' else output.getvalue().strip().split('\t')[4]
            self.assertEqual(status, 'fetch-error')

    def test_malformed_limit_containers_are_not_silently_dropped(self):
        fixtures = [
            ('claude', {'five_hour': {'utilization': 20}, 'seven_day_opus': 'malformed'}),
            ('codex', {'_native': True, 'rateLimitsByLimitId': {
                'normal': {'primary': {'usedPercent': 20, 'windowDurationMins': 300}}, 'model': 'malformed'}}),
            ('codex', {'_native': True, 'rateLimitsByLimitId': 'malformed',
                       'rateLimits': {'primary': {'usedPercent': 20}}}),
            ('codex', {'rate_limit': {'primary_window': {'used_percent': 20}}, 'additional_rate_limits': ['malformed']}),
        ]
        for malformed in (False, 0, "", {}):
            fixtures.append(('codex', {'rate_limit': {'primary_window': {'used_percent': 20}},
                                      'additional_rate_limits': malformed}))
        for malformed in (False, 0, ""):
            fixtures.append(('codex', {'rate_limit': malformed, 'additional_rate_limits': [
                {'limit_name': 'healthy', 'primary_window': {'used_percent': 20}}]}))
            fixtures.append(('codex', {'rate_limit': {'primary_window': {'used_percent': 20}},
                'additional_rate_limits': [{'limit_name': 'model', 'rate_limit': malformed}]}))
            fixtures.append(('codex', {'_native': True, 'rateLimits': malformed}))
        for vendor, data in fixtures:
            for fmt in ('json', 'tsv'):
                output = io.StringIO()
                with tempfile.TemporaryDirectory() as root, \
                     patch.dict(os.environ, {'N2_USAGE_ROOT': root, 'N2_USAGE_FORMAT': fmt}), \
                     patch.object(u.sys, 'argv', ['usage.py', vendor, 'Default=/fixture']), \
                     patch.object(u, vendor, return_value=('ok', lambda: data)), contextlib.redirect_stdout(output):
                    u.main()
                status = json.loads(output.getvalue())['status'] if fmt == 'json' else output.getvalue().strip().split('\t')[4]
                self.assertEqual(status, 'fetch-error', (vendor, fmt))
        self.assertEqual(len(u.details('claude', {'five_hour': {'utilization': 20}, 'seven_day_opus': None})['windows']), 1)

    def test_provider_rejection_does_not_fabricate_full_utilization(self):
        data = {'rate_limit': {'limit_reached': True, 'primary_window': {
            'used_percent': 20, 'limit_window_seconds': 604800}}}
        self.assertEqual(u.codex_row(data)[1], 20)
        self.assertTrue(u.details('codex', data)['restrictions'])

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
        self.assertEqual(identity['status'], 'login-only')
        self.assertNotIn('accountHash', identity, 'cached organization cannot establish account ownership')
        self.assertNotIn('organizationHash', identity)
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

    def test_authenticated_claude_identity_uses_stable_account_and_organization(self):
        profile = {'account': {'uuid': '11111111-1111-4111-8111-111111111111', 'email': 'one@example.invalid'},
                   'organization': {'uuid': '22222222-2222-4222-8222-222222222222'}}
        identity = u.claude_account_identity(profile)
        self.assertEqual(identity['status'], 'verified')
        profile['account']['email'] = 'renamed@example.invalid'
        self.assertEqual(identity, u.claude_account_identity(profile))
        profile['account']['uuid'] = '33333333-3333-4333-8333-333333333333'
        self.assertNotEqual(identity['accountHash'], u.claude_account_identity(profile)['accountHash'])
        profile['account']['uuid'] = '11111111-1111-4111-8111-111111111111'
        profile['organization']['uuid'] = '44444444-4444-4444-8444-444444444444'
        self.assertNotEqual(identity['accountHash'], u.claude_account_identity(profile)['accountHash'])
        self.assertNotIn('example.invalid', json.dumps(identity))
        for malformed in ({}, {'account': None}, {'account': {'uuid': 'cached-name'}, 'organization': {}},
                          {'account': {'uuid': True}, 'organization': {'uuid': []}}):
            self.assertEqual(u.claude_account_identity(malformed), {'status': 'unavailable'})

    def test_claude_profile_and_allowance_share_captured_bearer(self):
        profile = {'account': {'uuid': '11111111-1111-4111-8111-111111111111'},
                   'organization': {'uuid': '22222222-2222-4222-8222-222222222222'}}
        credential = {'accessToken': 'synthetic-bearer'}
        with patch.object(u, 'claude_creds', return_value=(credential, 'ok')), \
             patch.object(u, 'claude_identity', return_value={'status': 'login-only', 'loginHash': 'a' * 64}), \
             patch.object(u, 'claude_oauth_read', side_effect=[profile, {'five_hour': {'utilization': 25}}]) as read:
            status, fetch = u.claude('Default', '/fixture')
            result = fetch()
        self.assertEqual(status, 'ok')
        self.assertEqual(read.call_args_list[0].args, ('profile', 'synthetic-bearer'))
        self.assertEqual(read.call_args_list[1].args, ('usage', 'synthetic-bearer'))
        self.assertEqual(result['_identity'], u.claude_account_identity(profile))
        self.assertNotIn('synthetic-bearer', json.dumps(result))
        self.assertNotIn('11111111-1111', json.dumps(result))

    def test_claude_profile_failure_preserves_usage_without_claiming_identity(self):
        for failure in (OSError('network'), ValueError('malformed'),
                        u.urllib.error.HTTPError('https://api.anthropic.com', 403, 'denied', {}, None)):
            with self.subTest(failure=type(failure).__name__), \
                 patch.object(u, 'claude_creds', return_value=({'accessToken': 'synthetic'}, 'ok')), \
                 patch.object(u, 'claude_identity', return_value={'status': 'login-only', 'loginHash': 'a' * 64}), \
                 patch.object(u, 'claude_oauth_read', side_effect=[failure, {'five_hour': {'utilization': 25}}]):
                _, fetch = u.claude('Default', '/fixture')
                result = fetch()
                self.assertEqual(result['five_hour']['utilization'], 25)
                self.assertEqual(result['_identity'], {'status': 'unavailable'})

    def test_claude_switch_during_network_read_invalidates_measurement(self):
        with patch.object(u, 'claude_creds', side_effect=[({'accessToken': 'first'}, 'ok'),
                    ({'accessToken': 'first'}, 'ok'), ({'accessToken': 'second'}, 'ok')]), \
             patch.object(u, 'claude_identity', return_value={'status': 'unknown'}), \
             patch.object(u, 'claude_oauth_read', side_effect=[{}, {'five_hour': {'utilization': 25}}]):
            _, fetch = u.claude('Default', '/fixture')
            with self.assertRaisesRegex(ValueError, 'credentials changed'):
                fetch()

    def test_claude_unreadable_cli_route_prevents_headroom(self):
        with patch.object(u, 'claude_creds', return_value=({'accessToken': 'synthetic'}, 'ok')), \
             patch.object(u, 'claude_identity', return_value={'status': 'unavailable'}):
            self.assertEqual(u.claude('Default', '/fixture'), ('fetch-error', None))

    def test_claude_custom_base_does_not_measure_first_party_allowance(self):
        with patch.dict(os.environ, {'ANTHROPIC_BASE_URL': 'https://gateway.example.invalid'}, clear=True):
            self.assertEqual(u.claude_creds('/fixture', True), (None, 'credential-override'))

    def test_claude_oauth_transport_bounds_and_redirects(self):
        with patch.object(u.urllib.request, 'build_opener') as build:
            build.return_value.open.return_value = io.BytesIO(b'{"ok":true}')
            self.assertEqual(u.claude_oauth_read('profile', 'synthetic'), {'ok': True})
            request = build.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, 'https://api.anthropic.com/api/oauth/profile')
            self.assertEqual(request.get_header('Authorization'), 'Bearer synthetic')
            handler = build.call_args.args[0]
            for target in ('https://api.anthropic.com/other', 'https://other.example.invalid', 'http://api.anthropic.com'):
                self.assertIsNone(handler.redirect_request(request, None, 302, 'moved', {}, target))
            build.return_value.open.return_value = io.BytesIO(b' ' * 1048577)
            with self.assertRaisesRegex(ValueError, 'too large'):
                u.claude_oauth_read('usage', 'synthetic')
            with self.assertRaisesRegex(ValueError, 'unsupported'):
                u.claude_oauth_read('../other', 'synthetic')

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
account_reads = 0
for line in sys.stdin:
    request = json.loads(line)
    with open(os.environ['N2_TEST_CAPTURE'], 'a') as f:
        f.write(json.dumps({'method': request['method'], 'home': os.environ.get('CODEX_HOME')}) + '\\n')
    if 'id' not in request:
        continue
    result = {}
    if request['method'] == 'config/read':
        result = {'config': {}}
    if request['method'] == 'account/read':
        account_reads += 1
        result = {'account': {'type': 'chatgpt', 'email': 'fixture@example.com'}, 'workspaceRouting': {'chatgptAccountId': 'fixture-workspace', 'backendOrigin': 'https://chatgpt.com'}}
        if account_reads == 2 and os.environ.get('N2_TEST_SWITCH'):
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
            self.assertEqual([c['method'] for c in calls], ['initialize', 'initialized', 'config/read', 'account/read', 'account/rateLimits/read', 'account/read', 'config/read'])
            self.assertTrue(all(c['home'] == directory + '/account-home' for c in calls))
            with patch.dict(os.environ, {'PATH': directory + ':/usr/bin:/bin', 'N2_TEST_CAPTURE': str(capture), 'N2_TEST_SWITCH': '1'}):
                with self.assertRaisesRegex(RuntimeError, 'account changed'):
                    u.codex_native(directory + '/account-home')

    def test_invalid_percentage_is_unknown(self):
        for value in [float('nan'), float('inf'), -1, 101, True, '10']:
            self.assertIsNone(u.number(value))

if __name__ == '__main__':
    unittest.main()
