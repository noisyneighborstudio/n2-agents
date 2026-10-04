#!/usr/bin/env python3
"""busybar.py against a fake BUSY Bar: alert cards, the switch, clearing and failures."""
import http.server
import importlib.util
import io
import json
import os
import socket
import stat
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('busybar', ROOT / 'busybar.py')
busybar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(busybar)
busybar.FRAME_MS = 0  # the schedule is the device's frame rate, not behavior under test


class FakeBar(http.server.BaseHTTPRequestHandler):
    requests = []
    reply = 200

    def handle_any(self):
        body = self.rfile.read(int(self.headers.get('Content-Length') or 0))
        FakeBar.requests.append((self.command, self.path, dict(self.headers), body))
        payload = b'{"api_semver":"27.5.0"}' if self.path.endswith('/version') else b'{}'
        self.send_response(FakeBar.reply)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_DELETE = handle_any

    def log_message(self, *args):
        pass


class BusyBarTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeBar)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.address = '127.0.0.1:%d' % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        self.root = tempfile.mkdtemp()
        FakeBar.requests = []
        FakeBar.reply = 200

    def run_cli(self, *args, stdin=''):
        out = io.StringIO()
        old = sys.stdin
        sys.stdin = io.StringIO(stdin)
        try:
            with redirect_stdout(out):
                code = busybar.main(['--root', self.root, *args])
        finally:
            sys.stdin = old
        self.assertEqual(code, 0)
        return dict(line.split('\t', 1) for line in out.getvalue().splitlines())

    def turn_on(self, *extra, stdin=''):
        status = self.run_cli('on', '--address', self.address, *extra, stdin=stdin)
        FakeBar.requests = []
        return status

    def draws(self):
        return [json.loads(body) for method, path, _, body in FakeBar.requests
                if method == 'POST' and path.endswith('/display/draw')]

    def test_each_kind_maps_to_its_card(self):
        expected = {'half': ('50% LEFT', '#2979FFFF', 60), 'quarter': ('25% LEFT', '#FFD600FF', 60),
                    'low': ('10% LEFT', '#FFAB00FF', 120), 'out': ('OUT', '#FF1744FF', 0),
                    'signedout': ('SIGNED OUT', '#FF1744FF', 0), 'back': ('BACK', '#00C853FF', 60)}
        self.assertEqual(set(busybar.KINDS), set(expected))
        for kind, (word, color, timeout) in expected.items():
            card = busybar.make_card(kind, 'Work - Claude Code')
            self.assertEqual((card['label'], card['color'], card['timeout']), (word, color, timeout))

    def test_titles_are_printable_ascii(self):
        self.assertEqual(busybar.device_text('Work – Codex, back Mon 3:40 PM 🚀'), 'Work Codex, back Mon 3:40 PM')

    def test_endpoints(self):
        usb = busybar.endpoint('', '')
        self.assertEqual((usb['base'], usb['headers'], usb['connection']), ('http://10.0.4.20/api', {}, 'usb'))
        lan = busybar.endpoint('192.168.1.40', 'pw')
        self.assertEqual((lan['base'], lan['headers'], lan['connection']),
                         ('http://192.168.1.40/api', {'X-API-Token': 'pw'}, 'wifi'))
        cloud = busybar.endpoint('api.busy.app', 'tok')
        self.assertEqual((cloud['base'], cloud['headers'], cloud['connection']),
                         ('https://api.busy.app/busybar', {'Authorization': 'Bearer tok'}, 'cloud'))

    def test_every_moving_element_mounts_first_in_z_order(self):
        frames = busybar.intro_frames(busybar.make_card('low', 'x'))
        mounted = [e['id'] for e in frames[0]]
        later = {e['id'] for frame in frames[1:] for e in frame}
        self.assertTrue(later <= set(mounted), later - set(mounted))
        z = [e['z_index'] for e in frames[0]]
        self.assertEqual(z, sorted(z))

    def test_off_sends_nothing(self):
        self.run_cli('alert', 'out', 'Work - Codex', '--key', 'Work|codex')
        self.assertEqual(FakeBar.requests, [])

    def test_on_plays_hello_and_keeps_the_secret_private(self):
        status = self.run_cli('on', '--address', self.address, '--token-stdin', stdin='pw\n')
        self.assertEqual((status['enabled'], status['state'], status['token'], status['api']),
                         ('on', 'connected', 'set', '27.5.0'))
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.root, 'busybar.json')).st_mode), 0o600)
        self.assertEqual(self.draws()[-1]['elements'][1]['text'], 'CONNECTED')
        self.assertTrue(all({k.lower(): v for k, v in h.items()}.get('x-api-token') == 'pw' for _, _, h, _ in FakeBar.requests))

    def test_alert_sequence_clears_first_and_ends_on_the_card(self):
        self.turn_on()
        self.run_cli('alert', 'low', 'Work - Codex', '--key', 'Work|codex')
        first, upload = FakeBar.requests[0], FakeBar.requests[1]
        self.assertEqual((first[0], json.loads(first[3])), ('DELETE', {'application_name': 'n2agents'}))
        self.assertIn('/assets/upload?application_name=n2agents&file=logo.png', upload[1])
        self.assertTrue(upload[3].startswith(b'\x89PNG'))
        card = self.draws()[-1]
        self.assertEqual(card['led_notification_color'], '#FFAB00FF')
        self.assertEqual([(e['id'], e['timeout']) for e in card['elements']],
                         [('logo', 120), ('label', 120), ('title', 120)])
        self.assertEqual(card['elements'][2]['text'], 'Work - Codex')

    def test_a_persistent_card_clears_only_for_its_own_slot(self):
        self.turn_on()
        self.run_cli('alert', 'signedout', 'Work - Codex', '--key', 'Work|codex')
        FakeBar.requests = []
        self.run_cli('clear', 'Home|claude')
        self.assertEqual(FakeBar.requests, [])
        self.run_cli('clear', 'Work|codex')
        self.assertEqual([r[0] for r in FakeBar.requests], ['DELETE'])
        FakeBar.requests = []
        self.run_cli('clear', 'Work|codex')
        self.assertEqual(FakeBar.requests, [])

    def test_a_timed_card_replaces_the_persistent_one(self):
        self.turn_on()
        self.run_cli('alert', 'out', 'Work - Codex', '--key', 'Work|codex')
        self.run_cli('alert', 'back', 'Work - Codex', '--key', 'Work|codex')
        FakeBar.requests = []
        self.run_cli('clear', 'Work|codex')
        self.assertEqual(FakeBar.requests, [])

    def test_unreachable_bar_is_logged_and_the_caller_carries_on(self):
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            closed = '127.0.0.1:%d' % s.getsockname()[1]
        status = self.run_cli('on', '--address', closed)
        self.assertEqual(status['state'], 'unreachable')
        self.run_cli('alert', 'out', 'Work - Codex', '--key', 'Work|codex')
        log = Path(self.root, 'busybar.log').read_text()
        self.assertIn('hello failed', log)
        self.assertIn('alert out failed', log)

    def test_a_rejected_secret_reads_unauthorized(self):
        self.turn_on()
        FakeBar.reply = 401
        self.assertEqual(self.run_cli('status')['state'], 'unauthorized')

    def test_off_clears_the_bar(self):
        self.turn_on()
        status = self.run_cli('off')
        self.assertEqual(status['enabled'], 'off')
        self.assertEqual(FakeBar.requests[0][0], 'DELETE')


if __name__ == '__main__':
    unittest.main()
