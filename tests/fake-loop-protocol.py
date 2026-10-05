#!/usr/bin/env python3
"""Wrap synthetic loop behavior in documented Codex JSONL events."""
import json
import os
import re
import signal
import subprocess
import sys
import uuid

env = dict(os.environ)
env.pop('LOOP_FAKE_STRUCTURED', None)
prompt = sys.stdin.buffer.read()
# A slow worker records the TERM that stops it. This process leads the turn's
# group: the controller reaps it and then KILLs the rest, so the record is
# written here, before it exits, rather than by a descendant racing that KILL.
chunk = re.search(rb'^CHUNK: (\S+)', prompt, re.M)
scenario = os.environ.get('LOOP_FAKE', '')
if chunk and os.path.exists(os.path.join(scenario, 'slow')):
    name = chunk.group(1).decode()
    def terminated(*_):
        with open(os.path.join(scenario, 'terminated'), 'a') as record:
            record.write(name + '\n')
        os._exit(143)
    signal.signal(signal.SIGTERM, terminated)
    open(os.path.join(scenario, 'trapped-' + name), 'w').close()
result = subprocess.run(sys.argv[1:], input=prompt, capture_output=True, env=env)
print(json.dumps({'type': 'thread.started', 'thread_id': 'fixture-' + str(uuid.uuid4())}))
if result.returncode == 0:
    print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': result.stdout.decode()}}))
    print(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 50, 'cached_input_tokens': 30, 'output_tokens': 10}}))
else:
    print(json.dumps({'type': 'turn.failed', 'error': {'message': (result.stdout + result.stderr).decode()}}))
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
