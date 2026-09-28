#!/usr/bin/env python3
"""Fresh Claude fleet invocation accounting; execution identity remains unknown."""
import importlib.util
import contextlib
import json
import math
import select
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import threading

COUNTERS = ('inputTokens', 'outputTokens', 'cachedInputTokens', 'cacheCreationInputTokens',
            'uncachedInputTokens', 'totalTokens')


def counts(value, keys):
    values = [value.get(key) for key in keys]
    if any(type(n) is not int or not 0 <= n < 2**63 for n in values):
        raise ValueError('unavailable counts')
    uncached, output, read, created = values
    total_input = uncached + read + created
    if total_input + output >= 2**63:
        raise ValueError('counter overflow')
    return dict(zip(COUNTERS, (total_input, output, read, created, uncached, total_input+output)))


def usage(result):
    unknown = dict.fromkeys(COUNTERS)
    # Crash results can contain zeroed placeholders, not measured zero work.
    if result.get('subtype') == 'error_during_execution':
        return unknown, {}, 'unknown'
    try:
        if 'modelUsage' in result:
            models = result['modelUsage']
            if not isinstance(models, dict) or not 0 < len(models) <= 64:
                raise ValueError('invalid models')
            converted = {}
            for model, value in models.items():
                if not isinstance(model, str) or not model or len(model) > 128 or not isinstance(value, dict):
                    raise ValueError('invalid model')
                converted[model] = counts(value, ('inputTokens', 'outputTokens', 'cacheReadInputTokens', 'cacheCreationInputTokens'))
            aggregate = {k: sum(v[k] for v in converted.values()) for k in COUNTERS}
            if any(v >= 2**63 for v in aggregate.values()):
                raise ValueError('counter overflow')
            return aggregate, converted, 'invocation-tree'
        raw = result.get('usage')
        if not isinstance(raw, dict):
            raise ValueError('missing usage')
        return counts(raw, ('input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')), {}, 'main-agent'
    except ValueError:
        return unknown, {}, 'unknown'


def supervise(lifetime, command):
    # Preserve provider status/stderr while fencing all provider descendants.
    ready, notify = os.pipe()
    child = None
    def wake(*_):
        with contextlib.suppress(OSError): os.write(notify, b'x')
    signal.signal(signal.SIGTERM, wake)
    signal.signal(signal.SIGINT, wake)
    try:
        child = subprocess.Popen(command, start_new_session=True)
        threading.Thread(target=lambda: (child.wait(), wake()), daemon=True).start()
        select.select([int(lifetime), ready], [], [])
    finally:
        if child is not None:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try: os.killpg(child.pid, sig)
                except ProcessLookupError: pass
                except PermissionError:
                    if child.poll() is None: raise
                if sig == signal.SIGTERM:
                    try: child.wait(timeout=2)
                    except subprocess.TimeoutExpired: pass
            child.wait()
        os.close(ready); os.close(notify)
    return child.returncode if child.returncode >= 0 else 128-child.returncode


