#!/usr/bin/env python3
"""Real CLI ranking with disposable profiles and a local synthetic usage server."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import subprocess
import tempfile
import threading

repo = Path(__file__).resolve().parents[1]
class Handler(BaseHTTPRequestHandler):
    measured = 80
    def log_message(self, *args):
        pass
    def do_GET(self):
        value = self.measured if self.headers.get('ChatGPT-Account-Id') == 'measured' else None
        window = {'limit_window_seconds': 604800}
        if value is not None:
            window['used_percent'] = value
        payload = json.dumps({'rate_limit': {'primary_window': window}}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(payload)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
try:
    with tempfile.TemporaryDirectory(prefix='n2-ranking-') as tmp:
        root = Path(tmp); home = root / 'home'; bins = root / 'bin'
        home.mkdir(); bins.mkdir()
        profiles = home / '.n2-agents'
        for profile, identity in [('AUnknown', 'unknown'), ('ZMeasured', 'measured')]:
            cfg = profiles / profile / 'codex'; cfg.mkdir(parents=True)
            (cfg / 'auth.json').write_text(json.dumps({'tokens': {
                'access_token': 'synthetic', 'account_id': identity}}))
        (profiles / '0Fallback/opencode/opencode').mkdir(parents=True)
        for vendor in ['codex', 'opencode']:
            script = bins / vendor
            script.write_text('#!/bin/sh\nprintf "%s\\n" "' + vendor + '"\n')
            script.chmod(0o755)
        env = {'HOME': str(home), 'PATH': str(bins) + ':/usr/bin:/bin',
               'N2_CODEX_USAGE_URL': 'http://127.0.0.1:' + str(server.server_port)}
        def run(*args):
            return subprocess.run([str(repo/'agents'), *args], env=env,
                                  capture_output=True, text=True, timeout=30)
        # Same provider: absent measurements cannot win as fabricated zero.
        result = run('run', '--best', '--vendor', 'codex')
        assert result.returncode == 0 and "'ZMeasured'" in result.stderr, result
        # Rotate from the beginning: no-API profile sorts before measured profile.
        (profiles / '.last-slot').unlink(missing_ok=True)
        result = run('run')
        assert result.returncode == 0 and result.stdout.strip() == 'codex', result
        assert "'ZMeasured'" in result.stderr, result
        Handler.measured = 0
        result = run('run', '--best', '--vendor', 'codex')
        assert result.returncode == 0 and "'ZMeasured'" in result.stderr, result
        Handler.measured = 100
        result = run('run')
        assert result.returncode == 0 and result.stdout.strip() == 'opencode', result
        assert 'unmeasured' in result.stderr, result
        result = run('run', '--best', '--vendor', 'codex')
        assert result.returncode != 0, 'unknown and denied metered profiles must not be selected'
        for invalid in [None, float('nan'), -1, 101]:
            Handler.measured = invalid
            assert run('run', '--best', '--vendor', 'codex').returncode != 0
        print('Real CLI ranking passed: measured first; explicit unmeasured fallback.')
finally:
    server.shutdown(); server.server_close(); thread.join(timeout=5)
    assert not thread.is_alive()
