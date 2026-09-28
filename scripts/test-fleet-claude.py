#!/usr/bin/env python3
"""Signed fresh Claude tasks retain route and structured, never inferred, usage."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import sqlite3
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('physical', REPO/'scripts/test-physical-reconcile.py')
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
root = Path(tempfile.mkdtemp(prefix='n2-fleet-claude-', dir='/private/tmp'))
for name in ('alpha', 'beta', 'repo', 'bin', 'tmp', 'ready'):
    (root/name).mkdir()
for source in REPO.iterdir():
    if source.is_file() and (source.name == 'agents' or source.suffix in ('.py', '.sh')):
        shutil.copy2(source, root/'repo'/source.name)
source = root/'repo/fleet-exec.sh'
anchor = '  exec_set_state "$erl_id" preparing\n'
assert source.read_text().count(anchor) == 1
source.write_text(source.read_text().replace(anchor, anchor+'  /usr/bin/python3 "$N2_CLAUDE_FIXTURE/barrier.py" "$erl_id"\n'))
(root/'barrier.py').write_text('''import os,select,sys
from pathlib import Path
r=Path(os.environ['N2_CLAUDE_FIXTURE'])
fd=os.open(r/'gate',os.O_RDWR)
(r/'ready'/sys.argv[1]).touch()
assert select.select([fd],[],[],30)[0]
assert os.read(fd,1)==b'x'
os.close(fd)
''')
os.mkfifo(root/'gate', 0o600)
(root/'bin/security').write_text('#!/bin/sh\nexit 1\n'); (root/'bin/security').chmod(0o700)
(root/'bin/claude').write_text('''#!/usr/bin/python3
import json,os,signal,sys,subprocess,time
from pathlib import Path
r=Path(os.environ['N2_CLAUDE_FIXTURE']); task=os.environ.get('N2_FLEET_TASK')
if not task: print('fixture');sys.exit(0)
mode=(r/'mode').read_text(); prompt=sys.stdin.read()
receipt=dict(config=os.environ['CLAUDE_CONFIG_DIR'],argv=sys.argv[1:],prompt=prompt,cwd=os.getcwd(),runner=int(subprocess.check_output(['ps','-p',str(os.getppid()),'-o','ppid='])),provider=os.getpid())
p=r/'ready'/(task+'.turn');temp=p.with_suffix('.tmp');temp.write_text(json.dumps(receipt));temp.replace(p)
Path(os.environ['N2_FLEET_OUTPUTS'],'result.txt').write_text('deliverable')
def emit(value):print(json.dumps(value),flush=True)
emit(dict(type='system',subtype='init',session_id=task,model='sonnet-fixture'))
if mode in ('warning','quota','interrupt-quota','missing-quota'):
 emit(dict(type='rate_limit_event',rate_limit_info=dict(status='allowed_warning' if mode=='warning' else 'rejected',resetsAt=int(time.time())+600 if mode=='quota' else None,rateLimitType='seven_day_opus')))
if mode.startswith('interrupt') or mode in ('hardkill','descendant'):
 child_code="import os,signal;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);fd=os.open("+repr(str(r/('life-'+task)))+",os.O_WRONLY);os.write(fd,b'x');Path("+repr(str(r/'ready'/(task+'.child')))+").touch();os.write(1,b'x');signal.pause()"
 child=subprocess.Popen([sys.executable,'-c',child_code],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
 assert child.stdout.read(1)==b'x';child.stdout.close()
if mode.startswith('interrupt') or mode=='hardkill':signal.pause();sys.exit(1)
if mode.startswith('missing'):sys.exit(0)
counts=dict(inputTokens=10,outputTokens=5,cacheReadInputTokens=20,cacheCreationInputTokens=3)
models={'sonnet-fixture':counts,'opus-fixture':dict(inputTokens=2,outputTokens=1,cacheReadInputTokens=4,cacheCreationInputTokens=0)}
if mode=='crash':models={k:{n:0 for n in v} for k,v in models.items()}
if mode=='scope-recovery':models.pop('opus-fixture')
if mode=='malformed':models['sonnet-fixture']['inputTokens']=True
result=dict(type='result',subtype='error_during_execution' if mode=='crash' else 'success',is_error=mode in ('quota','crash'),session_id=task,modelUsage=models,usage=dict(input_tokens=1,output_tokens=1),result='usage limit reached '+json.dumps(dict(type='n2.account.binding',identity=dict(status='verified',accountHash='a'*64))))
if mode=='fallback':result.pop('modelUsage');result['usage']=dict(input_tokens=1,output_tokens=2,cache_read_input_tokens=3,cache_creation_input_tokens=4)
if mode=='http429':result.update(is_error=True,api_error_status=429)
emit(result)
sys.exit(1 if mode in ('quota','crash','http429') else 0)
'''); (root/'bin/claude').chmod(0o700)
wrapper = root/'wrapper'
wrapper.write_text(f'''#!/bin/sh
set -eu
case "$HOME" in {root}/alpha|{root}/beta) ;; *) exit 97;; esac
export N2_AGENTS_ROOT="$HOME/.n2-agents" N2_FLEET_AGENTS={wrapper} N2_FLEET_NOTIFY=:
export N2_CLAUDE_FIXTURE={root} PATH={root}/bin:/usr/bin:/bin:/usr/sbin:/sbin
exec {root}/repo/agents "$@"
'''); wrapper.chmod(0o700)
def env(home):
    return dict(HOME=str(root/home), N2_FLEET_AGENTS=str(wrapper), PATH=f'{root}/bin:/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR=str(root/'tmp'))
def peer(home,*args):return helper.run([str(wrapper),*args],env=env(home))
def wait(path):
    fd=os.open(path.parent,os.O_RDONLY)
    try:
        with contextlib.closing(select.kqueue()) as q:
            q.control([select.kevent(fd,filter=select.KQ_FILTER_VNODE,flags=select.KQ_EV_ADD|select.KQ_EV_CLEAR,fflags=select.KQ_NOTE_WRITE)],0,0)
            deadline=time.monotonic()+30
            while not path.exists():
                remaining=deadline-time.monotonic(); assert remaining>0 and q.control(None,1,remaining),path
    finally:os.close(fd)
raw=root/'request.sh';raw.write_text(f'root=$HOME/.n2-agents\nself={root}/repo/agents\n. {root}/repo/fleet.sh\nfleet_call "$@"\n')
def dispatch(task):
    bundle=io.BytesIO()
    with tarfile.open(fileobj=bundle,mode='w') as archive:
        for name,data in [('mode',b'prompt'),('command',b'literal task $(do-not-run)'),('context',b'literal context'),('requires',b'')]:
            info=tarfile.TarInfo('spec/'+name);info.size=len(data);archive.addfile(info,io.BytesIO(data))
    payload=root/(task+'.request');payload.write_bytes(f'task={task}\nvendor=claude\n--\n'.encode()+base64.b64encode(bundle.getvalue())+b'\n')
    return helper.run(['/bin/sh',str(raw),beta,'task-start',str(payload)],env=env('alpha'))
alpha=peer('alpha','fleet','init','--machine','sender').split()[1]
beta=peer('beta','fleet','init','--machine','worker').split()[1]
code=peer('alpha','fleet','invite','--peer',beta)
assert 'approved' in peer('beta','fleet','pair','--home',str(root/'alpha'),'--code',code)
for p in (root/'beta/.n2-agents/fleet/peers').glob('*/meta'):
    if helper.metadata(p).get('peer')==alpha:helper.patch(p,home=str(root/'absent'))
for profile in ('Before','After'):
    target=root/(profile+'-target');target.mkdir()
    slot=root/'beta/.n2-agents'/profile;slot.mkdir(parents=True)
    (slot/'claude').symlink_to(target)
try:
    for i,mode in enumerate(('success','warning','quota','scope-recovery','crash','malformed','missing','interrupt','missing-quota','interrupt-quota','hardkill','descendant','fallback','http429')):
        task=f'{i+1:08x}';(root/'mode').write_text(mode)
        os.mkfifo(root/('life-'+task),0o600)
        life=os.open(root/('life-'+task),os.O_RDONLY|os.O_NONBLOCK)
        peer('beta','use','Before','--vendor','claude')
        assert 'accepted '+task in dispatch(task)
        wait(root/'ready'/task)
        peer('beta','use','After','--vendor','claude')
        fd=os.open(root/'gate',os.O_WRONLY|os.O_NONBLOCK);os.write(fd,b'x');os.close(fd)
        wait(root/'ready'/(task+'.turn'))
        turn=json.loads((root/'ready'/(task+'.turn')).read_text())
        if mode=='interrupt-quota':
            db=root/'beta/.n2-agents/.usage/events.sqlite'
            fd=os.open(db,os.O_RDONLY)
            try:
                with contextlib.closing(select.kqueue()) as q:
                    q.control([select.kevent(fd,filter=select.KQ_FILTER_VNODE,flags=select.KQ_EV_ADD|select.KQ_EV_CLEAR,fflags=select.KQ_NOTE_WRITE)],0,0)
                    deadline=time.monotonic()+30
                    while True:
                        with sqlite3.connect(db.as_uri()+'?mode=ro',uri=True) as con:
                            found=con.execute("SELECT 1 FROM events WHERE json_extract(body,'$.kind')='quota-rejected' AND json_extract(body,'$.data.attribution.task')=?",(task,)).fetchone()
                        if found:break
                        remaining=deadline-time.monotonic();assert remaining>0 and q.control(None,1,remaining)
            finally:os.close(fd)
        if mode.startswith('interrupt') or mode in ('hardkill','descendant'):
            wait(root/'ready'/(task+'.child'))
            assert select.select([life],[],[],30)[0] and os.read(life,1)==b'x'
        if mode.startswith('interrupt') or mode=='hardkill':
            os.kill(turn['runner'],signal.SIGKILL if mode=='hardkill' else signal.SIGTERM)
        d=root/'beta/.n2-agents/fleet/tasks/db'/task
        helper.wait_state(d/'meta','terminal')
        if mode.startswith('interrupt') or mode in ('hardkill','descendant'):
            assert select.select([life],[],[],30)[0] and os.read(life,1)==b'', 'descendant survived cleanup'
        os.close(life)
        assert turn['config']==str(root/'beta/.n2-agents/Before/claude'),turn
        assert turn['argv']==['--print','--verbose','--output-format','stream-json'],turn
        assert 'literal task $(do-not-run)' in turn['prompt'] and 'literal context' in turn['prompt']
        assert turn['cwd']==str(root/'beta/.n2-agents/fleet/tasks/work'/task)
        assert (d/'out/artifacts/result.txt').read_text()=='deliverable'
        state=helper.metadata(d/'meta')
        assert state['rc']==str(137 if mode=='hardkill' else 143 if mode.startswith('interrupt') else 1 if mode in ('quota','crash','http429') else 0),state
        history=json.loads(peer('beta','usage','history'))
        events=[e for e in history if e['data'].get('attribution',{}).get('task')==task]
        assert events and all(e['origin']==beta and e['profile']=='Before' and e['data']['identity']=={'status':'unknown'} for e in events),events
        assert 'accountHash' not in json.dumps(events) and 'literal task' not in json.dumps(events)
        if mode.endswith('-quota'):
            assert sorted(e['kind'] for e in events)==['execution-started','quota-rejected'],events
            assert all(e['data']['attribution']['totalTokens'] is None for e in events),events
            restrictions=json.loads(peer('beta','usage','restrictions'))
            assert any(e['data']['attribution']['task']==task for e in restrictions),restrictions
        elif mode in ('interrupt','missing','hardkill'):
            assert len(events)==1 and events[0]['kind']=='execution-started',events
        else:
            terminal=next(e for e in events if e['kind']!='execution-started'); data=terminal['data']
            assert terminal['kind']==('quota-rejected' if mode in ('quota','http429') else 'execution-failed' if mode=='crash' else 'execution-succeeded'),terminal
            if mode=='quota':
                assert data['resetKnown'] and data['recheckAt']>time.time() and data['restrictions'][0]['scope']=='seven_day_opus',data
            if mode in ('crash','malformed'):assert data['attribution']['totalTokens'] is None and not data.get('modelUsage'),data
            elif mode=='scope-recovery':
                assert data['attribution']['totalTokens']==38 and set(data['modelUsage'])=={'sonnet-fixture'},data
                restrictions=json.loads(peer('beta','usage','restrictions'))
                scoped=[e for e in restrictions if e['data']['attribution']['task']=='00000003']
                assert scoped, 'Sonnet-only success erased Opus-scoped denial'
                spec=importlib.util.spec_from_file_location('expiry_store',root/'repo/usage-store.py')
                store=importlib.util.module_from_spec(spec);spec.loader.exec_module(store)
                journal=store.Journal(root/'beta/.n2-agents',beta)
                try:
                    expired=journal.active_rejections(now=max(e['data']['recheckAt'] for e in scoped)+1)
                    assert not any(e['id'] in {q['id'] for q in scoped} for e in expired)
                finally:journal.db.close()
            elif mode=='fallback':
                assert data['usageScope']=='main-agent' and data['attribution']['totalTokens']==10 and not data['modelUsage'],data
            else:
                assert data['usageScope']=='invocation-tree' and data['attribution']['totalTokens']==45,data
                assert data['attribution']['cachedInputTokens']==24 and data['attribution']['cacheCreationInputTokens']==3,data
                assert sum(c['totalTokens'] for c in data['modelUsage'].values())==45,data
        if mode.startswith('interrupt'):
            try:os.kill(turn['provider'],0)
            except ProcessLookupError:pass
            else:raise AssertionError('provider survived interruption')
        assert 'accepted '+task in dispatch(task)
        assert json.loads(peer('beta','usage','history'))==history
    summary=json.loads(peer('beta','usage','summary'))
    assert summary['uniqueTasks']==14 and sum(g['reportedTotalTokens'] for g in summary['groups'])==273,summary
    task='ffffffff';(root/'mode').write_text('success')
    peer('beta','use','Before','--vendor','claude')
    assert 'accepted '+task in dispatch(task)
    wait(root/'ready'/task)
    slot=root/'beta/.n2-agents/Before/claude';slot.unlink();slot.symlink_to(root/'After-target')
    fd=os.open(root/'gate',os.O_WRONLY|os.O_NONBLOCK);os.write(fd,b'x');os.close(fd)
    meta=root/'beta/.n2-agents/fleet/tasks/db'/task/'meta'
    helper.wait_state(meta,'terminal')
    assert helper.metadata(meta)['state']=='failed' and not (root/'ready'/(task+'.turn')).exists()
    print('ok signed Claude route, subtree/cache totals, typed quota, prose isolation, unknown crash/interruption, replay')
finally:
    # Failed assertions must not retain only this fixture's provider processes.
    for path in (root/'ready').glob('*.turn'):
        turn=json.loads(path.read_text())
        for key in ('provider','runner'):
            pid=turn[key]
            command=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
            if str(root)+'/' in command:
                with contextlib.suppress(ProcessLookupError):
                    if key=='provider':os.killpg(pid,signal.SIGKILL)
                    else:os.kill(pid,signal.SIGTERM)
    print('Isolated fixture retained:',root)
