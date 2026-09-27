#!/usr/bin/env python3
"""Capture receiver binding before admission; execute only that Codex account."""
import importlib.util
import json
import os
from pathlib import Path
import sys

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


def main():
    if sys.argv[1] == 'capture':
        capture(*sys.argv[2:])
    elif sys.argv[1] == 'run' and len(sys.argv) == 3:
        binding = json.loads(Path(sys.argv[2]).read_text())
        os.execv(sys.executable, [sys.executable, str(HERE/'codex-run.py'),
            '--config', binding['config'], '--expected-account', binding['account'],
            '--owner-root', binding['root'], '--profile-name', binding['profile']])
    else:
        raise ValueError('invalid operation')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Codex prompt account binding unavailable; no fallback attempted', file=sys.stderr)
        sys.exit(125)
