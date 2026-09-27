#!/usr/bin/env python3
"""Capture receiver binding before admission; execute only that Codex account."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import signal
import time

HERE = Path(__file__).resolve().parent


def capture(destination, root, profile, config):
    spec = importlib.util.spec_from_file_location('n2_prompt_usage', HERE/'usage.py')
    usage = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(usage)
    config = str(Path(config).resolve(strict=True))
    os.environ['N2_USAGE_ROOT'] = root
    status, observe = usage.codex(profile, config)
    if status != 'ok' or not callable(observe):
        raise ValueError('binding unavailable')
    identity = usage.details('codex', observe())['identity']
    if identity.get('status') != 'verified' or not identity.get('accountHash'):
        raise ValueError('binding unavailable')
    binding = dict(root=root, profile=profile, config=config, account=identity['accountHash'])
    # Task admission owns this unpublished directory. Never replace a binding.
    with open(destination, 'x') as output:
        os.chmod(destination, 0o600)
        json.dump(binding, output)


def run(binding, origin):
    def load(name, file):
        spec = importlib.util.spec_from_file_location(name, HERE/file)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    runner = load('n2_fleet_runner', 'codex-run.py')
    store = load('n2_fleet_journal', 'usage-store.py')
    prompt = sys.stdin.read(1024*1024+1)
    if not prompt or len(prompt.encode()) > 1024*1024:
        raise ValueError('invalid prompt')
    task = os.environ['N2_FLEET_TASK']
    counts = dict.fromkeys(('inputTokens','cachedInputTokens','outputTokens','totalTokens'))
    started = time.time()
    journal = store.Journal(binding['root'], origin)
    receipts = []
    original_emit = runner.emit
    def emit(value):
        # These are the bound runner's structured records, never parsed model text.
        if value.get('type') == 'n2.account.binding':
            receipts.append(value)
        original_emit(value)
    runner.emit = emit
    def interrupted(signum, frame):
        raise SystemExit(128+signum)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    try:
        # A killed process or missing terminal receipt leaves this durable unknown.
        journal.append('codex', binding['profile'], 'execution-started', {
            'status':'execution-unconfirmed', 'identity':{'status':'unknown'},
            'source':'n2-fleet', 'startedAt':started, 'usageScope':'provider-thread',
            'attribution':dict(counts, task=task)})
        code = runner.run(binding['config'], binding['account'], 'medium', prompt,
                          owner_root=binding['root'], profile_name=binding['profile'])
        if len(receipts) != 1:
            return code
        receipt = receipts[0]
        identity = receipt.get('identity', {})
        state = receipt.get('status')
        if (identity != {'status':'verified','accountHash':binding['account']}
                or receipt.get('usageScope') != 'provider-thread'
                or state not in ('completed','failed','interrupted')
                or (code == 0) != (state == 'completed')
                or not isinstance(receipt.get('session'),str) or not receipt['session']
                or not isinstance(receipt.get('turn'),str) or not receipt['turn']):
            raise ValueError('invalid terminal binding')
        if receipt.get('tokens') is not None:
            tokens = receipt['tokens']
            if (not isinstance(tokens,dict) or set(tokens) != set(counts)
                    or any(type(v) is not int or not 0 <= v < 2**63 for v in tokens.values())
                    or tokens['cachedInputTokens'] > tokens['inputTokens']):
                raise ValueError('invalid terminal counters')
            counts = tokens
        quota = state == 'failed' and receipt.get('errorCode') in ('usageLimitExceeded','rateLimitExceeded')
        reset = receipt.get('quotaResetAt') if quota else None
        journal.append('codex', binding['profile'], 'quota-rejected' if quota else (
            'execution-succeeded' if code == 0 else 'execution-failed'), {
            'status':'restricted' if quota else ('ok' if code == 0 else 'execution-failed'),
            'identity':identity, 'source':'n2-fleet', 'session':receipt['session'],
            'model':receipt.get('model'), 'requestedModel':receipt.get('requestedModel'),
            'usageScope':'provider-thread', 'startedAt':started,
            'resetKnown':reset is not None, 'recheckAt':reset,
            'restrictions':[{'scope':'unknown','reason':'quota-rejected'}] if quota else [],
            'attribution':dict(counts,task=task)})
        return code
    finally:
        journal.db.close()


def main():
    if sys.argv[1] == 'capture':
        capture(*sys.argv[2:])
    elif sys.argv[1] == 'run' and len(sys.argv) == 4:
        return run(json.loads(Path(sys.argv[2]).read_text()), sys.argv[3])
    else:
        raise ValueError('invalid operation')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print('Codex prompt account binding or usage receipt unavailable; no fallback attempted', file=sys.stderr)
        sys.exit(125)
