#!/usr/bin/env python3
"""Actual signed prompt dispatch must keep its account through preparation."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('physical', REPO / 'scripts/test-physical-reconcile.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
base = Path(tempfile.mkdtemp(prefix='n2-prompt-binding-', dir='/private/tmp'))
os.chmod(base, 0o700)
for name in ('sender', 'receiver', 'repo', 'bin', 'tmp', 'ready'):
    (base / name).mkdir()
for source in REPO.iterdir():
    if source.is_file() and (source.name == 'agents' or source.suffix in ('.sh', '.py')):
        shutil.copy2(source, base / 'repo' / source.name)
if '--skip-account-pin' in sys.argv:
    runner = base/'repo/codex-run.py'
    check = "if identity.get('status') != 'verified' or identity.get('accountHash') != expected_account:"
    assert runner.read_text().count(check) == 1
    runner.write_text(runner.read_text().replace(check, 'if False:'))
source = base / 'repo/fleet-exec.sh'
point = '  exec_set_state "$erl_id" preparing\n'
assert source.read_text().count(point) == 1
source.write_text(source.read_text().replace(point, point + '  /usr/bin/python3 "$N2_BIND_ROOT/barrier.py" "$erl_id"\n'))
(base / 'barrier.py').write_text('''import os,select,sys
from pathlib import Path
root=Path(os.environ['N2_BIND_ROOT'])
fd=os.open(root/'gate',os.O_RDWR)
(root/'ready'/sys.argv[1]).touch()
assert select.select([fd],[],[],45)[0], 'preparation barrier timed out'
assert os.read(fd,1)==b'x'
os.close(fd)
''')
os.mkfifo(base / 'gate', 0o600)
provider = (REPO / 'tests/fake-bound-codex.py').read_text()
provider = provider.replace("    method = request['method']", """    method = request['method']
    credential = Path(os.environ['CODEX_HOME'])/'auth.json'
    token = current_token or (json.loads(credential.read_text())['tokens']['access_token'] if credential.exists() else '')
    if method == 'turn/start':
        root = Path(os.environ['N2_BIND_ROOT'])
        task = os.environ['N2_FLEET_TASK']
        (root/(task+'.turn')).write_text(json.dumps({'token':token,'cwd':os.getcwd(),'params':request['params']}))
        Path(os.environ['N2_FLEET_OUTPUTS'],'result.txt').write_text('deliverable')""")
provider = provider.replace("    elif method == 'account/rateLimits/read':", """        if token == 'after-token': result['account']['email'] = 'after@example.invalid'
        if token == 'unknown-token': result = {'account': {'type':'apiKey'}}
    elif method == 'account/rateLimits/read':""")
(base / 'bin/codex').write_text(provider)
(base / 'bin/codex').chmod(0o700)
(base / 'bin/security').write_text('#!/bin/sh\nexit 1\n')
(base / 'bin/security').chmod(0o700)
wrapper = base / 'wrapper'
wrapper.write_text(f'''#!/bin/sh
set -eu
case "$HOME" in {base}/sender|{base}/receiver) ;; *) exit 97;; esac
export N2_AGENTS_ROOT="$HOME/.n2-agents" N2_FLEET_AGENTS={wrapper}
export N2_BIND_ROOT={base} N2_BOUND_TRACE={base}/trace PATH={base}/bin:/usr/bin:/bin:/usr/sbin:/sbin N2_FLEET_NOTIFY=:
exec {base}/repo/agents "$@"
''')
wrapper.chmod(0o700)
raw = base / 'request.sh'
raw.write_text(f'#!/bin/sh\nroot=$HOME/.n2-agents\nself={base}/repo/agents\n. {base}/repo/fleet.sh\nfleet_call "$@"\n')


def env(home):
    return {'HOME': str(base/home), 'N2_FLEET_AGENTS':str(wrapper),
            'PATH':f'{base}/bin:/usr/bin:/bin:/usr/sbin:/sbin', 'TMPDIR':str(base/'tmp')}


def peer(home, *args):
    return helper.run([str(wrapper), *args], env=env(home))


def wait_ready(task):
    fd = os.open(base/'ready', os.O_RDONLY)
    try:
        with contextlib.closing(select.kqueue()) as queue:
            queue.control([select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE)], 0, 0)
            deadline = time.monotonic()+45
            while not (base/'ready'/task).exists():
                remaining = deadline-time.monotonic()
                assert remaining > 0 and queue.control(None, 1, remaining), 'preparation not reached'
    finally:
        os.close(fd)


def dispatch(task):
    bundle = io.BytesIO()
    with tarfile.open(fileobj=bundle, mode='w') as archive:
        for name, data in [('spec/command', b'fixture task'), ('spec/context', b'fixture context'),
                           ('spec/mode', b'prompt'), ('spec/requires', b'')]:
            info = tarfile.TarInfo(name); info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    payload = base/(task+'.request')
    payload.write_bytes(f'task={task}\nvendor=codex\nlabel=binding\n--\n'.encode()+base64.b64encode(bundle.getvalue())+b'\n')
    return subprocess.run(['/bin/sh',str(raw),receiver,'task-start',str(payload)],
                          env=env('sender'),capture_output=True,text=True,timeout=45)


def credential(profile, token):
    directory = base/'receiver/.n2-agents'/profile/'codex'
    directory.mkdir(parents=True, exist_ok=True)
    (directory/'auth.json').write_text(json.dumps({'tokens':{'access_token':token,'account_id':'workspace'}}))


sender = peer('sender','fleet','init','--machine','sender').split()[1]
receiver = peer('receiver','fleet','init','--machine','receiver').split()[1]
code = peer('sender','fleet','invite','--peer',receiver)
assert 'approved' in peer('receiver','fleet','pair','--home',str(base/'sender'),'--code',code)
for path in (base/'receiver/.n2-agents/fleet/peers').glob('*/meta'):
    if helper.metadata(path).get('peer') == sender:
        helper.patch(path, home=str(base/'absent-return-route'))
try:
    for task, change in [('1111aaaa',False),('2222bbbb',True)]:
        credential('Before','before-token'); credential('After','after-token')
        peer('receiver','use','Before','--vendor','codex')
        response = dispatch(task)
        assert response.returncode == 0 and 'accepted '+task in response.stdout, response.stderr
        wait_ready(task)
        directory = base/'receiver/.n2-agents/fleet/tasks/db'/task
        binding = json.loads((directory/'prompt-binding.json').read_text())
        assert set(binding) == {'root','profile','config','account'} and binding['profile'] == 'Before', binding
        assert binding['config'] == str(base/'receiver/.n2-agents/Before/codex'), binding
        if change: credential('Before','after-token')
        else: peer('receiver','use','After','--vendor','codex')
        fd = os.open(base/'gate',os.O_WRONLY | os.O_NONBLOCK)
        os.write(fd,b'x'); os.close(fd)
        directory = base/'receiver/.n2-agents/fleet/tasks/db'/task
        helper.wait_state(directory/'meta','terminal')
        meta = helper.metadata(directory/'meta')
        if change:
            assert meta['state'] == 'failed' and meta['rc'] != '0', meta
            assert not (base/(task+'.turn')).exists(), 'changed account executed a turn'
        else:
            assert meta['state'] == 'completed' and meta['rc'] == '0', meta
            turn = json.loads((base/(task+'.turn')).read_text())
            assert turn['token'] == 'before-token', turn
            assert turn['cwd'] == str(base/'receiver/.n2-agents/fleet/tasks/work'/task), turn
            prompt = json.dumps(turn['params'])
            assert 'fixture task' in prompt and 'fixture context' in prompt, prompt
            assert (directory/'out/artifacts/result.txt').read_text() == 'deliverable'
            events = [json.loads(line) for line in (directory/'out/stdout').read_text().splitlines()]
            receipts = [e for e in events if e['type'] == 'n2.account.binding']
            assert len(receipts) == 1 and receipts[0]['identity']['accountHash'] == binding['account'], events
    credential('Before','unknown-token'); peer('receiver','use','Before','--vendor','codex')
    response = dispatch('3333cccc')
    assert response.returncode != 0 and 'account-binding-unavailable' in response.stderr, response
    assert not (base/'3333cccc.turn').exists()
    print('ok signed prompt dispatch: frozen profile, account mismatch refusal, unverified admission refusal, stdin/cwd/deliverables/exit')
finally:
    print(f'Isolated fixture retained: {base}', flush=True)
