#!/usr/bin/env python3
"""Bounded stdio transport for N2's provider-native Codex operations.

The owner keeps this connection for the operation being attributed. Never treat
an account observation from a different CLI process as an execution receipt.
"""
import json
import os
import queue
import select
import signal
import subprocess
import threading
import time

MAX_MESSAGE_BYTES = 2 * 1024 * 1024
MAX_PENDING_MESSAGES = 128


class CodexRPC:
    def __init__(self, cfg, cwd, timeout=15, executable='codex'):
        self.timeout = timeout
        self.messages = queue.Queue(maxsize=MAX_PENDING_MESSAGES)
        self.stopping = threading.Event()
        self.failure = None
        self.next_id = 1
        self.account_generation = 0
        self.process = subprocess.Popen(
            [executable, 'app-server'], cwd=cwd, env=dict(os.environ, CODEX_HOME=cfg),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            start_new_session=True, bufsize=0)
        os.set_blocking(self.process.stdin.fileno(), False)
        os.set_blocking(self.process.stdout.fileno(), False)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _put(self, message):
        while not self.stopping.is_set():
            try:
                self.messages.put(message, timeout=0.1)
                return
            except queue.Full:
                pass

    def _read(self):
        pending = bytearray()
        descriptor = self.process.stdout.fileno()
        try:
            while not self.stopping.is_set():
                if not select.select([descriptor], [], [], 0.1)[0]:
                    continue
                try:
                    chunk = os.read(descriptor, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    self._put(None)
                    return
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
                        self._put(message)
                    if self.stopping.is_set():
                        return
                if len(pending) > MAX_MESSAGE_BYTES:
                    raise ValueError('Codex protocol message exceeds size limit')
        except (OSError, ValueError, RecursionError):
            # Store only a fixed diagnostic, never provider payload/credentials.
            self.failure = 'Codex protocol stream failed'
            self._put(None)

    def send(self, message, deadline=None):
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

    def receive(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Codex protocol read timed out')
        try:
            message = self.messages.get(timeout=remaining)
        except queue.Empty:
            raise TimeoutError('Codex protocol read timed out') from None
        if message is None:
            raise RuntimeError(self.failure or 'Codex protocol stream closed')
        if message.get('method') == 'account/updated':
            self.account_generation += 1
        return message

    def call(self, method, params=None, deadline=None, on_notification=None):
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
            if 'method' in message and 'id' in message:
                # Read-only calls must not grant approvals or provide secrets.
                # A future execution owner must explicitly handle such requests.
                raise RuntimeError('unexpected Codex server request')
            if on_notification is not None:
                on_notification(message)

    def initialize(self):
        self.call('initialize', {
            'clientInfo': {'name': 'n2_usage', 'version': '1.0.0'},
            'capabilities': {'experimentalApi': True}})
        self.send({'method': 'initialized'})

    def read_usage(self):
        deadline = time.monotonic() + self.timeout
        account_response = self.call('account/read', {'refreshToken': False}, deadline)
        account = account_response.get('account')
        if account is not None and not isinstance(account, dict):
            raise ValueError('invalid Codex account response')
        if not account or account.get('type') != 'chatgpt':
            return {'_native': True, '_status': 'no-token' if not account else 'no-usage-api', 'account': account}
        generation = self.account_generation
        result = self.call('account/rateLimits/read', deadline=deadline)
        after = self.call('account/read', {'refreshToken': False}, deadline)
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

    def close(self):
        self.stopping.set()
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
