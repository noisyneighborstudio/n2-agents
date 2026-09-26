#!/usr/bin/env python3
"""One account-bound, headless Codex turn for the N2 loop.

The canonical credential file is read only. External authentication belongs to
one disposable app-server process; it never falls back to another account.
"""
import argparse
import contextlib
import datetime
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def emit(value):
    print(json.dumps(value, allow_nan=False, separators=(',', ':')), flush=True)


def private_copy(source, destination):
    if not source.exists():
        return
    if not source.is_file() or source.stat().st_size > 2 * 1024 * 1024:
        raise ValueError('unsupported Codex configuration file')
    with source.open("rb") as stream:
        data = stream.read(2 * 1024 * 1024 + 1)
    if len(data) > 2 * 1024 * 1024:
        raise ValueError('Codex configuration file grew during read')
    with open(destination, 'xb') as out:
        os.chmod(destination, 0o600)
        out.write(data)


def prepare_home(source, target):
    # Keep N2's selected configuration and user-owned resources. Never link the
    # account credential store, sessions, locks, or whole Codex home.
    for name in ('config.toml', 'AGENTS.md', 'AGENTS.override.md', 'managed_config.toml'):
        private_copy(source / name, target / name)
    for name in ('rules', 'skills', 'plugins'):
        resource = source / name
        if resource.exists():
            if not resource.is_dir():
                raise ValueError('unsupported Codex resource directory')
            (target / name).symlink_to(resource.resolve(), target_is_directory=True)


def failure_message(code):
    if code in ('usageLimitExceeded', 'rateLimitExceeded'):
        return 'Codex usage limit reached'
    if code == 'unauthorized':
        return 'Codex authentication failed'
    if code in ('serverOverloaded', 'internalServerError'):
        return 'Codex service unavailable'
    return 'Codex turn did not complete'


