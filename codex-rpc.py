#!/usr/bin/env python3
"""Bounded stdio transport for N2's provider-native Codex operations.

The owner keeps this connection for the operation being attributed. Never treat
an account observation from a different CLI process as an execution receipt.
"""
import datetime
import hashlib
import tempfile
import json
import math
import re
import os
import queue
import select
import signal
import subprocess
import sys
import threading
import time

MAX_MESSAGE_BYTES = 2 * 1024 * 1024
MAX_PENDING_MESSAGES = 128
RENEWAL_REPLY_SECONDS = 9


def reported_quota_reset(error, now):
    """Extract only an unambiguous retry time from a terminal quota error.

    TurnError has no typed reset field. Never borrow a window from an account
    poll or retain the provider's raw error text. Local dates and compound or
    qualified retry phrases remain unknown.
    """
    if not isinstance(error, dict) or error.get('codexErrorInfo') not in ('usageLimitExceeded', 'rateLimitExceeded'):
        return None
    message = error.get('message')
    if not isinstance(message, str) or len(message) > 16384:
        return None
    if len(re.findall(r'(?i)\btry again\b', message)) != 1:
        return None
    match = re.search(r'(?i)\btry again (in|at|after) ([^\r\n]+)[\r\n]*$', message)
    if not match:
        return None
    phrase = match[2].strip()
    if phrase.endswith('.'):
        phrase = phrase[:-1]
    relative = re.fullmatch(r'(\d{1,8})\s+(seconds?|secs?|minutes?|mins?|hours?|hrs?)', phrase, re.I)
    if match[1].lower() == 'in' and relative:
        unit = relative[2].lower()
        reset = now + int(relative[1]) * (3600 if unit.startswith('h') else 60 if unit.startswith('m') else 1)
    elif match[1].lower() in ('at', 'after') and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)', phrase) and not phrase.endswith('-00:00'):
        try:
            reset = datetime.datetime.fromisoformat(phrase.replace('Z', '+00:00')).timestamp()
        except (ValueError, OverflowError):
            return None
    else:
        return None
    # Malformed, expired and implausibly distant values cannot expire a denial.
    return reset if math.isfinite(reset) and now < reset <= now + 366 * 86400 else None


class InitialTokenRejected(RuntimeError):
    def __init__(self, deadline):
        super().__init__('Codex rejected the initial owner token')
        self.deadline = deadline


