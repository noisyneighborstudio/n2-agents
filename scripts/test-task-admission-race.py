#!/usr/bin/env python3
"""Two signed deliveries must admit one real synthetic command, never two."""
import base64
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import select
import shutil
import subprocess
import tarfile
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('physical', REPO / 'scripts/test-physical-reconcile.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
base = Path(tempfile.mkdtemp(prefix='n2-task-admission-', dir='/private/tmp'))
os.chmod(base, 0o700)
for name in ('sender', 'receiver', 'repo', 'bin', 'tmp', 'arrivals', 'runs', 'cleanup'):
    (base / name).mkdir()
for name in helper.run(['git', 'ls-files'], cwd=REPO).splitlines():
    if '/' not in name and (name == 'agents' or name.endswith(('.sh', '.py'))):
        shutil.copy2(REPO / name, base / 'repo' / name)
launch = '  exec_run_local "$hts_id" </dev/null >"$hts_d/worker.log" 2>&1 &'
source = base / 'repo/fleet-exec.sh'
assert source.read_text().count(launch) == 1
# Record parent-side launch admission so late child scheduling cannot conceal
# a second invocation. The worker still executes the real submitted command.
source.write_text(source.read_text().replace(launch,
    '  printf "%s\\n" "$hts_id" >> "$N2_RACE_ROOT/launches"\n' + launch))
wrapper = base / 'wrapper'
wrapper.write_text(f'''#!/bin/sh
set -eu
case "$HOME" in {base}/sender|{base}/receiver) ;; *) exit 97;; esac
export N2_AGENTS_ROOT="$HOME/.n2-agents" N2_FLEET_AGENTS={wrapper}
export N2_RACE_ROOT={base} PATH={base}/bin:/usr/bin:/bin:/usr/sbin:/sbin N2_FLEET_NOTIFY=:
exec {base}/repo/agents "$@"
''')
wrapper.chmod(0o700)
(base / 'bin/security').write_text('#!/bin/sh\nexit 1\n')
(base / 'bin/security').chmod(0o700)
# Gate only the first creation attempts for this task, before invoking the real
# mkdir. Both old callers have then already observed that the task is absent.
(base / 'bin/mkdir').write_text('''#!/usr/bin/python3
import os,select,sys
from pathlib import Path
root=Path(os.environ['N2_RACE_ROOT'])
target=str(root/'receiver/.n2-agents/fleet/tasks/db/aabbccdd')
if target in sys.argv[1:] and not (root/'released').exists():
 fd=os.open(root/'gate',os.O_RDWR)
 (root/'arrivals'/str(os.getpid())).touch()
 assert select.select([fd],[],[],30)[0],'admission barrier timeout'
 assert os.read(fd,1)==b'x'
 os.close(fd)
os.execv('/bin/mkdir',['mkdir']+sys.argv[1:])
''')
(base / 'bin/mkdir').chmod(0o700)
os.mkfifo(base / 'gate', 0o600)
os.mkfifo(base / 'cleanup-gate', 0o600)
(base / 'bin/rm').write_text('''#!/usr/bin/python3
import os,select,subprocess,sys
from pathlib import Path
root=Path(os.environ['N2_RACE_ROOT'])
target=str(root/'receiver/.n2-agents/fleet/tasks/work/eeff0011')
if target in sys.argv[1:] and (root/'hold-cleanup').exists():
 options=[arg for arg in sys.argv[1:] if arg.startswith('-')]
 for path in [arg for arg in sys.argv[1:] if not arg.startswith('-')]:
  if path==target:
   fd=os.open(root/'cleanup-gate',os.O_RDWR)
   (root/'cleanup/ready').touch()
   assert select.select([fd],[],[],30)[0],'cleanup barrier timeout'
   assert os.read(fd,1)==b'x'
   os.close(fd)
  subprocess.run(['/bin/rm']+options+[path],check=True)
 sys.exit(0)
os.execv('/bin/rm',['rm']+sys.argv[1:])
''')
(base / 'bin/rm').chmod(0o700)

(base / 'worker.py').write_text('''import os
from pathlib import Path
root=Path(os.environ['N2_RACE_ROOT'])/'runs'/os.environ['N2_FLEET_TASK']
(root/str(os.getpid())).write_text('executed\\n')
''')
raw = base / 'request.sh'
raw.write_text(f'''#!/bin/sh
root=$HOME/.n2-agents
self={base}/repo/agents
. {base}/repo/fleet.sh
fleet_call "$@"
''')


def environment(home):
    return {'HOME': str(base / home), 'N2_FLEET_AGENTS': str(wrapper),
            'N2_RACE_ROOT': str(base), 'PATH': f'{base}/bin:/usr/bin:/bin:/usr/sbin:/sbin',
            'TMPDIR': str(base / 'tmp')}


def peer(home, *args):
    return helper.run([str(wrapper), *args], env=environment(home))


def wait_count(directory, count):
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        with contextlib.closing(select.kqueue()) as queue:
            queue.control([select.kevent(descriptor, filter=select.KQ_FILTER_VNODE,
                           flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                           fflags=select.KQ_NOTE_WRITE)], 0, 0)
            deadline = time.monotonic() + 30
            while len(list(directory.iterdir())) < count:
                remaining = deadline - time.monotonic()
                assert remaining > 0 and queue.control(None, 1, remaining), directory
    finally:
        os.close(descriptor)


def payload(task, valid=True):
    path = base / (task + ('-valid' if valid else '-invalid'))
    command = f'/usr/bin/python3 {base}/worker.py\n'.encode()
    bundle = io.BytesIO()
    if valid:
        with tarfile.open(fileobj=bundle, mode='w') as archive:
            for name, data in [('spec/command', command), ('spec/mode', b'shell\n'),
                               ('spec/context', b''), ('spec/requires', b'')]:
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
    path.write_bytes(f'task={task}\nvendor=cursor\nlabel=admission\n--\n'.encode()
                     + base64.b64encode(bundle.getvalue()) + b'\n')
    return path


def request(path):
    child = subprocess.Popen(['/bin/sh', str(raw), receiver, 'task-start', str(path)],
                             env=environment('sender'), stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
    children.append(child)
    return child


sender = peer('sender', 'fleet', 'init', '--machine', 'sender').split()[1]
receiver = peer('receiver', 'fleet', 'init', '--machine', 'receiver').split()[1]
code = peer('sender', 'fleet', 'invite', '--peer', receiver)
assert 'approved' in peer('receiver', 'fleet', 'pair', '--home', str(base / 'sender'), '--code', code)
for path in (base / 'receiver/.n2-agents/fleet/peers').glob('*/meta'):
    if helper.metadata(path).get('peer') == sender:
        helper.patch(path, home=str(base / 'absent-return-route'))
children = []
try:
    task = 'aabbccdd'
    (base / 'runs' / task).mkdir()
    document = payload(task)
    children = [request(document), request(document)]
    wait_count(base / 'arrivals', 2)
    (base / 'released').touch()
    descriptor = os.open(base / 'gate', os.O_WRONLY | os.O_NONBLOCK)
    os.write(descriptor, b'xx')
    os.close(descriptor)
    replies = [child.communicate(timeout=30) for child in children]
    launches = (base / 'launches').read_text().splitlines()
    wait_count(base / 'runs' / task, len(launches))
    executions = len(list((base / 'runs' / task).iterdir()))
    print(f'signed concurrent deliveries: {len(launches)} launches, {executions} executions', flush=True)
    assert launches == [task] and executions == 1, (launches, executions)
    assert any(child.returncode == 0 and 'accepted ' + task in reply[0]
               for child, reply in zip(children, replies)), replies
    for child, (out, err) in zip(children, replies):
        assert (child.returncode == 0 and 'accepted ' + task in out) or (
            child.returncode != 0 and 'ERR task-pending' in err), (out, err)
    retry = request(document)
    out, err = retry.communicate(timeout=30)
    assert retry.returncode == 0 and 'accepted ' + task in out, (out, err)
    assert (base / 'launches').read_text().splitlines() == [task]
    # An interrupted, unpublished reservation must never claim acceptance.
    incomplete = base / 'receiver/.n2-agents/fleet/tasks/db/11223344'
    incomplete.mkdir()
    pending = request(payload('11223344'))
    out, err = pending.communicate(timeout=30)
    assert pending.returncode != 0 and 'ERR task-pending' in err, (out, err)
    assert not (incomplete / 'meta').exists()
    assert (base / 'launches').read_text().splitlines() == ['aabbccdd']
    # A failed initial publication may be retried; it must not look accepted.
    task = 'eeff0011'
    (base / 'runs' / task).mkdir()
    (base / 'hold-cleanup').touch()
    bad = request(payload(task, valid=False))
    wait_count(base / 'cleanup', 1)
    concurrent_retry = request(payload(task))
    retry_out, retry_err = concurrent_retry.communicate(timeout=30)
    print('retry during cleanup:', concurrent_retry.returncode, retry_out, retry_err, flush=True)
    assert concurrent_retry.returncode != 0 and 'ERR task-pending' in retry_err
    descriptor = os.open(base / 'cleanup-gate', os.O_WRONLY | os.O_NONBLOCK)
    os.write(descriptor, b'x')
    os.close(descriptor)
    out, err = bad.communicate(timeout=30)
    assert bad.returncode != 0 and 'ERR empty-bundle' in err, (out, err)
    assert not (base / 'receiver/.n2-agents/fleet/tasks/db' / task).exists()
    good = request(payload(task))
    out, err = good.communicate(timeout=30)
    assert good.returncode == 0 and 'accepted ' + task in out, (out, err)
    wait_count(base / 'runs' / task, 1)
    assert (base / 'launches').read_text().splitlines() == ['aabbccdd', task]
    print('idempotent repeat and retry after failed initialization passed')
finally:
    (base / 'released').touch()
    for name in ('gate', 'cleanup-gate'):
        try:
            descriptor = os.open(base / name, os.O_WRONLY | os.O_NONBLOCK)
        except OSError:
            continue
        os.write(descriptor, b'xx')
        os.close(descriptor)
    for child in children:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
    print(f'Isolated fixture retained: {base}')
