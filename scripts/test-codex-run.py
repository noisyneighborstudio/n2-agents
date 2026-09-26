#!/usr/bin/env python3
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bound', ROOT / 'codex-run.py')
bound = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bound)
ACCOUNT = hashlib.sha256(json.dumps(['codex', 'https://chatgpt.com', 'workspace', 'fixture@example.invalid'], separators=(',', ':')).encode()).hexdigest()

class BoundTurnTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'canonical'; self.home.mkdir()
        (self.home / 'auth.json').write_text(json.dumps({'tokens': {'access_token': 'synthetic-private-token', 'account_id': 'workspace'}}))
        (self.home / 'config.toml').write_text('model = "fixture-model"\n')
        (self.home / 'AGENTS.md').write_text('Preserve these instructions.\n')
        (self.home / 'AGENTS.override.md').write_text('Override instructions.\n')
        (self.home / 'skills').mkdir()
        (self.home / 'skills' / 'fixture.md').write_text('Resource retained.')
        self.binary = self.root / 'codex'
        self.binary.write_bytes((ROOT / 'tests/fake-bound-codex.py').read_bytes()); self.binary.chmod(0o700)
        self.trace = self.root / 'trace'
        self.original = (self.home / 'auth.json').read_bytes()

    def run_turn(self, mode='', expected=ACCOUNT):
        output = io.StringIO()
        with patch.dict(os.environ, {'N2_BOUND_FIXTURE': mode, 'N2_BOUND_TRACE': str(self.trace)}), contextlib.redirect_stdout(output):
            code = bound.run(str(self.home), expected, 'medium', 'Synthetic prompt', executable=str(self.binary), timeout=4)
        self.assertEqual((self.home / 'auth.json').read_bytes(), self.original)
        self.assertNotIn('synthetic-private-token', output.getvalue())
        return code, [json.loads(line) for line in output.getvalue().splitlines()]

    def test_success_is_bound_to_session_and_counts(self):
        code, rows = self.run_turn()
        self.assertEqual(code, 0)
        receipt = rows[-1]
        self.assertEqual(receipt['identity']['accountHash'], ACCOUNT)
        self.assertEqual(receipt['session'], 'thread-fixture')
        self.assertEqual(receipt['tokens']['totalTokens'], 60)
        self.assertEqual(rows[1]['item']['text'], 'Bound answer')
        trace = [json.loads(x) for x in self.trace.read_text().splitlines()]
        self.assertEqual(sum(x['method'] == 'turn/start' for x in trace), 1)
        for row in trace:
            self.assertNotEqual(row['home'], str(self.home))
            self.assertFalse(Path(row['home']).exists())
            self.assertIn('cli_auth_credentials_store="ephemeral"', row['args'])

    def test_quota_failure_keeps_account_receipt(self):
        code, rows = self.run_turn('quota')
        self.assertEqual(code, 1)
        self.assertEqual(rows[-1]['identity']['accountHash'], ACCOUNT)
        self.assertIn('usage limit', rows[-2]['error']['message'])
        self.assertNotIn('not copied', json.dumps(rows))

    def test_quota_reset_survives_without_raw_error_text(self):
        before = time.time()
        code, rows = self.run_turn('quota-reset')
        self.assertEqual(code, 1)
        message = rows[-2]['error']['message']
        stamp = message.split('Try again at ')[1]
        reset = bound.datetime.datetime.fromisoformat(stamp).timestamp()
        self.assertAlmostEqual(rows[-1]['quotaResetAt'], reset, delta=0.000001)
        self.assertGreaterEqual(reset, before + 180)
        self.assertLessEqual(reset, time.time() + 180)
        self.assertNotIn('not copied', json.dumps(rows))
        _, ambiguous = self.run_turn('quota-ambiguous')
        self.assertNotIn('Try again', ambiguous[-2]['error']['message'])
        self.assertIsNone(ambiguous[-1]['quotaResetAt'])

    def test_reset_parser_rejects_ambiguous_or_unrelated_evidence(self):
        rpc = bound.load('reset_test_rpc', 'codex-rpc.py')
        now = 1800000000
        def parse(message, code='usageLimitExceeded'):
            return rpc.reported_quota_reset({'message': message, 'codexErrorInfo': code}, now)
        self.assertEqual(parse('Quota. Try again in 3 minutes.'), now + 180)
        stamp = bound.datetime.datetime.fromtimestamp(now + 120, bound.datetime.timezone.utc).isoformat()
        self.assertEqual(parse('Quota. Try again at ' + stamp), now + 120)
        for phrase in ('in 3 minutes and 10 seconds', 'in 3 minutes or contact support',
                       'at Sep 26th, 2026 11:20 AM', 'in 0 seconds', 'in 99999999 hours',
                       'at 2020-01-01T00:00:00Z', 'at 2028-02-30T00:00:00Z',
                       'at 2027-01-15T08:02:00', 'at 2027-01-15T09:42:00+00:99',
                       'at 2027-01-15T06:24:00-00:99', 'at 2027-01-15T08:03:00-00:00', 'in 3 minutes.\nUnrelated text',
                       'in 1 hour. Try again in 2 hours'):
            self.assertIsNone(parse('Quota. Try again ' + phrase), phrase)
        self.assertIsNone(parse('Try again in 3 minutes', 'unauthorized'))
        self.assertIsNone(parse('Try again in 3 minutes', {'httpStatusCode': 429}))

    def test_changed_selection_never_starts_thread(self):
        with self.assertRaisesRegex(RuntimeError, 'selected Codex account changed'):
            self.run_turn(expected='a' * 64)
        self.assertNotIn('thread/start', self.trace.read_text())

    def test_wrong_execution_configuration_never_starts_turn(self):
        for mode in ('wrong-provider', 'wrong-sandbox'):
            self.trace.write_text('')
            with self.assertRaises(RuntimeError): self.run_turn(mode)
            self.assertNotIn('turn/start', self.trace.read_text())

    def test_auth_transitions_approvals_and_bad_counts_never_issue_receipt(self):
        for mode in ('refresh', 'account-change', 'approval', 'bad-tokens'):
            with self.assertRaises((RuntimeError, ValueError)): self.run_turn(mode)

    def test_rerouted_models_do_not_misattribute_all_tokens(self):
        _, rows = self.run_turn('rerouted')
        self.assertIsNone(rows[-1]['model'])

    def test_selected_config_resources_preserved_without_auth_link(self):
        target = self.root / 'shadow'; target.mkdir()
        bound.prepare_home(self.home, target)
        self.assertEqual((target / 'config.toml').read_bytes(), (self.home / 'config.toml').read_bytes())
        self.assertEqual((target / 'AGENTS.md').read_bytes(), (self.home / 'AGENTS.md').read_bytes())
        self.assertEqual((target / 'skills' / 'fixture.md').read_text(), 'Resource retained.')
        self.assertEqual((target / 'AGENTS.override.md').read_text(), 'Override instructions.\n')
        self.assertFalse((target / 'auth.json').exists())
        self.assertEqual((target / 'config.toml').stat().st_mode & 0o777, 0o600)

    def test_agents_command_resolves_profile_and_emits_bound_receipt(self):
        root = self.root / 'profiles'
        profile = root / 'Test'; profile.mkdir(parents=True)
        (profile / 'codex').symlink_to(self.home, target_is_directory=True)
        env = dict(os.environ, N2_AGENTS_ROOT=str(root), N2_BOUND_TRACE=str(self.trace),
                   N2_BOUND_FIXTURE='', PATH=str(self.root) + os.pathsep + os.environ['PATH'])
        result = subprocess.run([str(ROOT / 'agents'), 'run', 'Test', '--vendor', 'codex',
                                 '--bound-account', ACCOUNT, '--bound-effort', 'low'],
                                input='Synthetic prompt', capture_output=True, text=True, env=env, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1])['identity']['accountHash'], ACCOUNT)
        self.assertEqual((self.home / 'auth.json').read_bytes(), self.original)

    def test_term_reaps_detached_provider(self):
        started = self.root / 'started'
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'],
                   N2_BOUND_FIXTURE='slow', N2_BOUND_TRACE=str(self.trace), N2_BOUND_STARTED=str(started))
        process = subprocess.Popen([sys.executable, str(ROOT / 'codex-run.py'), '--config', str(self.home),
                                    '--expected-account', ACCOUNT], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        try:
            process.stdin.write(b'prompt'); process.stdin.close()
            deadline = time.monotonic() + 8
            while not started.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(started.exists())
            child = int(started.read_text())
            process.terminate(); process.wait(timeout=5)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM)
            with self.assertRaises(ProcessLookupError): os.kill(child, 0)
            self.assertNotIn(b'n2.account.binding', process.stdout.read())
        finally:
            if process.poll() is None: process.kill(); process.wait()
            process.stdout.close()

if __name__ == '__main__':
    import sys
    unittest.main()