class CodexRPC:
    def __init__(self, cfg, cwd, timeout=15, executable='codex', ephemeral_auth=False, own_process_group=True, environment=None, managed_file_auth=False, lifetime_lock_fd=None, lifetime_deadline=None):
        self.timeout = timeout
        self.executable = executable
        self.ephemeral_auth = ephemeral_auth
        self._renewal_source = None
        self._initial_owner_account = None
        self._bound_account_id = None
        self._token_digest = None
        self._renewal_ids = set()
        self.own_process_group = own_process_group
        self.cwd = os.path.abspath(cwd)
        self.messages = queue.Queue(maxsize=MAX_PENDING_MESSAGES)
        self.stopping = threading.Event()
        self.failure = None
        self._ingress_delayed_since = None
        self.next_id = 1
        self.account_generation = 0
        self._bound_account = None
        self._bound_generation = None
        self._binding_failed = False
        if ephemeral_auth and managed_file_auth:
            raise ValueError("conflicting Codex credential stores")
        child_env = dict(os.environ if environment is None else environment, CODEX_HOME=cfg)
        self._custom_openai_endpoint = bool(child_env.get('OPENAI_BASE_URL'))
        argv = [executable]
        if ephemeral_auth:
            argv += ['-c', 'cli_auth_credentials_store="ephemeral"']
        if managed_file_auth:
            argv += ['-c', 'cli_auth_credentials_store="file"']
        argv += ['app-server']
        pass_fds = ()
        if lifetime_lock_fd is not None:
            if not own_process_group or type(lifetime_lock_fd) is not int or lifetime_lock_fd < 3:
                raise ValueError('invalid process lifetime lock')
            if type(lifetime_deadline) not in (int, float) or not math.isfinite(lifetime_deadline) or lifetime_deadline <= time.monotonic():
                raise ValueError('invalid process lifetime deadline')
            pass_fds = (lifetime_lock_fd,)
            argv = [sys.executable, os.path.abspath(__file__), '--lock-supervisor', str(lifetime_lock_fd), str(lifetime_deadline)] + argv
        self.process = subprocess.Popen(
            argv, cwd=cwd, env=child_env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            start_new_session=own_process_group, pass_fds=pass_fds, bufsize=0)
        os.set_blocking(self.process.stdin.fileno(), False)
        os.set_blocking(self.process.stdout.fileno(), False)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _put(self, message, received_at=None):
        received_at = time.monotonic() if received_at is None else received_at
        while not self.stopping.is_set():
            try:
                self.messages.put_nowait((received_at, message))
                return
            except queue.Full:
                if self._ingress_delayed_since is None:
                    self._ingress_delayed_since = received_at
                try:
                    self.messages.put((received_at, message), timeout=0.1)
                    return
                except queue.Full:
                    pass

    def _read(self):
        pending = bytearray()
        pending_since = None
        descriptor = self.process.stdout.fileno()
        try:
            while not self.stopping.is_set():
                # After backpressure, unread pipe bytes may already be old.
                # Keep their conservative age until the pipe is observed empty.
                if not select.select([descriptor], [], [], 0)[0]:
                    self._ingress_delayed_since = None
                if not select.select([descriptor], [], [], 0.1)[0]:
                    continue
                try:
                    chunk = os.read(descriptor, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    self._put(None)
                    return
                arrived_at = self._ingress_delayed_since or time.monotonic()
                if pending_since is None:
                    pending_since = arrived_at
                else:
                    pending_since = min(pending_since, arrived_at)
                pending.extend(chunk)
                while b'\n' in pending:
                    end = pending.index(b'\n') + 1
                    if end > MAX_MESSAGE_BYTES:
                        raise ValueError('Codex protocol message exceeds size limit')
                    line = bytes(pending[:end])
                    del pending[:end]
                    try:
                        message = json.loads(line)
                    except (ValueError, UnicodeError):
                        # A startup log is not a protocol response.
                        continue
                    if isinstance(message, dict):
                        self._put(message, pending_since)
                    if self.stopping.is_set():
                        return
                if not pending:
                    pending_since = None
                if len(pending) > MAX_MESSAGE_BYTES:
                    raise ValueError('Codex protocol message exceeds size limit')
        except (OSError, ValueError, RecursionError):
            # Store only a fixed diagnostic, never provider payload/credentials.
            self.failure = 'Codex protocol stream failed'
            self._put(None)

    def send(self, message, deadline=None):
        if self._binding_failed:
            raise RuntimeError('Codex account binding is invalid')
        method = message.get('method')
        if method is not None and not isinstance(method, str):
            raise ValueError('invalid Codex request method')
        if self._bound_account is not None and method is not None and (method.startswith('account/login/') or method == 'account/logout'):
            raise RuntimeError('cannot replace a bound Codex account')
        deadline = deadline if deadline is not None else time.monotonic() + self.timeout
        body = json.dumps(message, allow_nan=False, separators=(',', ':')).encode() + b'\n'
        if len(body) > MAX_MESSAGE_BYTES:
            raise ValueError('Codex request exceeds size limit')
        descriptor = self.process.stdin.fileno()
        remaining_body = memoryview(body)
        while remaining_body:
            remaining_time = deadline - time.monotonic()
            if remaining_time <= 0 or not select.select([], [descriptor], [], remaining_time)[1]:
                raise TimeoutError('Codex protocol write timed out')
            try:
                written = os.write(descriptor, remaining_body[:65536])
            except BlockingIOError:
                continue
            if not written:
                raise RuntimeError('Codex protocol write closed')
            remaining_body = remaining_body[written:]

    def _renew_external_account(self, message, deadline):
        """Fetch from a trusted owner and authenticate before exposing a token.

        The owner callback must preserve its grant generation and consent checks.
        It receives only the pinned account ID and monotonic deadline. A timed-out
        fetch may finish at the owner, but its result can never reach this server.
        """
        try:
            params = message.get('params')
            request_id = message.get('id')
            valid_id = type(request_id) is int or (isinstance(request_id, str) and 0 < len(request_id) <= 256)
            if (not valid_id or request_id in self._renewal_ids or len(self._renewal_ids) >= 1024
                    or not isinstance(params, dict) or params.get('reason') != 'unauthorized'
                    or params.get('previousAccountId') not in (None, self._bound_account_id)
                    or self._renewal_source is None or not self.ephemeral_auth):
                raise RuntimeError('invalid renewal request')
            self._renewal_ids.add(request_id)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('renewal deadline expired')
            result_queue = queue.Queue(maxsize=1)
            source, account_id = self._renewal_source, self._bound_account_id
            def fetch():
                try:
                    result = source(account_id, deadline)
                except Exception:
                    result = None
                # No callback exception or secret-bearing diagnostic crosses out.
                result_queue.put(result)
            threading.Thread(target=fetch, daemon=True).start()
            supplied = result_queue.get(timeout=remaining)
            if not isinstance(supplied, dict) or set(supplied) != {'accessToken', 'chatgptAccountId'}:
                raise ValueError('invalid renewal response')
            token = supplied['accessToken']
            if (supplied['chatgptAccountId'] != account_id or not isinstance(token, str)
                    or not token or len(token.encode()) > 65536):
                raise ValueError('invalid renewal credential')
            digest = hashlib.sha256(token.encode()).digest()
            if digest == self._token_digest or time.monotonic() >= deadline:
                raise ValueError('renewal did not replace rejected token')
            # No execution or canonical-home access in this verifier. It must
            # authenticate the exact token, not trust the owner's account label.
            with tempfile.TemporaryDirectory(prefix='n2-codex-renewal-') as home:
                with CodexRPC(home, self.cwd, timeout=max(.001, deadline - time.monotonic()),
                              executable=self.executable, ephemeral_auth=True,
                              own_process_group=self.own_process_group) as verifier:
                    verifier.initialize(deadline=deadline)
                    observed = verifier.pin_external_account(token, account_id, deadline=deadline)
                    if self._account_key(observed) != self._bound_account:
                        raise RuntimeError('renewal account mismatch')
            if time.monotonic() >= deadline:
                raise TimeoutError('renewal verification expired')
            self.send({'id': request_id, 'result': {'accessToken': token, 'chatgptAccountId': account_id}}, deadline)
            self._token_digest = digest
        except Exception:
            self._binding_failed = True
            raise RuntimeError('bound Codex account requires renewal') from None

    def receive(self, deadline, return_after_control=False):
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Codex protocol read timed out')
            try:
                received_at, message = self.messages.get(timeout=remaining)
            except queue.Empty:
                raise TimeoutError('Codex protocol read timed out') from None
            if message is None:
                raise RuntimeError(self.failure or 'Codex protocol stream closed')
            if message.get('method') == 'account/updated':
                self.account_generation += 1
                if self._bound_account is not None:
                    self._binding_failed = True
                    raise RuntimeError('bound Codex account changed')
            if message.get('method') == 'account/chatgptAuthTokens/refresh' and self._initial_owner_account is not None:
                params = message.get('params')
                request_id = message.get('id')
                valid_id = type(request_id) is int or (isinstance(request_id, str) and 0 < len(request_id) <= 256)
                if (valid_id and isinstance(params, dict) and params.get('reason') == 'unauthorized'
                        and params.get('previousAccountId') in (None, self._initial_owner_account)):
                    # No execution has started and no account is bound yet.
                    # The owner client closes this server, renews that rejected
                    # generation once, then independently pins a new server.
                    raise InitialTokenRejected(min(deadline, received_at + RENEWAL_REPLY_SECONDS))
                raise RuntimeError('invalid initial owner renewal request')
            if message.get('method') == 'account/chatgptAuthTokens/refresh' and self._bound_account is not None:
                # Reserve one second of the provider's approximate 10-second
                # deadline, including time already spent in our inbound queue.
                self._renew_external_account(message, min(deadline, received_at + RENEWAL_REPLY_SECONDS))
                if return_after_control:
                    return None
                continue
            return message

    def call(self, method, params=None, deadline=None, on_notification=None, deferred_messages=None):
        request_id = self.next_id
        self.next_id += 1
        request = {'id': request_id, 'method': method}
        if params is not None:
            request['params'] = params
        deadline = deadline if deadline is not None else time.monotonic() + self.timeout
        self.send(request, deadline)
        while True:
            message = self.receive(deadline)
            # JSON true must not compare equal to request id 1.
            if type(message.get('id')) is int and message['id'] == request_id and 'method' not in message:
                if 'error' in message:
                    raise RuntimeError('Codex request failed: ' + method)
                result = message.get('result')
                if not isinstance(result, dict):
                    raise ValueError('invalid Codex response: ' + method)
                return result
            if deferred_messages is not None:
                if len(deferred_messages) >= 128:
                    raise RuntimeError('too many deferred Codex messages')
                deferred_messages.append(message)
                continue
            if 'method' in message and 'id' in message:
                # Read-only calls must not grant approvals or provide secrets.
                # A future execution owner must explicitly handle such requests.
                raise RuntimeError('unexpected Codex server request')
            if on_notification is not None:
                on_notification(message)

    def initialize(self, deadline=None):
        self.initialization = self.call('initialize', {
            'clientInfo': {'name': 'n2_usage', 'version': '1.0.0'},
            'capabilities': {'experimentalApi': True}}, deadline=deadline)
        self.send({'method': 'initialized'}, deadline=deadline)

    def _subscription_provider(self, deadline, deferred_messages=None):
        # The saved ChatGPT login can coexist with a custom model provider.
        # Its allowance must not make that unrelated route look runnable.
        response = self.call('config/read', {'cwd': self.cwd, 'includeLayers': False}, deadline, deferred_messages=deferred_messages)
        config = response.get('config')
        if not isinstance(config, dict):
            raise ValueError('invalid Codex effective configuration')
        provider = config.get('model_provider')
        if provider is not None and (not isinstance(provider, str) or not provider):
            raise ValueError('invalid Codex model provider')
        if self._custom_openai_endpoint or config.get('openai_base_url') is not None:
            return None
        backend = config.get('chatgpt_base_url')
        if backend is not None and (not isinstance(backend, str) or backend.rstrip('/') != 'https://chatgpt.com/backend-api'):
            return None
        providers = config.get('model_providers')
        if providers is not None:
            if not isinstance(providers, dict):
                raise ValueError('invalid Codex model providers')
            if 'openai' in providers:
                return None
        return provider or 'openai'

    def read_usage(self, deadline=None, deferred_messages=None):
        deadline = deadline if deadline is not None else time.monotonic() + self.timeout
        provider = self._subscription_provider(deadline, deferred_messages)
        if provider != 'openai':
            return {'_native': True, '_status': 'no-usage-api'}
        account_response = self.call('account/read', {'refreshToken': False}, deadline, deferred_messages=deferred_messages)
        account = account_response.get('account')
        if account is not None and not isinstance(account, dict):
            raise ValueError('invalid Codex account response')
        if not account or account.get('type') != 'chatgpt':
            return {'_native': True, '_status': 'no-token' if not account else 'no-usage-api', 'account': account}
        requires_auth = account_response.get('requiresOpenaiAuth')
        if requires_auth is not None and type(requires_auth) is not bool:
            raise ValueError('invalid Codex provider authentication requirement')
        if requires_auth is False:
            return {'_native': True, '_status': 'no-usage-api'}
        generation = self.account_generation
        result = self.call('account/rateLimits/read', deadline=deadline, deferred_messages=deferred_messages)
        after = self.call('account/read', {'refreshToken': False}, deadline, deferred_messages=deferred_messages)
        after_provider = self._subscription_provider(deadline, deferred_messages)
        if provider != after_provider:
            raise RuntimeError('provider changed during usage read')
        if after != account_response or self.account_generation != generation:
            raise RuntimeError('account changed during usage read')
        routing = account_response.get('workspaceRouting')
        measured_account = result.get('accountId')
        if measured_account is not None:
            if not isinstance(measured_account, str) or not measured_account:
                raise ValueError('invalid allowance account')
            if isinstance(routing, dict) and measured_account != routing.get('chatgptAccountId'):
                raise RuntimeError('allowance account does not match selected account')
        result.update(_native=True, account=account, workspaceRouting=routing)
        return result

    @staticmethod
    def _account_key(observation):
        return json.dumps({'account': observation.get('account'),
                           'workspaceRouting': observation.get('workspaceRouting')},
                          sort_keys=True, separators=(',', ':'))

    def pin_external_account(self, access_token, account_id, renewal_source=None, deadline=None, allow_initial_rejection=False):
        """Pin this process's auth in memory and authenticate its allowance read.

        The caller owns token lifecycle and must supply an isolated Codex home.
        No refresh token is accepted or retained. A refresh server request fails
        closed unless a trusted renewal source is supplied for this account. This
        pins authentication only; execution must also validate provider routing.
        """
        if self._bound_account is not None or self._binding_failed:
            raise RuntimeError('Codex account binding already attempted')
        try:
            if not isinstance(access_token, str) or not access_token or not isinstance(account_id, str) or not account_id:
                raise ValueError('missing Codex account credential')
            if renewal_source is not None and (not callable(renewal_source) or not self.ephemeral_auth):
                raise ValueError('renewal requires an ephemeral owner-bound client')
            if allow_initial_rejection:
                if renewal_source is None or not self.ephemeral_auth:
                    raise ValueError('initial recovery requires an owner source')
                self._initial_owner_account = account_id
            result = self.call('account/login/start', {
                'type': 'chatgptAuthTokens', 'accessToken': access_token, 'chatgptAccountId': account_id}, deadline=deadline)
            if result.get('type') != 'chatgptAuthTokens':
                raise RuntimeError('Codex external authentication unavailable')
            observation = self.read_usage(deadline=deadline)
            routing = observation.get('workspaceRouting')
            account = observation.get('account')
            if not isinstance(routing, dict) or routing.get('chatgptAccountId') != account_id:
                raise RuntimeError('Codex selected a different account')
            if not isinstance(account, dict) or account.get('type') != 'chatgpt':
                raise RuntimeError('Codex subscription authentication unavailable')
            self._bound_account = self._account_key(observation)
            self._bound_generation = self.account_generation
            self._bound_account_id = account_id
            self._token_digest = hashlib.sha256(access_token.encode()).digest()
            self._renewal_source = renewal_source
            return observation
        except Exception:
            # A failed pin cannot be followed by a turn on a fallback account.
            self._binding_failed = True
            raise
        finally:
            self._initial_owner_account = None

    def validate_account_binding(self, deferred_messages=None):
        if self._bound_account is None:
            raise RuntimeError('Codex account is not bound')
        try:
            observation = self.read_usage(deferred_messages=deferred_messages)
            if self._account_key(observation) != self._bound_account or self.account_generation != self._bound_generation:
                raise RuntimeError('bound Codex account changed')
            return observation
        except Exception:
            self._binding_failed = True
            raise

    def run_bound_turn(self, prompt, effort='medium', timeout=3600):
        """Run one fresh thread on this connection's externally pinned account.

        Approval review and workspace-write match the loop's --approve-for-me
        mode. Unhandled server requests never grant permission. The caller owns
        process cancellation and must not issue concurrent RPC calls.
        """
        if not isinstance(prompt, str) or not prompt or effort not in ('low', 'medium', 'high'):
            raise ValueError('invalid bound turn input')
        if not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or not 0 < timeout <= 86400:
            raise ValueError('invalid bound turn timeout')
        self.validate_account_binding()
        deadline = time.monotonic() + timeout
        started = self.call('thread/start', {
            'cwd': self.cwd, 'approvalPolicy': 'on-request',
            'approvalsReviewer': 'auto_review', 'sandbox': 'workspace-write',
            'ephemeral': True}, deadline=min(deadline, time.monotonic() + self.timeout))
        thread = started.get('thread')
        if (not isinstance(thread, dict) or not isinstance(thread.get('id'), str) or not thread['id']
                or started.get('modelProvider') != 'openai'
                or started.get('approvalsReviewer') != 'auto_review'
                or started.get('approvalPolicy') != 'on-request'
                or not isinstance(started.get('sandbox'), dict)
                or started['sandbox'].get('type') != 'workspaceWrite'
                or started.get('cwd') != self.cwd):
            self._binding_failed = True
            raise RuntimeError('Codex execution configuration does not match the bound request')
        # Thread creation may resolve project settings or initiate auth changes.
        self.validate_account_binding()
        early = []
        def buffer(message):
            if len(early) >= MAX_PENDING_MESSAGES:
                raise RuntimeError('too many events before Codex turn acknowledgement')
            early.append(message)
        reply = self.call('turn/start', {
            'threadId': thread['id'], 'input': [{'type': 'text', 'text': prompt}],
            'effort': effort}, deadline=min(deadline, time.monotonic() + self.timeout), on_notification=buffer)
        turn = reply.get('turn')
        if not isinstance(turn, dict) or not isinstance(turn.get('id'), str) or not turn['id']:
            self._binding_failed = True
            raise ValueError('invalid Codex turn acknowledgement')
        result = {'threadId': thread['id'], 'turnId': turn['id'], 'model': started.get('model'),
                  'text': '', 'tokens': None, 'status': None, 'errorCode': None, 'errorResetAt': None}
        def consume(message):
            method = message.get('method')
            if method is None:
                return
            if 'id' in message:
                raise RuntimeError('action required: unexpected Codex server request')
            params = message.get('params')
            if not isinstance(params, dict) or params.get('threadId') != thread['id']:
                return
            if method == 'turn/completed':
                completed = params.get('turn')
                if not isinstance(completed, dict) or completed.get('id') != turn['id']:
                    return
                state = completed.get('status')
                if state not in ('completed', 'failed', 'interrupted') or result['status'] is not None:
                    raise ValueError('invalid Codex turn completion')
                result['status'] = state
                error = completed.get('error')
                if isinstance(error, dict):
                    result['errorCode'] = error.get('codexErrorInfo')
                    if state == 'failed':
                        result['errorResetAt'] = reported_quota_reset(error, time.time())
            elif params.get('turnId') == turn['id']:
                if method == 'item/completed':
                    item = params.get('item')
                    if isinstance(item, dict) and item.get('type') == 'agentMessage':
                        text = item.get('text')
                        if not isinstance(text, str) or len(text.encode()) > MAX_MESSAGE_BYTES:
                            raise ValueError('invalid Codex agent message')
                        result['text'] = text
                elif method == 'thread/tokenUsage/updated':
                    usage = params.get('tokenUsage')
                    total = usage.get('total') if isinstance(usage, dict) else None
                    if not isinstance(total, dict):
                        raise ValueError('invalid Codex token usage')
                    counts = {}
                    for key in ('inputTokens', 'cachedInputTokens', 'outputTokens', 'totalTokens'):
                        value = total.get(key)
                        if type(value) is not int or value < 0 or value >= 2**63:
                            raise ValueError('invalid Codex token count')
                        counts[key] = value
                    if counts['cachedInputTokens'] > counts['inputTokens']:
                        raise ValueError('invalid Codex cached input count')
                    result['tokens'] = counts
                elif method == 'model/rerouted':
                    # A rerouted thread may contain multiple models. Do not
                    # assign all cumulative tokens to the initially chosen one.
                    result['model'] = None
        for message in early:
            consume(message)
        while result['status'] is None:
            consume(self.receive(deadline))
        # Drain prior notifications through a same-process account read. Never
        # turn a pre-launch observation into a receipt after an auth transition.
        after = self.call('account/read', {'refreshToken': False},
                          deadline=min(deadline, time.monotonic() + self.timeout), on_notification=consume)
        if (self._account_key(after) != self._bound_account
                or self.account_generation != self._bound_generation
                or self._subscription_provider(min(deadline, time.monotonic() + self.timeout)) != 'openai'):
            self._binding_failed = True
            raise RuntimeError('Codex account or route changed during execution')
        return result

    def close(self):
        self.stopping.set()
        if not self.own_process_group:
            # Execution children share the loop's tracked group. The loop owns
            # descendant cleanup, including when this wrapper is killed.
            try:
                self.process.terminate()
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
            self.reader.join(timeout=1)
            self.process.stdin.close()
            self.process.stdout.close()
            if self.reader.is_alive():
                raise RuntimeError('Codex protocol reader did not stop')
            return
        try:
            # The leader may have exited while a child still owns its pipes.
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError:
            # macOS can report EPERM for an already vanished process group.
            if self.process.poll() is None:
                raise
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=2)
        # A reaped leader does not prove its descendants stopped. They may
        # ignore TERM while retaining pipes or doing provider-side work.
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            if self.process.poll() is None:
                raise
        self.reader.join(timeout=1)
        self.process.stdin.close()
        self.process.stdout.close()
        if self.reader.is_alive():
            raise RuntimeError('Codex protocol reader did not stop')

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def _lock_supervisor():
    """Retain the inherited flock while the native process can mutate its home.

    This dedicated session survives a killed RPC caller. On child exit it kills
    its whole group before releasing the lock, including any pipe-owning child.
    TERM does not release the lock early; the caller escalates the whole group.
    """
    if len(sys.argv) < 6 or sys.argv[1] != '--lock-supervisor':
        raise SystemExit(2)
    fd = int(sys.argv[2])
    os.fstat(fd)
    deadline = float(sys.argv[3])
    if not math.isfinite(deadline):
        raise SystemExit(2)
    if os.getpgrp() != os.getpid():
        raise SystemExit(2)
    signal.signal(signal.SIGTERM, lambda *_: None)
    try:
        child = subprocess.Popen(sys.argv[4:], stdin=sys.stdin.buffer, stdout=sys.stdout.buffer,
                                 stderr=subprocess.DEVNULL, close_fds=True)
        child.wait(timeout=max(0, deadline-time.monotonic()))
    except subprocess.TimeoutExpired:
        pass
    finally:
        os.killpg(os.getpid(), signal.SIGKILL)


if __name__ == '__main__':
    _lock_supervisor()