def run(config, expected_account, effort, prompt, timeout=3600, executable='codex', own_process_group=True, execution_home=None, owner_root=None, profile_name=None):
    if not re.fullmatch('[0-9a-f]{64}', expected_account):
        raise ValueError('invalid expected account')
    source = Path(config).resolve(strict=True)
    owner_client = None
    marker = source / '.n2-owner.json'
    if marker.exists() or marker.is_symlink():
        broker = load('n2_owner_client', 'fleet-auth-client.py')
        owner_client = broker.for_profile(owner_root, source, profile_name, expected_account)
    else:
        credential = source / 'auth.json'
        if not credential.is_file() or credential.stat().st_size > 2 * 1024 * 1024:
            raise ValueError('Codex file credential unavailable')
        with credential.open('rb') as stream:
            raw = stream.read(2 * 1024 * 1024 + 1)
        if len(raw) > 2 * 1024 * 1024:
            raise ValueError('Codex credential file grew during read')
        saved = json.loads(raw)
        tokens = saved.get('tokens') if isinstance(saved, dict) else None
        if not isinstance(tokens, dict):
            raise ValueError('Codex subscription credential unavailable')
        token, account = tokens.get('access_token'), tokens.get('account_id')
        if not isinstance(token, str) or not token or not isinstance(account, str) or not account:
            raise ValueError('Codex subscription credential unavailable')
    rpc = load('n2_codex_rpc', 'codex-rpc.py')
    usage = load('n2_usage', 'usage.py')
    if execution_home is not None:
        owned_home = Path(execution_home)
        metadata = owned_home.lstat()
        if (owned_home.is_symlink() or not owned_home.is_dir() or metadata.st_uid != os.getuid()
                or metadata.st_mode & 0o077 or any(p.name != 'process-group' for p in owned_home.iterdir())):
            raise ValueError('execution home must be an empty private owned directory')
    context = contextlib.nullcontext(execution_home) if execution_home is not None else tempfile.TemporaryDirectory(prefix='n2-codex-turn-')
    with context as directory:
        home = Path(directory)
        prepare_home(source, home)
        with contextlib.ExitStack() as stack:
            if owner_client:
                client, observation = stack.enter_context(owner_client.connection(str(home), os.getcwd(),
                    time.monotonic()+20, executable=executable, own_process_group=own_process_group))
            else:
                client = stack.enter_context(rpc.CodexRPC(str(home), os.getcwd(), executable=executable,
                    ephemeral_auth=True, own_process_group=own_process_group))
                client.initialize()
                observation = client.pin_external_account(token, account)
            identity = usage.details('codex', observation)['identity']
            if identity.get('status') != 'verified' or identity.get('accountHash') != expected_account:
                raise RuntimeError('selected Codex account changed before execution')
            result = client.run_bound_turn(prompt, effort=effort, timeout=timeout)
    emit({'type': 'thread.started', 'thread_id': result['threadId']})
    emit({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': result['text']}})
    if result['status'] == 'completed':
        counts = result['tokens'] or {}
        emit({'type': 'turn.completed', 'usage': {
            'input_tokens': counts.get('inputTokens'), 'cached_input_tokens': counts.get('cachedInputTokens'),
            'output_tokens': counts.get('outputTokens')}})
    else:
        message = failure_message(result['errorCode'])
        if result['errorResetAt'] is not None:
            reset = datetime.datetime.fromtimestamp(result['errorResetAt'], datetime.timezone.utc).isoformat(timespec='microseconds')
            message += '\nTry again at ' + reset
        emit({'type': 'turn.failed', 'error': {'message': message}})
    emit({'type': 'n2.account.binding', 'identity': {'status': 'verified', 'accountHash': expected_account},
          'session': result['threadId'], 'turn': result['turnId'], 'model': result['model'],
          'usageScope': 'provider-thread', 'tokens': result['tokens'], 'quotaResetAt': result['errorResetAt']})
    return 0 if result['status'] == 'completed' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--expected-account', required=True)
    parser.add_argument('--shared-process-group', action='store_true')
    parser.add_argument('--execution-home')
    parser.add_argument('--owner-root')
    parser.add_argument('--profile-name')
    parser.add_argument('--effort', choices=('low', 'medium', 'high'), default='medium')
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupted)
    try:
        if args.shared_process_group:
            if not args.execution_home:
                raise ValueError('tracked execution requires an owner home')
            marker = Path(args.execution_home) / 'process-group'
            deadline = time.monotonic() + 10
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            if marker.read_text() != str(os.getpid()) or os.getpgrp() != os.getpid():
                raise ValueError('execution group has not been recorded by its owner')
        prompt = sys.stdin.read(1024 * 1024 + 1)
        if not prompt or len(prompt.encode()) > 1024 * 1024:
            raise ValueError('invalid prompt size')
        return run(args.config, args.expected_account, args.effort, prompt, own_process_group=not args.shared_process_group, execution_home=args.execution_home, owner_root=args.owner_root, profile_name=args.profile_name)
    except Exception as error:
        # Provider/configuration exceptions may contain secrets. Only a fixed
        # diagnostic crosses stdout/stderr; never emit a guessed account receipt.
        diagnostics = {
            'Codex file credential unavailable': 'Codex authentication failed: the selected file credential is unavailable',
            'Codex subscription credential unavailable': 'Codex authentication failed: the selected subscription credential is unavailable',
            'selected Codex account changed before execution': 'Codex authentication failed: the selected account changed before execution',
            'bound Codex account requires renewal': 'Codex authentication failed: the bound token requires renewal',
            'unexpected Codex server request': 'Action required: Codex requested host interaction during a bound turn',
            'action required: unexpected Codex server request': 'Action required: Codex requested host interaction during a bound turn',
        }
        message = diagnostics.get(str(error), 'Codex account-bound execution unavailable; no fallback attempted')
        emit({'type': 'turn.failed', 'error': {'message': message}})
        return 1


if __name__ == '__main__':
    sys.exit(main())
