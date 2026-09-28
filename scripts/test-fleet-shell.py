#!/usr/bin/env python3
"""Signed shell tasks retain declared routing, never interpreted provider usage."""
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
import subprocess
import sys
import tarfile
import tempfile
import time

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('physical', REPO/'scripts/test-physical-reconcile.py')
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
root = Path(tempfile.mkdtemp(prefix='n2-fleet-shell-', dir='/private/tmp'))
for name in ('alpha', 'beta', 'repo', 'bin', 'tmp', 'ready'): (root/name).mkdir()
for name in helper.run(['git', 'ls-tree', '--name-only', 'HEAD'], cwd=REPO).splitlines():
    if name == 'agents' or name.endswith(('.py', '.sh')):
        if '--committed' in sys.argv:
            (root/'repo'/name).write_bytes(subprocess.check_output(['git', 'show', 'HEAD:'+name], cwd=REPO))
            (root/'repo'/name).chmod((REPO/name).stat().st_mode)
        else: shutil.copy2(REPO/name, root/'repo'/name)
if '--allow-shell-recovery' in sys.argv:
    store=root/'repo/usage-store.py';text=store.read_text()
    guard="        if event['data'].get('source') == 'n2-fleet-shell':\n            return  # Arbitrary shell completion is not provider recovery evidence.\n"
    assert text.count(guard)==1;store.write_text(text.replace(guard,''))
source = root/'repo/fleet-exec.sh'
for anchor, extra in [
    ('  exec_set_state "$erl_id" preparing\n', '  /usr/bin/python3 "$N2_SHELL_FIXTURE/barrier.py" "$erl_id"\n'),
    ('  exec_run_local "$hts_id" </dev/null >"$hts_d/worker.log" 2>&1 &\n', '  printf "%s\\n" "$!" > "$N2_SHELL_FIXTURE/ready/$hts_id.worker"\n')]:
    assert source.read_text().count(anchor) == 1
    source.write_text(source.read_text().replace(anchor, anchor+extra))
