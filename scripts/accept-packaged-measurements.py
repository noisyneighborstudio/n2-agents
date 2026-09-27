#!/usr/bin/env python3
"""Opt-in disposable macOS package acceptance; requires existing AX permission."""
import contextlib
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('native', REPO / 'scripts/accept-native-physical-reconcile.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
run = native.physical.run
base = Path(tempfile.mkdtemp(prefix='n2-package-measurements-', dir='/private/tmp'))
source = REPO / 'tray/build/N2 Agents.app'
app = base / 'N2 Measurement Acceptance.app'
run(['ditto', str(source), str(app)])
resources = app / 'Contents/Resources'
config = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert config.get('N2QABuild') and not (resources / 'fleet-qa').exists()
config.update(CFBundleIdentifier='dev.sethwebster.n2agents.measurement.' + uuid.uuid4().hex,
              CFBundleName='N2 Measurement Acceptance')
config.pop('CFBundleURLTypes', None)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(config))
receipt = {'root': str(base), 'syntheticProvider': True, 'installed': False, 'hashes': {}}
for name in ('agents', 'usage.py', 'usage-store.py', 'codex-rpc.py'):
    assert (resources / name).read_bytes() == (REPO / name).read_bytes()
    receipt['hashes'][name] = hashlib.sha256((resources / name).read_bytes()).hexdigest()
for name in ('home', 'state', 'bin', 'tmp', 'responses'):
    (base / name).mkdir()
for profile in ('Default', 'Other'):
    directory = base / 'state' / profile / 'codex'
    directory.mkdir(parents=True)
    (directory / 'auth.json').write_text('{"tokens":{}}')
