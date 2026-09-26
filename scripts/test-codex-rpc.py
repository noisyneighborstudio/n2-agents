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
account_reads = 0
config_reads = 0
login_token = None
pending_renewal = None
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request: continue
    if 'method' not in request:
        if pending_renewal is not None:
            with open('renewal-delivered', 'w') as f: f.write('yes')
            print(json.dumps({'id': pending_renewal, 'result': {'renewed': True}}), flush=True)
            pending_renewal = None
        continue
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
    if method == 'thread/start' and mode.startswith('renew-'):
        if mode == 'renew-slow-drain':
            # Exact frames let the reader finish a chunk without a partial line.
            notice = json.dumps({'method': 'fixture/notice'})
            for _ in range(24):
                sys.stdout.write(notice + ' ' * (4095 - len(notice)) + chr(10))
                sys.stdout.flush()
        if mode == 'renew-burst':
            for _ in range(140):
                print(json.dumps({'method': 'fixture/notice', 'params': {'padding': 'x' * 1024}}), flush=True)
        params = {'reason': 'unauthorized', 'previousAccountId': 'workspace'}
        request_id = 99
        if mode == 'renew-wrong-request': params['previousAccountId'] = 'other'
        if mode == 'renew-bool-id': request_id = True
        if mode == 'renew-null-account': params['previousAccountId'] = None
        pending_renewal = request['id']
        print(json.dumps({'id': request_id, 'method': 'account/chatgptAuthTokens/refresh', 'params': params}), flush=True)
        continue
    if method == 'thread/start' and mode in ('update-after-pin', 'refresh-after-pin'):
        notice = {'method': 'account/updated', 'params': {'authMode': 'chatgpt'}}
        if mode == 'refresh-after-pin': notice = {'id': 99, 'method': 'account/chatgptAuthTokens/refresh', 'params': {}}
        print(json.dumps(notice), flush=True)
    if method == 'account/login/start':
        login_token = request['params']['accessToken']
        if login_token == 'slow-token': time.sleep(2)
        result = {'type': 'chatgptAuthTokens'}
        if mode == 'unsupported-pin': result = {'type': 'chatgpt'}
        print(json.dumps({'method': 'account/updated', 'params': {'authMode': 'chatgptAuthTokens'}}), flush=True)
    if method == 'config/read':
        config_reads += 1
        result = {'config': {}}
        if mode == 'custom-provider' or (mode == 'provider-switch' and config_reads > 1): result['config']['model_provider'] = 'synthetic'
        if mode == 'invalid-provider': result['config']['model_provider'] = False
        if mode == 'openai-endpoint': result['config']['openai_base_url'] = 'https://example.invalid/v1'
        if mode == 'chatgpt-endpoint' or (mode == 'endpoint-switch' and config_reads > 1): result['config']['chatgpt_base_url'] = 'https://example.invalid/backend-api'
        if mode == 'reserved-provider': result['config']['model_providers'] = {'openai': {'base_url': 'https://example.invalid/v1'}}
        if mode == 'invalid-providers': result['config']['model_providers'] = []
        if mode == 'invalid-config': result['config'] = []
        if login_token == 'endpoint-token': result['config']['chatgpt_base_url'] = 'https://example.invalid/backend-api'
    if method == 'account/read':
        account_reads += 1
        result = {'account': {'type': 'chatgpt', 'email': 'fixture@example.invalid'},
                  'workspaceRouting': {'chatgptAccountId': 'workspace', 'backendOrigin': 'https://chatgpt.com'}}
        if login_token == 'wrong-token': result['account']['email'] = 'other@example.invalid'
        if mode == 'no-provider-auth': result['requiresOpenaiAuth'] = False
        if mode == 'invalid-provider-auth': result['requiresOpenaiAuth'] = 'false'
        if (mode == 'switch' and account_reads == 2) or (mode == 'pin-switch' and account_reads >= 3):
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
                client = rpc.CodexRPC(root, root, timeout=timeout, executable=str(binary), ephemeral_auth=True)
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

    def test_custom_provider_does_not_inherit_chatgpt_headroom(self):
        for mode in ('custom-provider', 'no-provider-auth', 'openai-endpoint', 'chatgpt-endpoint', 'reserved-provider'):
            def read(client):
                client.initialize()
                value = client.read_usage()
                self.assertEqual(value, {'_native': True, '_status': 'no-usage-api'})
            self.run_client(mode, read)

    def test_inherited_endpoint_does_not_inherit_subscription_headroom(self):
        def read(client):
            client.initialize()
            self.assertEqual(client.read_usage(), {'_native': True, '_status': 'no-usage-api'})
        with patch.dict(os.environ, {'OPENAI_BASE_URL': 'https://example.invalid/v1'}):
            self.run_client('', read)

    def test_provider_change_invalidates_observation(self):
        def read(client):
            client.initialize()
            with self.assertRaisesRegex(RuntimeError, 'provider changed'):
                client.read_usage()
        for mode in ('provider-switch', 'endpoint-switch'):
            self.run_client(mode, read)

    def test_malformed_provider_configuration_cannot_appear_healthy(self):
        for mode in ('invalid-provider', 'invalid-config', 'invalid-provider-auth', 'invalid-providers'):
            def read(client):
                client.initialize()
                with self.assertRaises(ValueError):
                    client.read_usage()
            self.run_client(mode, read)

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
            # EOF must test a closed stream, not race Python startup under load.
            self.run_client(mode, read, timeout=2 if mode == 'eof' else 0.2)
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

    def test_owner_token_is_authenticated_before_delivery(self):
        for mode in ('renew-ok', 'renew-null-account'):
            def read(client):
                client.initialize()
                calls = []
                def source(account, deadline):
                    calls.append(account)
                    self.assertGreater(deadline, time.monotonic())
                    return {'accessToken': 'renewed-token', 'chatgptAccountId': account}
                client.pin_external_account('original-token', 'workspace', renewal_source=source)
                result = client.call('thread/start', {})
                self.assertTrue(result['renewed'])
                self.assertEqual(calls, ['workspace'])
                client.validate_account_binding()
                self.assertTrue((Path(client.cwd) / 'renewal-delivered').exists())
            self.run_client(mode, read, timeout=3)

    def test_wrong_renewed_identity_is_never_delivered(self):
        for token in ('wrong-token', 'endpoint-token'):
            def read(client):
                client.initialize()
                client.pin_external_account('original-token', 'workspace', renewal_source=lambda account, deadline:
                    {'accessToken': token, 'chatgptAccountId': account})
                with self.assertRaisesRegex(RuntimeError, 'requires renewal'):
                    client.call('thread/start', {})
                self.assertFalse((Path(client.cwd) / 'renewal-delivered').exists())
                with self.assertRaisesRegex(RuntimeError, 'binding is invalid'):
                    client.call('thread/start', {})
            self.run_client('renew-ok', read, timeout=3)

    def test_invalid_refresh_requests_never_fetch_a_secret(self):
        for mode in ('renew-wrong-request', 'renew-bool-id'):
            def read(client):
                client.initialize()
                calls = []
                def source(account, deadline):
                    calls.append(account)
                    return {'accessToken': 'renewed-token', 'chatgptAccountId': account}
                client.pin_external_account('original-token', 'workspace', renewal_source=source)
                with self.assertRaisesRegex(RuntimeError, 'requires renewal'):
                    client.call('thread/start', {})
                self.assertEqual(calls, [])
                self.assertFalse((Path(client.cwd) / 'renewal-delivered').exists())
            self.run_client(mode, read)

    def test_invalid_or_reused_owner_response_is_never_delivered(self):
        responses = [None, {'accessToken': 'new', 'chatgptAccountId': 'other'},
                     {'accessToken': 'original-token', 'chatgptAccountId': 'workspace'},
                     {'accessToken': 'new', 'chatgptAccountId': 'workspace', 'refreshToken': 'secret'},
                     {'accessToken': 'x' * 65537, 'chatgptAccountId': 'workspace'}]
        for response in responses:
            def read(client):
                client.initialize()
                client.pin_external_account('original-token', 'workspace', renewal_source=lambda account, deadline: response)
                with self.assertRaisesRegex(RuntimeError, 'requires renewal'):
                    client.call('thread/start', {})
                self.assertFalse((Path(client.cwd) / 'renewal-delivered').exists())
            self.run_client('renew-ok', read)

    def test_owner_timeout_and_verification_timeout_deliver_nothing(self):
        for source_delay, token in ((2, 'renewed-token'), (0, 'slow-token')):
            def read(client):
                client.initialize()
                def source(account, deadline):
                    time.sleep(source_delay)
                    return {'accessToken': token, 'chatgptAccountId': account}
                client.pin_external_account('original-token', 'workspace', renewal_source=source)
                started = time.monotonic()
                with self.assertRaisesRegex(RuntimeError, 'requires renewal'):
                    client.call('thread/start', {}, deadline=time.monotonic() + .2)
                self.assertLess(time.monotonic() - started, 1)
                self.assertFalse((Path(client.cwd) / 'renewal-delivered').exists())
            self.run_client('renew-ok', read)

    def test_replayed_refresh_id_does_not_fetch_again(self):
        def read(client):
            client.initialize()
            calls = []
            def source(account, deadline):
                calls.append(account)
                return {'accessToken': 'renewed-token', 'chatgptAccountId': account}
            client.pin_external_account('original-token', 'workspace', renewal_source=source)
            client.call('thread/start', {})
            with self.assertRaisesRegex(RuntimeError, 'requires renewal'):
                client.call('thread/start', {})
            self.assertEqual(calls, ['workspace'])
        self.run_client('renew-ok', read, timeout=3)

    def test_expired_queued_request_does_not_fetch_a_token(self):
        def read(client):
            client.initialize()
            calls = []
            def source(account, deadline):
                calls.append(account)
                return {'accessToken': 'renewed-token', 'chatgptAccountId': account}
            client.pin_external_account('original-token', 'workspace', renewal_source=source)
            client.send({'id': 1000, 'method': 'thread/start', 'params': {}})
            until = time.monotonic() + 1
            while client.messages.empty() and time.monotonic() < until:
                time.sleep(.01)
            self.assertFalse(client.messages.empty())
            time.sleep(.07)
            with patch.object(rpc, 'RENEWAL_REPLY_SECONDS', .05):
                with self.assertRaisesRegex(RuntimeError, 'requires renewal'):
                    client.receive(time.monotonic() + 1)
            self.assertEqual(calls, [])
            self.assertFalse((Path(client.cwd) / 'renewal-delivered').exists())
        self.run_client('renew-ok', read)

    def test_backpressure_cannot_restart_refresh_deadline(self):
        def read(client):
            client.initialize()
            calls = []
            def source(account, deadline):
                calls.append(account)
                return {'accessToken': 'renewed-token', 'chatgptAccountId': account}
            client.pin_external_account('original-token', 'workspace', renewal_source=source)
            client.send({'id': 1000, 'method': 'thread/start', 'params': {}})
            until = time.monotonic() + 2
            while client.messages.qsize() < rpc.MAX_PENDING_MESSAGES and time.monotonic() < until:
                time.sleep(.01)
            self.assertEqual(client.messages.qsize(), rpc.MAX_PENDING_MESSAGES)
            time.sleep(.15)
            with patch.object(rpc, 'RENEWAL_REPLY_SECONDS', .05):
                with self.assertRaisesRegex(RuntimeError, 'requires renewal'):
                    client.call('account/read', {}, deadline=time.monotonic() + 2)
            self.assertEqual(calls, [])
            self.assertFalse((Path(client.cwd) / 'renewal-delivered').exists())
        self.run_client('renew-burst', read)

    def test_successful_short_queue_waits_preserve_unread_refresh_age(self):
        original_queue = rpc.queue.Queue
        original_read = rpc.os.read
        waits = []
        class ObservedQueue(original_queue):
            def put(self, item, block=True, timeout=None):
                started = time.monotonic()
                value = super().put(item, block=block, timeout=timeout)
                if block and timeout is not None:
                    waits.append(time.monotonic() - started)
                return value
        def read(client):
            client.initialize()
            calls = []
            def source(account, deadline):
                calls.append(account)
                return {'accessToken': 'renewed-token', 'chatgptAccountId': account}
            client.pin_external_account('original-token', 'workspace', renewal_source=source)
            def slow_notification(message):
                if message.get('method') == 'fixture/notice':
                    time.sleep(.01)
            with patch.object(rpc, 'RENEWAL_REPLY_SECONDS', .1):
                with self.assertRaisesRegex(RuntimeError, 'requires renewal'):
                    client.call('thread/start', {}, deadline=time.monotonic() + 3,
                                on_notification=slow_notification)
            self.assertEqual(calls, [], 'an old unread request must not reach the token source')
            self.assertFalse((Path(client.cwd) / 'renewal-delivered').exists())
        # Keep framing deterministic while retaining real pipes and provider
        # subprocesses. Each timed enqueue normally succeeds after about 10ms.
        with patch.object(rpc, 'MAX_PENDING_MESSAGES', 1), patch.object(rpc.queue, 'Queue', ObservedQueue), \
                patch.object(rpc.os, 'read', side_effect=lambda fd, size: original_read(fd, min(size, 4096))):
            self.run_client('renew-slow-drain', read, timeout=3)
        self.assertTrue(any(.002 < elapsed < .1 for elapsed in waits),
                        'exercise successful queue waits shorter than the old Full timeout')

    def test_owner_error_is_redacted(self):
        def read(client):
            client.initialize()
            def source(account, deadline):
                raise ValueError('synthetic-owner-secret')
            client.pin_external_account('original-token', 'workspace', renewal_source=source)
            with self.assertRaises(RuntimeError) as error:
                client.call('thread/start', {})
            self.assertEqual(str(error.exception), 'bound Codex account requires renewal')
        self.run_client('renew-ok', read)

    def test_non_object_response_is_not_success(self):
        def read(client):
            with self.assertRaisesRegex(ValueError, 'invalid Codex response'):
                client.initialize()
        self.run_client('invalid-result', read)


if __name__ == '__main__':
    unittest.main()
