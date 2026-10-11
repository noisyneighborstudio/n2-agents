#!/usr/bin/env python3
"""Long-lived Claude tokens: capture, storage, allowance. No network."""
import importlib.util, json, os, stat, tempfile, unittest
from pathlib import Path
from unittest.mock import patch

repo = Path(__file__).resolve().parents[1]
def load(name, file):
    spec = importlib.util.spec_from_file_location(name, repo / file)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
t = load('n2_claude_token', 'claude-token.py')
u = load('n2_usage', 'usage.py')

TOKEN = 'sk-ant-oat01-' + 'Ab3_-xY9' * 11 + 'Zq3wA' + 'AA'
ORG = '00000000-0000-4000-8000-000000000001'
HEADERS = json.loads((repo / 'tests/fixtures/claude-token-headers.json').read_text())

class Slot:
    def __enter__(self):
        self.dir = tempfile.TemporaryDirectory(); return self.dir.name
    def __exit__(self, *a): self.dir.cleanup()

def login(cfg, org=ORG, email='me@example.com'):
    Path(cfg, '.claude.json').write_text(json.dumps({'oauthAccount': {'organizationUuid': org, 'emailAddress': email}}))

class TokenTests(unittest.TestCase):
    def test_fixture_token_has_the_real_shape(self):
        self.assertEqual(len(TOKEN), 108)
        self.assertTrue(t.SHAPE.fullmatch(TOKEN))

    def test_capture_rejoins_a_token_the_tui_wrapped_and_styled(self):
        wrapped = TOKEN[:40] + '\r\n  ' + TOKEN[40:85] + '\x1b[0m\r\n  ' + TOKEN[85:]
        transcript = ('\x1b[2J\x1b[?25l✓ Long-lived authentication token created successfully!\r\n'
                      '\x1b[1mYour OAuth token (valid for 1 year):\x1b[22m\r\n  \x1b[33m' + wrapped +
                      '\x1b[39m\r\n\r\nStore this token securely.\r\n')
        self.assertEqual(t.capture(transcript), TOKEN)

    def test_capture_takes_the_last_full_token_and_refuses_partial_ones(self):
        other = TOKEN[:-3] + 'zAA'
        self.assertEqual(t.capture(TOKEN + '\n' + other + '\n'), other)
        self.assertIsNone(t.capture(TOKEN[:-5] + '\nStore this token'))
        self.assertIsNone(t.capture('CLAUDE_CONFIG_DIR=/x\n'))

    def test_store_keeps_other_settings_private_and_clears_cleanly(self):
        with Slot() as cfg:
            Path(cfg, 'settings.json').write_text(json.dumps({'model': 'opus', 'env': {'FOO': '1'}}))
            t.write(cfg, TOKEN)
            self.assertEqual(t.read(cfg), TOKEN)
            self.assertEqual(stat.S_IMODE(os.stat(Path(cfg, 'settings.json')).st_mode), 0o600)
            t.write(cfg, None)
            self.assertEqual(json.loads(Path(cfg, 'settings.json').read_text()), {'model': 'opus', 'env': {'FOO': '1'}})
            t.write(cfg, TOKEN); Path(cfg, 'settings.json').write_text(json.dumps({'env': {t.KEY: TOKEN}}))
            t.write(cfg, None)
            self.assertEqual(json.loads(Path(cfg, 'settings.json').read_text()), {})

    def test_read_ignores_anything_that_is_not_a_token(self):
        with Slot() as cfg:
            for env in ({t.KEY: 'sk-ant-api03-x'}, {t.KEY: 7}, []):
                Path(cfg, 'settings.json').write_text(json.dumps({'env': env}))
                self.assertIsNone(t.read(cfg))

    def test_headers_become_usage_windows(self):
        result = t.from_headers(HEADERS)
        self.assertEqual(result['_organization'], ORG)
        self.assertEqual(result['five_hour'], {'utilization': 0.0, 'resets_at': '2026-10-11T17:40:00+00:00'})
        self.assertEqual(result['seven_day']['utilization'], 59.0)
        windows = u.details('claude', {k: v for k, v in result.items() if k != '_organization'})['windows']
        self.assertEqual([(w['scope'], w['usedPercent']) for w in windows], [('five_hour', 0.0), ('seven_day', 59.0)])

    def capture_verb(self, cfg, org):
        Path(cfg, 'out').write_text('Your OAuth token:\n' + TOKEN + '\n')
        with patch.object(t, 'organization', return_value=org), patch.object(t.sys, 'argv', ['x', 'capture', cfg, str(Path(cfg, 'out'))]):
            t.main()

    def test_capture_saves_only_a_token_for_the_signed_in_organization(self):
        with Slot() as cfg:
            login(cfg)
            with self.assertRaises(SystemExit) as refused:
                self.capture_verb(cfg, '00000000-0000-4000-8000-000000000002')
            self.assertIn('different account', str(refused.exception.code))
            self.assertIsNone(t.read(cfg))
            self.capture_verb(cfg, ORG)
            self.assertEqual(t.read(cfg), TOKEN)

    def test_usage_reads_a_token_slot_from_headers_with_its_identity(self):
        with Slot() as cfg:
            login(cfg); t.write(cfg, TOKEN)
            with patch.object(t, 'allowance', side_effect=lambda token: t.from_headers(HEADERS)), \
                 patch.object(u, 'claude_token_module', return_value=t), \
                 patch.object(u, 'claude_creds', side_effect=AssertionError('refreshable login read')):
                status, read = u.claude('Work', cfg)
                self.assertEqual(status, 'ok')
                self.assertEqual(read()['_identity']['status'], 'login-only')
                login(cfg, org='00000000-0000-4000-8000-000000000002')
                self.assertEqual(read()['_identity'], {'status': 'conflicting'})

    def test_an_inherited_token_neither_overrides_measurement_nor_reaches_the_provider(self):
        with patch.dict(os.environ, {t.KEY: TOKEN, 'USER': 'n2'}):
            self.assertNotIn(t.KEY, u.claude_env('/slot'))
            self.assertEqual(u.claude_env('/slot')['CLAUDE_CONFIG_DIR'], '/slot')

if __name__ == '__main__':
    unittest.main()
