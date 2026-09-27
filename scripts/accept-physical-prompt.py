#!/usr/bin/env python3
"""Actual signed Codex dispatch and usage exchange over disposable SSH peers."""
import argparse
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time


def load(path):
    spec = importlib.util.spec_from_file_location('physical', path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def fixture(root, mode, value):
    root = Path(root)
    helper = load(root/'physical.py')
    if mode == 'credential':
        path = root/'beta/.n2-agents/Before/codex/auth.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'tokens':{'access_token':value,'account_id':'workspace'}}))
    elif mode == 'wait':
        path = root/'beta/.n2-agents/fleet/tasks/db'/value/'meta'
        helper.wait_state(path, 'terminal')
        print(json.dumps(helper.metadata(path)))
    elif mode == 'interrupt':
        path = root/'turns'/(value+'.json')
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            with contextlib.closing(select.kqueue()) as queue:
                queue.control([select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                    flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE)], 0, 0)
                deadline = time.monotonic()+30
                while not path.exists():
                    remaining = deadline-time.monotonic()
                    assert remaining > 0 and queue.control(None,1,remaining), 'turn did not start'
            turn = json.loads(path.read_text())
            os.kill(turn['runner'],signal.SIGTERM)
        finally:
            os.close(fd)
    elif mode == 'inspect':
        turns = [json.loads(line) for line in (root/'turns.jsonl').read_text().splitlines()]
        for turn in turns:
            if turn['token'] == 'interrupt-token':
                try: os.kill(turn['provider'],0)
                except ProcessLookupError: pass
                else: raise AssertionError('interrupted provider survived')
        print(json.dumps(turns))
    else:
        raise ValueError(mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--peer', required=True, help='local or existing trusted user@IPv4')
    parser.add_argument('--skip-exchange', action='store_true', help='negative control, must fail')
    args = parser.parse_args()
    local = args.peer == 'local'
    if not local and not re.fullmatch(r'[A-Za-z0-9._-]+@[0-9.]+', args.peer):
        parser.error('requires an existing trusted user@IPv4 route')
    user, address = ('fixture','127.0.0.1') if local else args.peer.split('@')
    repo = Path(__file__).resolve().parents[1]
    helper = load(repo/'scripts/test-physical-reconcile.py')
    run = helper.run
    root = Path(tempfile.mkdtemp(prefix='n2-physical-prompt-',dir='/private/tmp')); root.chmod(0o700)
    ssh = ['/usr/bin/ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10',args.peer]
    receipt = {'root':str(root),'peer':args.peer,'negativeControl':args.skip_exchange,'stages':[]}
    transcript = []
    remote_ready = False
    active = None

    def remote(command):
        return run(['/bin/sh','-c',command] if local else ssh+[command])

    def call(home, *arguments, physical=True):
        command = ['env','-i','HOME='+str(root/home),'USER='+user,'TMPDIR='+str(root/'tmp'),
                   'PATH=/usr/bin:/bin:/usr/sbin:/sbin',str(root/'wrapper'),*arguments]
        out = remote(shlex.join(command)) if home == 'beta' and physical else run(command)
        transcript.append({'home':home,'args':arguments,'stdout':out})
        return out

    def helper_call(mode, value):
        return remote(shlex.join(['/usr/bin/python3',str(root/'acceptance.py'),'--fixture',str(root),mode,value]))

    def peer_meta(home, peer):
        matches = [p for p in (root/home/'.n2-agents/fleet/peers').glob('*/meta') if helper.metadata(p).get('peer') == peer]
        assert len(matches) == 1
        return matches[0]

    try:
        receipt.update(localHost=socket.gethostname(),remoteHost=remote('hostname'),source=run(['git','rev-parse','HEAD'],cwd=repo))
        if not local:
            assert receipt['localHost'] != receipt['remoteHost']
            trusted = run(['/usr/bin/ssh-keygen','-F',address,'-f',str(Path.home()/'.ssh/known_hosts')])
            keys = [line.split()[1:3] for line in trusted.splitlines() if line and not line.startswith('#') and line.split()[1] == 'ssh-ed25519']
            assert len(keys) == 1
        for name in ('alpha','beta','repo','bin','tmp','turns'):
            (root/name).mkdir()
        for name in run(['git','ls-files'],cwd=repo).splitlines():
            if '/' not in name and (name == 'agents' or name.endswith(('.py','.sh'))):
                shutil.copy2(repo/name,root/'repo'/name)
        shutil.copy2(__file__,root/'acceptance.py')
        shutil.copy2(repo/'scripts/test-physical-reconcile.py',root/'physical.py')
        provider = (repo/'tests/fake-bound-codex.py').read_text().replace("if mode == 'rerouted':", "if mode.endswith('rerouted'):")
        provider = provider.replace("    method = request['method']", """    method = request['method']
    credential = Path(os.environ['CODEX_HOME'])/'auth.json'
    token = current_token or (json.loads(credential.read_text())['tokens']['access_token'] if credential.exists() else '')
    if token == 'quota-token': mode = 'quota-rerouted'
    if method == 'turn/start':
        import select,socket
        root=Path(os.environ['N2_PROOF_ROOT']); task=os.environ['N2_FLEET_TASK']
        turn={'task':task,'host':socket.gethostname(),'runner':os.getppid(),'provider':os.getpid(),'token':token}
        with (root/'turns.jsonl').open('a') as out: out.write(json.dumps(turn)+'\\n')
        path=root/'turns'/(task+'.json'); temp=path.with_suffix('.new')
        temp.write_text(json.dumps(turn)); temp.replace(path)
        Path(os.environ['N2_FLEET_OUTPUTS'],'result.txt').write_text('physical deliverable')
        if token == 'interrupt-token':
            assert select.select([sys.stdin],[],[],30)[0], 'interruption timeout'
            raise RuntimeError('not interrupted')""")
        provider = provider.replace("    elif method == 'turn/start':", "        if token == 'other-token': result['model']='other-model'\n    elif method == 'turn/start':")
        (root/'bin/codex').write_text(provider); (root/'bin/codex').chmod(0o700)
        (root/'bin/security').write_text('#!/bin/sh\nexit 1\n'); (root/'bin/security').chmod(0o700)
        if local:
            (root/'bin/ssh').write_text('''#!/usr/bin/python3
import subprocess,sys
result=subprocess.run(['/bin/sh','-c',sys.argv[-1]],input=sys.stdin.buffer.read(),capture_output=True)
sys.stdout.buffer.write(result.stdout);sys.stderr.buffer.write(result.stderr);sys.exit(result.returncode)
''')
            (root/'bin/ssh').chmod(0o700)
        wrapper = root/'wrapper'
        wrapper.write_text(f'''#!/bin/sh
set -eu
case "$HOME" in {root}/alpha|{root}/beta) ;; *) exit 97;; esac
export N2_AGENTS_ROOT="$HOME/.n2-agents" N2_FLEET_AGENTS={wrapper} N2_FLEET_NOTIFY=:
export N2_PROOF_ROOT={root} N2_BOUND_TRACE={root}/trace PATH={root}/bin:/usr/bin:/bin:/usr/sbin:/sbin
exec {root}/repo/agents "$@"
'''); wrapper.chmod(0o700)
        alpha=call('alpha','fleet','init','--machine','physical-dispatcher').split()[1]
        beta=call('beta','fleet','init','--machine','physical-worker',physical=False).split()[1]
        receipt.update(dispatcher=alpha,worker=beta)
        invite=call('alpha','fleet','invite','--peer',beta)
        assert 'approved' in call('beta','fleet','pair','--home',str(root/'alpha'),'--code',invite,physical=False)
        helper.patch(peer_meta('beta',alpha),home=str(root/'absent-return-route'))
        fixture(str(root),'credential','before-token')
        call('beta','use','Before','--vendor','codex',physical=False)
        if not local:
            archive=root/'fixture.tar'
            with tarfile.open(archive,'w') as bundle:
                for name in ('beta','bin','repo','tmp','turns','wrapper','acceptance.py','physical.py'):
                    bundle.add(root/name,arcname=name)
            remote('umask 077 && mkdir '+shlex.quote(str(root)))
            with archive.open('rb') as stream:
                result=subprocess.run(ssh+['tar -xf - -C '+shlex.quote(str(root))],stdin=stream,capture_output=True,timeout=60)
            assert result.returncode == 0, result.stderr.decode()
        remote_ready=True
        command=shlex.join(['env','-i','HOME='+str(root/'beta'),'USER='+user,'TMPDIR='+str(root/'tmp'),'PATH=/usr/bin:/bin:/usr/sbin:/sbin',str(wrapper)])
        helper.patch(peer_meta('alpha',beta),transport='ssh',address=address,port='22',user=user,command=command,
                     bootstrap='1' if local else str(Path.home()/'.ssh/id_ed25519'))
        if not local: call('alpha','fleet','rehost',beta,'--host-key','physical-prompt '+' '.join(keys[0]))
        assert 'pong physical-worker' in call('alpha','fleet','ping',beta)
        total=0
        for phase, token in [('success','before-token'),('quota','quota-token'),('other','other-token'),('recovery','before-token'),('interrupt','interrupt-token')]:
            helper_call('credential',token)
            task=call('alpha','fleet','task','run','--machine','physical-worker','--agent','codex','--allow-unknown-auth','--prompt','physical fixture task').split('\t')[0]
            assert re.fullmatch('[a-f0-9]{8,64}',task),task
            active=task
            if phase == 'interrupt': helper_call('interrupt',task)
            worker_state=json.loads(helper_call('wait',task))
            active=None
            assert worker_state['state'] == ('failed' if phase in ('quota','interrupt') else 'completed'),worker_state
            before=json.loads(call('beta','usage','history'))
            task_events=[e for e in before if e['data'].get('attribution',{}).get('task') == task]
            assert all(e['origin'] == beta for e in task_events)
            assert len(task_events) == (1 if phase == 'interrupt' else 2),task_events
            if phase != 'interrupt': total += 60
            if not args.skip_exchange: call('alpha','fleet','sync','tick','--interval','1')
            history=json.loads(call('alpha','usage','history'))
            assert {e['id']:e for e in history} == {e['id']:e for e in before}, 'execution events did not cross signed exchange'
            summary=json.loads(call('alpha','usage','summary'))
            assert sum(g['reportedTotalTokens'] for g in summary['groups']) == total,summary
            restrictions=json.loads(call('alpha','usage','restrictions'))
            assert bool(restrictions) == (phase in ('quota','other')),restrictions
            if phase == 'interrupt':
                assert sum(g['unconfirmedTasks'] for g in summary['groups']) == 1,summary
                assert all(v is None for k,v in task_events[0]['data']['attribution'].items() if k != 'task')
            else:
                terminal=next(e for e in task_events if e['kind'] != 'execution-started')['data']
                assert terminal['attribution']['cachedInputTokens'] == 30 and terminal['identity']['status'] == 'verified',terminal
            receipt['stages'].append({'phase':phase,'task':task,'workerState':worker_state,'history':history,'summary':summary,'restrictions':restrictions})
        # Replay a completed task through the same signed task-start carrier.
        task=receipt['stages'][0]['task']; payload=root/'replay'
        bundle=io.BytesIO()
        with tarfile.open(fileobj=bundle,mode='w') as archive:
            info=tarfile.TarInfo('spec/mode');data=b'prompt';info.size=len(data);archive.addfile(info,io.BytesIO(data))
        payload.write_bytes(f'task={task}\nvendor=codex\n--\n'.encode()+base64.b64encode(bundle.getvalue())+b'\n')
        request=root/'request.sh'
        request.write_text(f'root=$HOME/.n2-agents\nself={root}/repo/agents\n. {root}/repo/fleet.sh\nfleet_call "$@"\n')
        env={'HOME':str(root/'alpha'),'N2_FLEET_AGENTS':str(wrapper),'PATH':str(root/'bin')+':/usr/bin:/bin:/usr/sbin:/sbin'}
        assert 'accepted '+task in run(['/bin/sh',str(request),beta,'task-start',str(payload)],env=env)
        call('alpha','fleet','sync','tick','--interval','1')
        assert json.loads(call('alpha','usage','summary')) == summary, 'replay changed accounting'
        turns=json.loads(helper_call('inspect','unused'))
        assert len(turns) == 5 and {t['host'] for t in turns} == {receipt['remoteHost']},turns
        assert len({t['task'] for t in turns}) == 5,turns
        receipt.update(turns=turns,passed=True)
        print(json.dumps({'passed':True,'receipt':str(root/'receipt.json')}))
    finally:
        cleanup_error=None
        if remote_ready and active:
            try: helper_call('wait',active)
            except Exception as error:
                cleanup_error=error
                receipt['cleanupError']=str(error)
        (root/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
        (root/'cli.json').write_text(json.dumps(transcript,indent=2)+'\n')
        print(f'Disposable roots retained: {root}',file=sys.stderr)
        if cleanup_error is not None and sys.exc_info()[0] is None: raise cleanup_error


if __name__ == '__main__':
    if len(sys.argv)>1 and sys.argv[1] == '--fixture': fixture(*sys.argv[2:])
    else: main()
