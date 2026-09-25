#!/usr/bin/env python3
"""Exercise provider parsing without credentials or network access."""
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
        result = {'account': {'type': 'chatgpt', 'email': 'fixture@example.com'}}
    elif request['method'] == 'account/rateLimits/read':
        result = {'rateLimitsByLimitId': {'fixture': {'primary': {'usedPercent': 12, 'windowDurationMins': 15}}}}
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
""")
            binary.chmod(0o700)
            with patch.dict(os.environ, {'PATH': directory + ':/usr/bin:/bin', 'N2_TEST_CAPTURE': str(capture)}):
                response = u.codex_native(directory + '/account-home')
            self.assertEqual(u.details('codex', response)['windows'][0]['durationSeconds'], 900)
            calls = [json.loads(line) for line in capture.read_text().splitlines()]
            self.assertEqual([c['method'] for c in calls], ['initialize', 'initialized', 'account/read', 'account/rateLimits/read'])
            self.assertTrue(all(c['home'] == directory + '/account-home' for c in calls))

    def test_invalid_percentage_is_unknown(self):
        for value in [float('nan'), float('inf'), -1, 101, True, '10']:
            self.assertIsNone(u.number(value))

if __name__ == '__main__':
    unittest.main()