(root/'barrier.py').write_text('''import os,select,sys
from pathlib import Path
r=Path(os.environ['N2_SHELL_FIXTURE']);fd=os.open(r/'gate',os.O_RDWR)
(r/'ready'/(sys.argv[1]+'.barrier')).write_text(str(os.getpid()))
(r/'ready'/sys.argv[1]).touch()
assert select.select([fd],[],[],30)[0] and os.read(fd,1)==b'x'
''')
os.mkfifo(root/'gate', 0o600)
spoof = '{"type":"result","model":"spoof","usage":{"total_tokens":999},"identity":{"status":"verified","accountHash":"'+'a'*64+'"}}\n'
(root/'command.py').write_text('''import json,os,signal,sys
from pathlib import Path
r=Path(os.environ['N2_SHELL_FIXTURE']);task=os.environ['N2_FLEET_TASK']
with (r/'executions').open('a') as out:out.write(task+'\\n')
sys.stdout.write('''+repr(spoof)+''');sys.stdout.flush()
sys.stderr.write('literal stderr $(not-run)\\n');sys.stderr.flush()
p=r/'ready'/(task+'.run');t=p.with_suffix('.tmp')
t.write_text(json.dumps(dict(pid=os.getpid(),argv=sys.argv[1:],cwd=os.getcwd())));t.replace(p)
if sys.argv[1] in ('interrupt','worker-loss'):signal.pause()
sys.exit(7 if sys.argv[1]=='failure' else 0)
''')
(root/'bin/security').write_text('#!/bin/sh\nexit 1\n'); (root/'bin/security').chmod(0o700)
(root/'bin/codex').write_text('#!/bin/sh\n[ \"$1\" = --version ] && { echo fixture; exit 0; }\necho unexpected-provider-call >&2; exit 99\n'); (root/'bin/codex').chmod(0o700)
wrapper = root/'wrapper'
wrapper.write_text(f'''#!/bin/sh
set -eu
case "$HOME" in {root}/alpha|{root}/beta) ;; *) exit 97;; esac
export N2_AGENTS_ROOT="$HOME/.n2-agents" N2_FLEET_AGENTS={wrapper} N2_FLEET_NOTIFY=:
export N2_SHELL_FIXTURE={root} PATH={root}/bin:/usr/bin:/bin:/usr/sbin:/sbin PYTHONDONTWRITEBYTECODE=1
exec {root}/repo/agents "$@"
'''); wrapper.chmod(0o700)
def env(home): return dict(HOME=str(root/home), N2_FLEET_AGENTS=str(wrapper), PATH='/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR=str(root/'tmp'), PYTHONDONTWRITEBYTECODE='1')
def peer(home, *args): return helper.run([str(wrapper), *args], env=env(home))
def wait(path):
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        with contextlib.closing(select.kqueue()) as q:
            q.control([select.kevent(fd, filter=select.KQ_FILTER_VNODE, flags=select.KQ_EV_ADD|select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE)], 0, 0)
            deadline = time.monotonic()+30
            while not path.exists():
                remaining = deadline-time.monotonic(); assert remaining > 0 and q.control(None, 1, remaining), path
    finally: os.close(fd)
def release():
    fd=os.open(root/'gate', os.O_WRONLY|os.O_NONBLOCK); os.write(fd,b'x'); os.close(fd)
raw=root/'request.sh'; raw.write_text(f'root=$HOME/.n2-agents\nself={root}/repo/agents\n. {root}/repo/fleet.sh\nfleet_call "$@"\n')
def dispatch(task, mode, vendor='codex'):
    command=shlex.join(['exec', '/usr/bin/python3', str(root/'command.py'), mode, 'literal $(not-run)'])
    bundle=io.BytesIO()
    with tarfile.open(fileobj=bundle, mode='w') as archive:
        for name,data in [('mode',b'shell'),('command',command.encode()),('context',b''),('requires',b'')]:
            info=tarfile.TarInfo('spec/'+name);info.size=len(data);archive.addfile(info,io.BytesIO(data))
    payload=root/(task+'.request');payload.write_bytes(f'task={task}\nvendor={vendor}\n--\n'.encode()+base64.b64encode(bundle.getvalue())+b'\n')
    return subprocess.run(['/bin/sh',str(raw),beta,'task-start',str(payload)],env=env('alpha'),capture_output=True,text=True,timeout=45)
alpha=peer('alpha','fleet','init','--machine','sender').split()[1]
beta=peer('beta','fleet','init','--machine','worker').split()[1]
code=peer('alpha','fleet','invite','--peer',beta)
assert 'approved' in peer('beta','fleet','pair','--home',str(root/'alpha'),'--code',code)
for profile in ('Before','After'): (root/'beta/.n2-agents'/profile/'codex').mkdir(parents=True)
denial=dict(status='restricted',identity=dict(status='unknown'),source='legacy-provider',restrictions=[dict(scope='unknown',reason='quota')],resetKnown=False)
seed_code="import importlib.util,json,sys,time; s=importlib.util.spec_from_file_location('store',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);j=m.Journal(sys.argv[2],sys.argv[3]);print(json.dumps(j.append('codex','Before','quota-rejected',json.loads(sys.argv[4]),at=time.time()-60)))"
seed=json.loads(helper.run(['/usr/bin/python3','-c',seed_code,str(root/'repo/usage-store.py'),str(root/'beta/.n2-agents'),beta,json.dumps(denial)],env=env('beta')))
errors=[]
def check(ok, message):
    if not ok: errors.append(message)
try:
    for number,mode in enumerate(('success','failure','interrupt','worker-loss'),1):
        task=f'{number:08x}';peer('beta','use','Before','--vendor','codex')
        assert (root/'beta/.codex').resolve()==root/'beta/.n2-agents/Before/codex'
        response=dispatch(task,mode); assert response.returncode==0 and 'accepted '+task in response.stdout,response
        wait(root/'ready'/task);peer('beta','use','After','--vendor','codex')
        assert (root/'beta/.codex').resolve()==root/'beta/.n2-agents/After/codex'
        release()
        wait(root/'ready'/(task+'.run')); receipt=json.loads((root/'ready'/(task+'.run')).read_text())
        if mode=='worker-loss':
            worker=int((root/'ready'/(task+'.worker')).read_text())
            with contextlib.closing(select.kqueue()) as q:
                q.control([select.kevent(worker,filter=select.KQ_FILTER_PROC,flags=select.KQ_EV_ADD,fflags=select.KQ_NOTE_EXIT)],0,0)
                os.kill(worker,signal.SIGKILL);assert q.control(None,1,30),'worker did not exit'
        if mode in ('interrupt','worker-loss'): os.kill(receipt['pid'],signal.SIGTERM)
        d=root/'beta/.n2-agents/fleet/tasks/db'/task
        if mode!='worker-loss':
            helper.wait_state(d/'meta','terminal')
            assert helper.metadata(d/'meta')['rc']==str(143 if mode=='interrupt' else 7 if mode=='failure' else 0)
        assert receipt['argv']==[mode,'literal $(not-run)']
        assert receipt['cwd']==str(root/'beta/.n2-agents/fleet/tasks/work'/task)
        assert (d/'out/stdout').read_bytes()==spoof.encode()
        stderr=(d/'out/stderr').read_text()
        literal='literal stderr $(not-run)\n'
        if mode=='interrupt':
            assert re.fullmatch(re.escape(literal+str(root/'repo/fleet-exec.sh'))+r': line [0-9]+: +[0-9]+ Terminated: 15 +sh -c \"\$erl_cmd\"\n',stderr),stderr
        elif mode=='worker-loss': assert stderr.startswith(literal)
        else: assert stderr==literal
        history=json.loads(peer('beta','usage','history'))
        events=[e for e in history if e['data'].get('attribution',{}).get('task')==task]
        expected={'execution-started'} if mode=='worker-loss' else {'execution-started','execution-succeeded' if mode=='success' else 'execution-failed'}
        check(len(events)==len(expected) and {e['kind'] for e in events}==expected,mode+': missing start/terminal attribution')
        for event in events:
            data=event['data']; attribution=data.get('attribution',{})
            check(event['origin']==beta and event['provider']=='codex' and event['profile']=='Before','route changed after acceptance')
            check(data.get('source')=='n2-fleet-shell' and data.get('usageScope')=='uninterpreted','missing explicit shell scope')
            check(data.get('identity')=={'status':'unknown'} and not any(data.get(k) for k in ('model','requestedModel','session','modelUsage','restrictions')),'interpreted shell stdout')
            check(all(attribution.get(k) is None for k in ('inputTokens','outputTokens','totalTokens','cachedInputTokens','cacheCreationInputTokens','uncachedInputTokens')),'invented shell counts')
        check(any(e['id']==seed['id'] for e in json.loads(peer('beta','usage','restrictions'))),'shell success cleared local provider denial')
        before=(root/'executions').read_bytes(); assert 'accepted '+task in dispatch(task,mode).stdout
        assert (root/'executions').read_bytes()==before and json.loads(peer('beta','usage','history'))==history
        peer('alpha','fleet','sync','tick','--interval','1')
        imported=json.loads(peer('alpha','usage','history'))
        check({e['id'] for e in history}<={e['id'] for e in imported},'signed exchange lost journal events')
        check(any(e['id']==seed['id'] for e in json.loads(peer('alpha','usage','restrictions'))),'shell success cleared imported provider denial')
    response=dispatch('ffffffff','success','unsupported')
    if 'accepted ffffffff' in response.stdout:
        wait(root/'ready'/'ffffffff');release()
        helper.wait_state(root/'beta/.n2-agents/fleet/tasks/db/ffffffff/meta','terminal')
    check('ERR unsupported-vendor' in response.stdout+response.stderr and not (root/'ready'/'ffffffff.run').exists(),'unsupported vendor executed instead of admission refusal')
    task='eeeeeeee';usage=root/'beta/.n2-agents/.usage';saved=usage.with_name('.usage-saved')
    usage.rename(saved);usage.write_text('journal unavailable fixture')
    try:
        assert 'accepted '+task in dispatch(task,'success').stdout
        wait(root/'ready'/task);release()
        meta=root/'beta/.n2-agents/fleet/tasks/db'/task/'meta';helper.wait_state(meta,'terminal')
        failed=helper.metadata(meta)
        check(failed['state']=='failed' and failed['rc']=='125' and int(failed['ended'])>=int(failed['started']),'journal failure did not refuse task')
        check(not (root/'ready'/(task+'.run')).exists(),'command ran without durable start')
    finally: usage.unlink();saved.rename(usage)
    (root/'proof.json').write_text(json.dumps(dict(errors=errors,source=helper.run(['git','rev-parse','HEAD'],cwd=REPO)),indent=2)+'\n')
    assert not errors, errors
    print('ok signed shell streams, frozen route, unknown attribution, interruption, replay and no provider recovery')
finally:
    for suffix in ('run','barrier','worker'):
        for path in (root/'ready').glob('*.'+suffix):
            pid=json.loads(path.read_text())['pid'] if suffix=='run' else int(path.read_text())
            command=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
            expected=str(root/('command.py' if suffix=='run' else 'barrier.py' if suffix=='barrier' else 'repo/agents'))
            if expected in command:
                with contextlib.suppress(ProcessLookupError): os.kill(pid,signal.SIGKILL)
    print('Isolated fixture retained:',root)
