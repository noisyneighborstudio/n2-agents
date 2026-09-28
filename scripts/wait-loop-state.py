#!/usr/bin/env python3
"""Wait for atomic loop state replacements on macOS; timeouts only fail."""
from contextlib import closing
import datetime
import json
import os
from pathlib import Path
import select
import sys
import time

path, expected = Path(sys.argv[1]), sys.argv[2]
deadline = time.monotonic() + 120
fd = os.open(path.parent, os.O_RDONLY)
state = {}
try:
    with closing(select.kqueue()) as queue:
        queue.control([select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                      flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                      fflags=select.KQ_NOTE_WRITE)], 0)
        while True:
            state = json.loads(path.read_text())
            if state['status'] == expected:
                if expected == 'WAITING':
                    reset = datetime.datetime.fromisoformat(state['retryAt'].replace('Z', '+00:00'))
                    assert reset > datetime.datetime.now(datetime.timezone.utc), 'retry deadline already elapsed'
                break
            if state['status'] in ('DONE', 'PAUSED') or time.monotonic() >= deadline:
                raise AssertionError('loop did not reach ' + expected)
            queue.control(None, 1, max(0, deadline - time.monotonic()))
except Exception:
    print(json.dumps({'expected': expected, 'state': state}), file=sys.stderr)
    raise
finally:
    os.close(fd)