policy = '(version 1)(allow default)(deny network*)'
env = {'HOME': str(base / 'home'), 'CFFIXED_USER_HOME': str(base / 'home'),
       'N2_AGENTS_ROOT': str(base / 'state'), 'PATH': str(base / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin',
       'TMPDIR': str(base / 'tmp'), 'ZDOTDIR': str(base / 'home'), 'N2_MEASURE_FIXTURE': str(base),
       'N2_MEASUREMENT_NEGATIVE': os.environ.get('N2_MEASUREMENT_NEGATIVE', '')}
# Prevent the GUI login-shell PATH read from loading real shell configuration.
(base / 'bin/shell').write_text('#!/bin/sh\nexec /usr/bin/env\n')
(base / 'bin/security').write_text('#!/bin/sh\nexit 1\n')
for name in ('shell', 'security'):
    (base / 'bin' / name).chmod(0o700)
env['SHELL'] = str(base / 'bin/shell')
(base / 'bin/codex').write_text('''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
base=Path(os.environ['N2_MEASURE_FIXTURE'])
assert Path(os.environ['CODEX_HOME']).is_relative_to(base/'state')
account=Path(os.environ['CODEX_HOME']).parent.name
mode=(base/'provider-mode').read_text()
for line in sys.stdin:
 request=json.loads(line)
 with (base/'protocol.jsonl').open('a') as f:f.write(json.dumps({'method':request['method'],'profile':account})+'\\n')
 if 'id' not in request:continue
 result={}
 if request['method']=='config/read':result={'config':{}}
 if request['method']=='account/read':result={'account':{'type':'chatgpt','email':'fixture@example.invalid'},'workspaceRouting':{'chatgptAccountId':account,'backendOrigin':'https://chatgpt.com'}}
 if request['method']=='account/rateLimits/read':
  if mode=='failed':
   print(json.dumps({'id':request['id'],'error':{'code':-1,'message':'synthetic failure'}}),flush=True);continue
  result={'rateLimitsByLimitId':{} if mode=='missing' else {'fixture':{'primary':{'usedPercent':12 if account=='Default' else 34,'windowDurationMins':300}}}}
 print(json.dumps({'id':request['id'],'result':result}),flush=True)
''')
(base / 'bin/codex').chmod(0o700)
# Prove the denied-network boundary itself fails a connection attempt.
network = subprocess.run(['/usr/bin/sandbox-exec', '-p', policy, '/usr/bin/python3', '-c',
                          'import socket; socket.socket().connect(("127.0.0.1",9))'], env=env, capture_output=True, text=True)
assert network.returncode != 0 and 'Operation not permitted' in network.stderr
receipt['networkDenied'] = True
for mode in ('healthy', 'missing', 'failed'):
    (base / 'provider-mode').write_text(mode)
    result = run(['/usr/bin/sandbox-exec', '-p', policy, str(resources / 'agents'),
                  'best', '--json', '--vendor', 'codex'], env=env)
    (base / 'responses' / mode).write_text(result + '\n')
    rows = [json.loads(line) for line in result.splitlines()]
    assert len(rows) == 2
    assert all(row['status'] == ('ok' if mode == 'healthy' else 'fetch-error') for row in rows), rows
healthy = [json.loads(line) for line in (base / 'responses/healthy').read_text().splitlines()]
assert len({r['identity']['accountHash'] for r in healthy}) == 2
assert all(r['identity']['status'] == 'verified' for r in healthy)
# Simulate retained observations aging at the transport boundary. No provider
# result or production parser is rewritten; the original CLI output is retained.
stale = [dict(row, observedAt='2020-01-01T00:00:00Z') for row in healthy]
(base / 'responses/stale').write_text('\n'.join(json.dumps(row) for row in stale)+'\n')
receipt['accounts'] = {r['profile']: r['identity']['accountHash'] for r in healthy}
receipt['observedAt'] = {r['profile']: r['observedAt'] for r in healthy}
# An allowlist adapter feeds actual bundled CLI output into the unchanged UI.
# The real CLI and provider protocol proof above remain available in the fixture.
(resources / 'agents').rename(resources / 'agents-real')
cli = base / 'cli.py'
cli.write_text('''import json,os,sys
from pathlib import Path
base=Path(''' + repr(str(base)) + ''')
assert os.environ['HOME']==str(base/'home') and os.environ['N2_AGENTS_ROOT']==str(base/'state')
(base/'app-pid').write_text(str(os.getppid()))
args=sys.argv[1:]
if args==['porcelain']:
 print('V\\tcodex\\t1\\tinstance\\toauth\\tCodex\\t1\\tCX\\tCodex\\tcom.openai.codex\\t7d')
 for profile in ('Default','Other'):
  print('P\\t'+profile+'\\t0\\tcodex:ok')
  print('S\\t'+profile+'\\tcodex\\t'+str(base/'state'/profile/'codex')+'\\tfixture\\tyes\\t')
elif args==['best','--json','--vendor','codex']:
 mode=(base/'ui-mode').read_text()
 if mode=='failed' and os.environ.get('N2_MEASUREMENT_NEGATIVE')=='1':mode='healthy'
 sys.stdout.write((base/'responses'/mode).read_text())
 (base/('read-'+(base/'ui-mode').read_text())).touch()
elif args and args[0] in ('sessions','fleet'):pass
else:raise AssertionError(args)
''')
(resources / 'agents').write_text('#!/bin/sh\nexec /usr/bin/python3 ' + str(cli) + ' "$@"\n')
run(['codesign', '--force', '--deep', '--sign', '-', str(app)])
run(['codesign', '--verify', '--deep', '--strict', str(app)])
ui = base / 'ui'
run(['swiftc', '-warnings-as-errors', str(REPO / 'scripts/native-measurement-ui.swift'), '-o', str(ui)])
executable = app / 'Contents/MacOS' / config['CFBundleExecutable']
receipt['binarySha256'] = hashlib.sha256(executable.read_bytes()).hexdigest()
(base / 'ui-mode').write_text('healthy')
launcher = subprocess.Popen(['/usr/bin/sandbox-exec', '-p', policy, str(executable)], env=env,
                            stdout=(base / 'app.log').open('w'), stderr=subprocess.STDOUT)
try:
    native.wait_file(base / 'read-healthy')
    pid = int((base / 'app-pid').read_text())
    assert run(['ps', '-p', str(pid), '-o', 'comm=']) == str(executable)
    def action(mode, text=''):
        return run([str(ui), str(pid), mode, text], env=env)
    def capture(name):
        text = action('dump')
        (base / (name + '.txt')).write_text(text)
        window = action('window')
        assert window.isdigit()
        expected = {'healthy': ['open next best', '12.0% used'],
                    'other-account': ['open next best', '34.0% used'],
                    'failed': ['usage unavailable', 'check failed'],
                    'missing': ['usage unavailable', 'check failed'],
                    'stale': ['usage unavailable', 'stale measurement']}.get(name, ['n2 agents'])
        deadline = time.monotonic() + 20
        while True:
            run(['screencapture', '-x', '-l', window, str(base / (name + '.png'))])
            # AX may publish before the window's pixels. Each capture is a
            # rendered receipt; wait for its text, never a timing sleep.
            pixels = action('ocr', str(base / (name + '.png')))
            if all(value in pixels.lower() for value in expected):
                (base / (name + '.ocr.txt')).write_text(pixels)
                break
            assert time.monotonic() < deadline, 'window pixels did not reach ' + name
        return text
    run(['osascript', '-e', f'tell application "System Events" to tell (first application process whose unix id is {pid}) to click menu bar item 1 of menu bar 1'])
    action('wait', 'Open next best')
    action('click', 'Default')
    action('wait', '12% used')
    action('click', 'Codex')
    account_label = 'Usage account · ' + receipt['accounts']['Default'][:12]
    action('wait', account_label)
    baseline = capture('healthy')
    assert account_label in baseline
    observed = next(line for line in baseline.splitlines() if line.startswith('Observed '))
    expected_time = datetime.datetime.fromisoformat(receipt['observedAt']['Default'].replace('Z', '+00:00')).timestamp()
    assert observed == 'Observed ' + action('date', str(expected_time))
    action('click', 'Other')
    action('click', 'Codex')
    other_label = 'Usage account · ' + receipt['accounts']['Other'][:12]
    action('wait', other_label)
    other = capture('other-account')
    assert other_label in other and account_label not in other
    action('click', 'Default')
    action('click', 'Codex')
    action('wait', account_label)
    receipt['nativeAccountSeparation'] = True
    assert 'Usage unavailable' not in baseline
    # The unavailable assertion must reject a genuinely healthy rendered state.
    def unavailable(text):
        assert 'Usage unavailable' in text and 'Open next best' not in text
    try: unavailable(baseline)
    except AssertionError: receipt['negativeControlRejected'] = True
    else: raise AssertionError('healthy UI passed unavailable proof')
    for mode, label in [('failed', 'check failed'), ('missing', 'check failed'), ('stale', 'stale reading')]:
        if mode != 'failed':
            (base / 'ui-mode').write_text('healthy')
            run(['/usr/bin/open', '-a', str(app), 'n2agents://refresh'])
            action('wait', 'Open next best')
            action('wait', '12.0% used')
        (base / 'ui-mode').write_text(mode)
        run(['/usr/bin/open', '-a', str(app), 'n2agents://refresh'])
        native.wait_file(base / ('read-' + mode))
        action('wait', label)
        rendered = capture(mode)
        unavailable(rendered)
        if mode == 'stale':
            assert 'Observed ' + action('date', '1577836800') in rendered
            assert '12% used' not in rendered and '12.0% used' not in rendered
        else:
            assert observed in rendered, 'failed refresh replaced historical observation time'
    receipt['nativeObservationTimesPreserved'] = True
    receipt['passed'] = True
except Exception:
    if 'pid' in globals():
        with contextlib.suppress(Exception): capture('failure')
    raise
finally:
    # Match only our unique copied executable, even if startup failed early.
    for line in run(['ps', '-axo', 'pid=,comm=']).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == str(executable):
            with contextlib.suppress(ProcessLookupError): os.kill(int(parts[0]), signal.SIGTERM)
    try:
        launcher.wait(timeout=15)
    except subprocess.TimeoutExpired:
        launcher.kill()
        launcher.wait(timeout=5)
        raise
    finally:
        (base / 'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
        print('Acceptance artifacts:', base)
        shutil.rmtree(app)