def run(binding, origin):
    spec = importlib.util.spec_from_file_location('n2_claude_store', Path(__file__).with_name('usage-store.py'))
    store = importlib.util.module_from_spec(spec); spec.loader.exec_module(store)
    if str(Path(binding['config']).resolve(strict=True)) != binding['target']:
        raise ValueError('accepted configuration target changed')
    journal = store.Journal(binding['root'], origin)
    task = os.environ['N2_FLEET_TASK']
    started = time.time()
    base = dict(identity={'status': 'unknown'}, source='n2-fleet', startedAt=started)
    child, pending, writer = None, [], None
    def interrupted(signum, frame):
        pending.append(signum)
        if child is not None:
            raise SystemExit(128+signum)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    try:
        journal.append('claude', binding['profile'], 'execution-started', dict(base,
            status='execution-unconfirmed', usageScope='unknown', attribution=dict.fromkeys(COUNTERS) | {'task': task}))
        environment = dict(os.environ, CLAUDE_CONFIG_DIR=binding['config'])
        if pending: raise SystemExit(128+pending[0])
        reader, writer = os.pipe()
        try:
            child = subprocess.Popen([sys.executable, __file__, '--supervise', str(reader),
                'claude', '--print', '--verbose', '--output-format', 'stream-json'],
                stdin=sys.stdin, stdout=subprocess.PIPE, env=environment, pass_fds=(reader,))
        finally: os.close(reader)
        if pending: raise SystemExit(128+pending[0])
        results, initial, rejections, malformed = [], None, {}, False
        def selection():
            model = initial.get('model') if initial else None
            return model if isinstance(model, str) and 0 < len(model) <= 128 else None
        for raw in iter(lambda: child.stdout.readline(1024*1024+1), b''):
            sys.stdout.buffer.write(raw); sys.stdout.buffer.flush()
            if len(raw) > 1024*1024:
                malformed = True; continue
            try:
                event = json.loads(raw)
                if not isinstance(event, dict):
                    raise ValueError('not an event')
            except (ValueError, UnicodeDecodeError):
                malformed = True; continue
            if event.get('type') == 'system' and event.get('subtype') == 'init':
                if initial is not None:
                    malformed = True
                initial = event
            elif event.get('type') == 'result':
                if len(results) < 2: results.append(event)
                else: malformed = True
            elif event.get('type') == 'rate_limit_event':
                info = event.get('rate_limit_info')
                if isinstance(info, dict) and info.get('status') == 'rejected':
                    scope = info.get('rateLimitType')
                    if scope not in ('five_hour', 'seven_day', 'seven_day_opus', 'seven_day_sonnet', 'overage'):
                        scope = 'unknown'
                    reset = info.get('resetsAt')
                    if type(reset) not in (int, float) or not math.isfinite(reset) or not time.time() < reset <= time.time()+366*86400:
                        reset = None
                    if scope in rejections and rejections[scope] == reset: continue
                    rejections[scope] = reset
                    known = all(v is not None for v in rejections.values())
                    # Denial is evidence even if the process never emits a result.
                    journal.append('claude', binding['profile'], 'quota-rejected', dict(base,
                        status='restricted', requestedModel=selection(), usageScope='unknown',
                        resetKnown=known, recheckAt=max(rejections.values()) if known else None,
                        restrictions=[{'scope': k, 'reason': 'quota-rejected', 'resetsAt': v} for k,v in rejections.items()],
                        attribution=dict.fromkeys(COUNTERS) | {'task': task}))
        code = child.wait()
        if malformed or len(results) != 1:
            return code
        result = results[0]
        session = result.get('session_id')
        subtype = result.get('subtype')
        is_error = result.get('is_error')
        if (not isinstance(session, str) or not session or len(session) > 128
                or type(is_error) is not bool
                or subtype not in ('success', 'error_during_execution', 'error_max_turns',
                                   'error_max_budget_usd', 'error_max_structured_output_retries')
                or (initial is not None and initial.get('session_id') != session)
                or (code == 0) != (subtype == 'success' and not is_error)):
            return code
        totals, models, scope = usage(result)
        quota = is_error and (bool(rejections) or result.get('api_error_status') == 429)
        if quota and not rejections: rejections['unknown'] = None
        known = quota and all(v is not None for v in rejections.values())
        journal.append('claude', binding['profile'], 'quota-rejected' if quota else (
            'execution-succeeded' if code == 0 else 'execution-failed'), dict(base,
            status='restricted' if quota else 'ok' if code == 0 else 'execution-failed',
            session=session, requestedModel=selection(), model=next(iter(models)) if len(models)==1 else None,
            modelUsage=models, usageScope=scope, resetKnown=known, recheckAt=max(rejections.values()) if known else None,
            restrictions=[{'scope': k, 'reason': 'quota-rejected', 'resetsAt': v} for k,v in rejections.items()] if quota else [],
            attribution=dict(totals, task=task)))
        return code
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM): signal.signal(sig, signal.SIG_IGN)
        if child is not None:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
            child.stdout.close()
        if writer is not None: os.close(writer)
        journal.db.close()


def main():
    if sys.argv[1] == '--supervise':
        return supervise(sys.argv[2], sys.argv[3:])
    if sys.argv[1] == 'capture' and len(sys.argv) == 6:
        _, _, destination, root, profile, config = sys.argv
        target = Path(config).resolve(strict=True)
        if not target.is_dir(): raise ValueError('configuration is not a directory')
        binding = dict(root=root, profile=profile, config=config, target=str(target))
        with open(destination, 'x') as output:
            os.chmod(destination, 0o600); json.dump(binding, output)
    elif sys.argv[1] == 'run' and len(sys.argv) == 4:
        return run(json.loads(Path(sys.argv[2]).read_text()), sys.argv[3])
    else:
        raise ValueError('invalid operation')


if __name__ == '__main__':
    try: sys.exit(main())
    except Exception:
        print('Claude fleet route or usage unavailable; no fallback attempted', file=sys.stderr)
        sys.exit(125)
