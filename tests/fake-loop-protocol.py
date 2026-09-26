#!/usr/bin/env python3
"""Wrap synthetic loop behavior in documented Codex JSONL events."""
import json
import os
import subprocess
import sys
import uuid

env = dict(os.environ)
env.pop('LOOP_FAKE_STRUCTURED', None)
result = subprocess.run(sys.argv[1:], input=sys.stdin.buffer.read(), capture_output=True, env=env)
print(json.dumps({'type': 'thread.started', 'thread_id': 'fixture-' + str(uuid.uuid4())}))
if result.returncode == 0:
    print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': result.stdout.decode()}}))
    print(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 50, 'cached_input_tokens': 30, 'output_tokens': 10}}))
else:
    print(json.dumps({'type': 'turn.failed', 'error': {'message': (result.stdout + result.stderr).decode()}}))
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
