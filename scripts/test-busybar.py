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
    unplugged = False

    def handle_any(self):
        body = self.rfile.read(int(self.headers.get('Content-Length') or 0))
        if FakeBar.unplugged:  # the connection drops with no reply
            self.close_connection = True
            return
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
        FakeBar.unplugged = False

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
                    'signedout': ('SIGNED OUT', '#FF1744FF', 0), 'back': ('BACK', '#00C853FF', 60),
                    'update': ('UPDATE', '#FFD600FF', 60)}
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
        self.assertNotIn('alert out failed', log, 'one line per outage, not one per alert')

    def log(self):
        return Path(self.root, 'busybar.log').read_text().splitlines()

    def test_a_card_missed_while_unplugged_goes_up_on_reconnect(self):
        self.turn_on()
        FakeBar.unplugged = True
        self.run_cli('alert', 'out', 'Work - Codex', '--key', 'Work|codex')
        self.run_cli('sync')
        self.run_cli('sync')
        self.assertEqual([l.split(' ', 1)[1].split(':')[0] for l in self.log()], ['alert out failed', 'unreachable'])
        FakeBar.unplugged = False
        self.run_cli('sync')
        self.assertTrue(self.log()[-1].endswith(' reconnected'))
        card = self.draws()[-1]
        self.assertEqual((card['elements'][1]['text'], card['elements'][1]['timeout'], card['led_notification_color']),
                         ('OUT', 0, '#FF1744FF'))
        FakeBar.requests = []
        self.run_cli('sync')
        self.assertEqual([(m, p) for m, p, _, _ in FakeBar.requests], [('GET', '/api/version')], 'nothing to redo')

    def age_card(self, seconds):
        path = Path(self.root, 'busybar.state')
        state = json.loads(path.read_text())
        state['card']['at'] -= seconds
        path.write_text(json.dumps(state))

    def test_a_timed_card_comes_back_for_what_is_left_of_its_time(self):
        self.turn_on()
        FakeBar.unplugged = True
        self.run_cli('alert', 'low', 'Work - Codex', '--key', 'Work|codex')
        self.age_card(100)
        FakeBar.unplugged = False
        self.run_cli('sync')
        self.assertEqual(self.draws()[-1]['elements'][0]['timeout'], 20)

    def test_a_card_that_ran_out_while_away_is_cleared_not_replayed(self):
        self.turn_on()
        FakeBar.unplugged = True
        self.run_cli('alert', 'low', 'Work - Codex', '--key', 'Work|codex')
        self.age_card(130)
        FakeBar.unplugged = False
        FakeBar.requests = []
        self.run_cli('sync')
        self.assertEqual([m for m, _, _, _ in FakeBar.requests], ['GET', 'DELETE'])

    def test_signing_in_while_unplugged_leaves_nothing_to_restore(self):
        self.turn_on()
        FakeBar.unplugged = True
        self.run_cli('alert', 'signedout', 'Home - Claude Code', '--key', 'Home|claude')
        self.run_cli('clear', 'Home|claude')
        FakeBar.unplugged = False
        FakeBar.requests = []
        self.run_cli('sync')
        self.assertEqual([m for m, _, _, _ in FakeBar.requests], ['GET', 'DELETE'], 'the stale card is cleared')

    def test_sync_does_nothing_while_off(self):
        self.run_cli('sync')
        self.assertEqual(FakeBar.requests, [])

    def test_a_rejected_secret_reads_unauthorized(self):
        self.turn_on()
        FakeBar.reply = 401
        self.assertEqual(self.run_cli('status')['state'], 'unauthorized')

    def test_off_clears_the_bar(self):
        self.turn_on()
        status = self.run_cli('off')
        self.assertEqual(status['enabled'], 'off')
        self.assertEqual(FakeBar.requests[0][0], 'DELETE')


    SLIDES = json.dumps([{'title': 'Work - Claude Code', 'left': 82}, {'title': 'Home - Codex', 'left': 0}])

    def test_gauge_fills_in_proportion(self):
        def cells(fraction):
            body = busybar.gauge(fraction, '#00C853FF').splitlines()[5:]
            return sum(r.count('f') for r in body), sum(r.count('t') for r in body)
        empty, half, full = cells(0), cells(0.5), cells(1)
        self.assertEqual(empty[0], 0)
        self.assertEqual(full[1], 0)
        self.assertAlmostEqual(half[0] / sum(half), 0.5, delta=0.05)
        self.assertTrue(busybar.gauge(0.3, '#2979FFFF').startswith('! XPM2\n16 16 3 1\n. c none\nt c #303030\nf c #2979FF'))

    def test_gauge_colors_follow_the_alert_tiers(self):
        self.assertEqual([busybar.tone(n) for n in (100, 51, 50, 26, 25, 11, 10, 1, 0)],
                         ['#00C853FF', '#00C853FF', '#2979FFFF', '#2979FFFF', '#FFD600FF', '#FFD600FF',
                          '#FFAB00FF', '#FFAB00FF', '#FF1744FF'])

    def test_slideshow_does_nothing_while_off(self):
        self.run_cli('slideshow', stdin=self.SLIDES)
        self.assertEqual(FakeBar.requests, [])

    def test_slideshow_counts_each_slot_up_then_clears(self):
        self.turn_on()
        self.run_cli('slideshow', stdin=self.SLIDES)
        figures = [e['text'] for d in self.draws() for e in d['elements'] if e['id'] == 'figure']
        self.assertEqual(figures[0], '0%')
        self.assertIn('82%', figures)
        self.assertEqual(figures[-1], '0%')
        self.assertEqual(max(int(f[:-1]) for f in figures), 82)
        self.assertTrue(all(e['timeout'] == 5 for d in self.draws() for e in d['elements']), 'stray slides go on their own')
        self.assertEqual(FakeBar.requests[-1][0], 'DELETE')

    def test_slideshow_puts_a_standing_card_back_without_its_intro(self):
        self.turn_on()
        self.run_cli('alert', 'out', 'Work - Codex', '--key', 'Work|codex')
        FakeBar.requests = []
        self.run_cli('slideshow', stdin=self.SLIDES)
        last = self.draws()[-1]
        self.assertEqual(([e['id'] for e in last['elements']], last['led_notification_color']),
                         (['logo', 'label', 'title'], '#FF1744FF'))
        self.assertFalse(any(e['id'] == 'edge-l' for d in self.draws() for e in d['elements']), 'no intro replay')


if __name__ == '__main__':
    unittest.main()
