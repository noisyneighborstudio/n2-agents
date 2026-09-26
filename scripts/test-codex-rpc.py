#!/usr/bin/env python3
"""Exercise the real subprocess protocol without accounts or model calls."""
import importlib.util
import os
from pathlib import Path
import tempfile
import subprocess
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('n2_codex_rpc', Path(__file__).resolve().parents[1] / 'codex-rpc.py')
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)

PROVIDER = '''#!/usr/bin/env python3
import json, os, sys, time, signal
mode = os.environ.get('N2_RPC_FIXTURE', '')
if mode == 'no-read': time.sleep(10)
if mode in ('inherited-pipe', 'stubborn-pipe'):
    if os.fork() == 0:
        if mode == 'stubborn-pipe': signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open('child.pid', 'w') as f: f.write(str(os.getpid()))
        time.sleep(10)
        os._exit(0)
    os._exit(0)
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request: continue
    method = request['method']
    if mode == 'timeout': time.sleep(10)
    if mode == 'eof': sys.exit(0)
    if mode == 'large':
        print('x' * 4096, flush=True)
        continue
    if mode == 'approval':
        print(json.dumps({'id': 99, 'method': 'item/commandExecution/requestApproval', 'params': {}}), flush=True)
        continue
    if mode == 'noise':
        print('startup diagnostic', flush=True)
        print(json.dumps({'id': True, 'result': {'wrong': True}}), flush=True)
    result = {}
    if method == 'thread/start' and mode in ('update-after-pin', 'refresh-after-pin'):
        notice = {'method': 'account/updated', 'params': {'authMode': 'chatgpt'}}
        if mode == 'refresh-after-pin': notice = {'id': 99, 'method': 'account/chatgptAuthTokens/refresh', 'params': {}}
        print(json.dumps(notice), flush=True)
    if method == 'account/login/start':
        result = {'type': 'chatgptAuthTokens'}
        if mode == 'unsupported-pin': result = {'type': 'chatgpt'}
        print(json.dumps({'method': 'account/updated', 'params': {'authMode': 'chatgptAuthTokens'}}), flush=True)
    if method == 'account/read':
        result = {'account': {'type': 'chatgpt', 'email': 'fixture@example.invalid'},
                  'workspaceRouting': {'chatgptAccountId': 'workspace', 'backendOrigin': 'https://chatgpt.com'}}
        if (mode == 'switch' and request['id'] == 4) or (mode == 'pin-switch' and request['id'] >= 6):
            result['workspaceRouting']['chatgptAccountId'] = 'other'
    if method == 'account/rateLimits/read':
        if mode == 'refresh-pin':
            print(json.dumps({'id': 99, 'method': 'account/chatgptAuthTokens/refresh', 'params': {'reason': 'unauthorized'}}), flush=True)
            continue
        result = {'accountId': 'workspace', 'rateLimits': {'primary': {'usedPercent': 12}}}
        if mode == 'mismatch': result['accountId'] = 'other'
        if mode == 'invalid-account': result['accountId'] = True
        if mode == 'changed':
            print(json.dumps({'method': 'account/updated', 'params': {'authMode': 'chatgpt'}}), flush=True)
    if mode == 'invalid-result': result = []
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
'''


class ProtocolTests(unittest.TestCase):
    def run_client(self, mode, callback, timeout=1):
        with tempfile.TemporaryDirectory() as root:
            binary = Path(root) / 'codex'
            binary.write_text(PROVIDER)
            binary.chmod(0o700)
            with patch.dict(os.environ, {'N2_RPC_FIXTURE': mode}):
                client = rpc.CodexRPC(root, root, timeout=timeout, executable=str(binary))
                try:
                    with client:
                        callback(client)
                finally:
                    self.assertIsNotNone(client.process.poll(), 'provider process must be reaped')
                    self.assertFalse(client.reader.is_alive(), 'protocol reader must finish')
                    child_file = Path(root) / 'child.pid'
                    if child_file.exists():
                        state = subprocess.run(['/bin/ps', '-p', child_file.read_text(), '-o', 'stat='],
                                               capture_output=True, text=True, check=False).stdout.strip()
                        self.assertTrue(not state or state.startswith('Z'), 'descendant must not keep running')

    def test_consistent_account_and_allowance(self):
        def read(client):
            client.initialize()
            value = client.read_usage()
            self.assertEqual(value['accountId'], value['workspaceRouting']['chatgptAccountId'])
            self.assertEqual(value['rateLimits']['primary']['usedPercent'], 12)
        self.run_client('', read)

    def test_account_change_invalidates_observation(self):
        for mode in ('switch', 'changed'):
            def read(client):
                client.initialize()
                with self.assertRaisesRegex(RuntimeError, 'account changed'):
                    client.read_usage()
            self.run_client(mode, read)

    def test_allowance_must_belong_to_selected_account(self):
        def read(client):
            client.initialize()
            with self.assertRaisesRegex(RuntimeError, 'does not match'):
                client.read_usage()
        self.run_client('mismatch', read)

    def test_invalid_allowance_account_is_rejected(self):
        def read(client):
            client.initialize()
            with self.assertRaisesRegex(ValueError, 'invalid allowance account'):
                client.read_usage()
        self.run_client('invalid-account', read)

    def test_noise_and_boolean_ids_cannot_impersonate_reply(self):
        def read(client):
            result = client.call('initialize', {})
            self.assertEqual(result, {})
        self.run_client('noise', read)

    def test_read_calls_do_not_approve_server_requests(self):
        def read(client):
            with self.assertRaisesRegex(RuntimeError, 'unexpected Codex server request'):
                client.initialize()
        self.run_client('approval', read)

    def test_timeout_and_eof_cleanup(self):
        for mode, exception in [('timeout', TimeoutError), ('eof', RuntimeError)]:
            def read(client):
                with self.assertRaises(exception):
                    client.initialize()
            start = time.monotonic()
            self.run_client(mode, read, timeout=0.2)
            self.assertLess(time.monotonic() - start, 3)

    def test_oversized_protocol_line_fails_closed(self):
        def read(client):
            with self.assertRaisesRegex(RuntimeError, 'protocol stream failed'):
                client.initialize()
        with patch.object(rpc, 'MAX_MESSAGE_BYTES', 2048):
            self.run_client('large', read)

    def test_deadline_includes_blocked_write(self):
        def read(client):
            with self.assertRaisesRegex(TimeoutError, 'write timed out'):
                client.call('large/request', {'prompt': 'x' * 200000})
        start = time.monotonic()
        self.run_client('no-read', read, timeout=0.2)
        self.assertLess(time.monotonic() - start, 3)

    def test_exited_leader_with_inherited_pipe_cannot_hang_cleanup(self):
        def read(client):
            client.process.wait(timeout=2)
            with self.assertRaises(TimeoutError):
                client.receive(time.monotonic() + 0.2)
        start = time.monotonic()
        for mode in ('inherited-pipe', 'stubborn-pipe'):
            self.run_client(mode, read, timeout=0.2)
        self.assertLess(time.monotonic() - start, 3)

    def test_external_pin_is_validated_and_cannot_switch_accounts(self):
        def read(client):
            client.initialize()
            observed = client.pin_external_account('synthetic-token', 'workspace')
            self.assertEqual(observed['accountId'], 'workspace')
            client.validate_account_binding()
            with self.assertRaisesRegex(RuntimeError, 'cannot replace'):
                client.call('account/logout')
            with self.assertRaisesRegex(RuntimeError, 'cannot replace'):
                client.send({'id': 99, 'method': 'account/logout'})
            with self.assertRaisesRegex(RuntimeError, 'already attempted'):
                client.pin_external_account('other-token', 'other-workspace')
            client.validate_account_binding()
        self.run_client('', read)

    def test_wrong_pin_poisons_connection_instead_of_using_fallback(self):
        def read(client):
            client.initialize()
            with self.assertRaisesRegex(RuntimeError, 'different account'):
                client.pin_external_account('synthetic-token', 'other-workspace')
            with self.assertRaisesRegex(RuntimeError, 'binding is invalid'):
                client.call('thread/start', {})
        self.run_client('', read)

    def test_changed_pinned_account_cannot_start_more_work(self):
        def read(client):
            client.initialize()
            client.pin_external_account('synthetic-token', 'workspace')
            with self.assertRaises(RuntimeError):
                client.validate_account_binding()
            with self.assertRaisesRegex(RuntimeError, 'binding is invalid'):
                client.call('thread/start', {})
        self.run_client('pin-switch', read)

    def test_unsupported_or_expired_external_auth_never_falls_back(self):
        for mode in ('unsupported-pin', 'refresh-pin'):
            def read(client):
                client.initialize()
                with self.assertRaises(RuntimeError):
                    client.pin_external_account('synthetic-token', 'workspace')
                with self.assertRaisesRegex(RuntimeError, 'binding is invalid'):
                    client.send({'id': 99, 'method': 'thread/start', 'params': {}})
            self.run_client(mode, read)

    def test_invalid_pin_arguments_disable_fallback(self):
        def read(client):
            client.initialize()
            with self.assertRaises(ValueError):
                client.pin_external_account('', 'workspace')
            with self.assertRaisesRegex(RuntimeError, 'binding is invalid'):
                client.call('thread/start', {})
        self.run_client('', read)

    def test_observed_auth_change_or_refresh_immediately_disables_calls(self):
        for mode in ('update-after-pin', 'refresh-after-pin'):
            def read(client):
                client.initialize()
                client.pin_external_account('synthetic-token', 'workspace')
                with self.assertRaises(RuntimeError):
                    client.call('thread/start', {})
                with self.assertRaisesRegex(RuntimeError, 'binding is invalid'):
                    client.call('thread/start', {})
            self.run_client(mode, read)

    def test_non_object_response_is_not_success(self):
        def read(client):
            with self.assertRaisesRegex(ValueError, 'invalid Codex response'):
                client.initialize()
        self.run_client('invalid-result', read)


if __name__ == '__main__':
    unittest.main()
