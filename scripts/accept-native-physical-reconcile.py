#!/usr/bin/env python3
"""Opt-in macOS UI acceptance: --peer user@IPv4 [--artifacts directory]."""
import contextlib
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import select
import signal
import shutil
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('physical', REPO / 'scripts/test-physical-reconcile.py')
physical = importlib.util.module_from_spec(spec)
spec.loader.exec_module(physical)


def wait_file(path):
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        with contextlib.closing(select.kqueue()) as queue:
            queue.control([select.kevent(descriptor, filter=select.KQ_FILTER_VNODE,
                          flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                          fflags=select.KQ_NOTE_WRITE)], 0, 0)
            deadline = time.monotonic() + 40
            while not path.exists():
                remaining = deadline - time.monotonic()
                assert remaining > 0 and queue.control(None, 1, remaining), str(path)
    finally:
        os.close(descriptor)


def release(path):
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as error:
        if error.errno != errno.ENXIO:
            raise
    else:
        try:
            os.write(descriptor, b'release\n')
        finally:
            os.close(descriptor)


def verify_finished(tree):
    assert 'static text finished of' in tree and 'static text unreachable of' not in tree


def verify_feed(tree, *titles):
    # The durable half of a fleet event: the in-app activity feed, which must
    # not depend on a desktop banner having landed.
    assert 'static text FLEET ACTIVITY of' in tree, 'activity feed not shown'
    for title in titles:
        assert f'static text {title} of' in tree, f'activity feed lacks {title!r}'


def native_check_in(evidence, local_meta):
    assert evidence['transport'] == 'physical SSH', 'native acceptance requires a physical peer'
    fixture = Path(evidence['root'])
    base = fixture / 'native'
    base.mkdir()
    home = base / 'home'
    home.mkdir()
    evidence['nativeArtifacts'] = str(base)
    app = base / 'N2 Physical Acceptance.app'
    source = REPO / 'tray/build/N2 Agents.app'
    assert source.is_dir(), 'build N2_QA=1 with tray/build.sh first'
    physical.run(['ditto', str(source), str(app)])
    plist = app / 'Contents/Info.plist'
    config = plistlib.loads(plist.read_bytes())
    config.update(CFBundleIdentifier='dev.sethwebster.n2agents.physical.' + uuid.uuid4().hex,
                  CFBundleName='N2 Physical Acceptance', N2QABuild=True)
    for key in ('N2FleetQA', 'CFBundleURLTypes'):
        config.pop(key, None)
    plist.write_bytes(plistlib.dumps(config))
    resources = app / 'Contents/Resources'
    (resources / 'fleet-qa').unlink(missing_ok=True)
    assert (resources / 'fleet-exec.sh').read_bytes() == (REPO / 'fleet-exec.sh').read_bytes()
    os.mkfifo(base / 'release', 0o600)
    cli = base / 'cli.py'
    cli.write_text('''import json,os,sys,subprocess,select
from pathlib import Path
base=Path(''' + repr(str(base)) + ''')
fixture=base.parent
assert os.environ['HOME']==str(base/'home')
assert os.environ['CFFIXED_USER_HOME']==str(base/'home')
assert os.environ['N2_AGENTS_ROOT']==str(base/'state')
args=sys.argv[1:]
(base/'app-pid').write_text(str(os.getppid()))
with (base/'commands.jsonl').open('a') as f:f.write(json.dumps(args)+'\\n')
if args and args[0] in ('porcelain','sessions'):sys.exit(0)
allowed=[['fleet','status','--no-probe'],['fleet','peers'],['fleet','sync','status'],['fleet','sync','conflicts'],['fleet','sync','except','list'],['fleet','tools','list'],['fleet','tools','status'],['fleet','tools','deferred'],['fleet','task','list'],['fleet','task','notices'],['fleet','task','reconcile']]
assert args in allowed,args
if args==['fleet','task','reconcile']:
 fd=os.open(base/'release',os.O_RDWR|os.O_NONBLOCK)
 (base/'started').touch()
 assert select.select([fd],[],[],60)[0],'UI release timed out'
 assert os.read(fd,128).strip()==b'release'
 os.close(fd)
env=dict(os.environ,HOME=str(fixture/'alpha'))
r=subprocess.run([str(fixture/'wrapper')]+args,env=env,text=True,capture_output=True)
sys.stdout.write(r.stdout);sys.stderr.write(r.stderr)
if args==['fleet','task','notices']:(base/'read').touch()
sys.exit(r.returncode)
''')
    (resources / 'agents').write_text('#!/bin/sh\nexec /usr/bin/python3 ' + str(cli) + ' "$@"\n')
    physical.run(['codesign', '--force', '--deep', '--sign', '-', str(app)])
    physical.run(['codesign', '--verify', '--deep', '--strict', str(app)])
    window = base / 'window.swift'
    window.write_text('''import Foundation
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for item in windows where item[kCGWindowOwnerPID as String] as? Int == pid {
 if let bounds = item[kCGWindowBounds as String] as? [String: Any], (bounds["Height"] as? Double ?? 0) > 100 {
  print(item[kCGWindowNumber as String]!)
 }
}
''')
    command = ['/usr/bin/open', '-n', '-W', str(app)]
    for key, value in {'HOME': str(home), 'CFFIXED_USER_HOME': str(home),
                       'N2_AGENTS_ROOT': str(base / 'state'), 'ZDOTDIR': str(home),
                       'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}.items():
        command += ['--env', key + '=' + value]
    launcher = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pid = None
    try:
        if os.environ.get('N2_NATIVE_FAIL_BEFORE_READ') == '1':
            wait_file(base / 'app-pid')
            raise RuntimeError('injected failure before initial read')
        wait_file(base / 'read')
        pid = int((base / 'app-pid').read_text())
        executable = str(app / 'Contents/MacOS' / config['CFBundleExecutable'])
        assert physical.run(['ps', '-p', str(pid), '-o', 'comm=']) == executable

        def ax(action):
            return physical.run(['osascript', '-e', 'tell application "System Events" to tell '
                                 f'(first application process whose unix id is {pid}) to ' + action])

        def capture(name):
            tree = ax('get entire contents of window 1')
            (base / (name + '.txt')).write_text(tree)
            identifier = physical.run(['swift', str(window), str(pid)])
            assert identifier.isdigit(), identifier
            physical.run(['screencapture', '-x', '-l', identifier, str(base / (name + '.png'))])
            return tree

        ax('click menu bar item 1 of menu bar 1')
        physical.run(['swift', str(REPO / 'scripts/native-physical-wait.swift'), str(pid), 'unreachable'])
        before = capture('unreachable')
        assert 'static text unreachable of' in before and 'static text physical-reconcile of' in before
        verify_feed(before, 'physical-worker disconnected')
        # Negative control: the real unreachable capture must fail the finished check.
        try:
            verify_finished(before)
        except AssertionError:
            pass
        else:
            raise AssertionError('finished check accepted unreachable state')
        try:
            verify_feed(before, 'Task finished on physical-worker')
        except AssertionError:
            pass
        else:
            raise AssertionError('feed check accepted a completion that had not happened')
        # SwiftUI currently exposes these buttons without names. The fixture has
        # one task and no profiles; require that exact observed layout before use.
        assert ax('count buttons of scroll area 1 of group 1 of window 1') == '10'
        ax('click button 10 of scroll area 1 of group 1 of window 1')
        wait_file(base / 'started')
        assert physical.metadata(local_meta)['state'] == 'unreachable'
        ax('click button 1 of group 1 of window 1')
        assert 'static text Settings of' in capture('settings-while-held')
        assert physical.metadata(local_meta)['state'] == 'unreachable'
        release(base / 'release')
        physical.wait_state(local_meta, 'completed')
        ax('click button 1 of group 1 of window 1')
        ax('click menu bar item 1 of menu bar 1')
        physical.run(['swift', str(REPO / 'scripts/native-physical-wait.swift'), str(pid), 'finished'])
        recovered = capture('recovered')
        verify_finished(recovered)
        verify_feed(recovered, 'physical-worker disconnected', 'Task finished on physical-worker')
        # A copy with a unique bundle id has no notification permission, so the
        # banner attempt must surface its failure instead of passing silently.
        banner = ('permission-unavailable-shown' if 'Desktop notifications are unavailable' in recovered
                  else 'submitted')
        evidence['native'] = {'unreachableShown': True, 'settingsResponsiveWhileHeld': True,
                              'finishedShown': True, 'negativeControlRejected': True,
                              'feedShowsDisconnectAndCompletion': True, 'banner': banner,
                              'binarySha256': hashlib.sha256(Path(executable).read_bytes()).hexdigest()}
    finally:
        release(base / 'release')
        # Startup can fail before the CLI publishes app-pid. Match only this
        # unique copied executable, never a process name shared with live apps.
        executable = str(app / 'Contents/MacOS' / config['CFBundleExecutable'])
        processes = physical.run(['ps', '-axo', 'pid=,comm='])
        for line in processes.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[1] == executable:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(int(parts[0]), signal.SIGTERM)
        try:
            launcher.wait(timeout=15)
        except subprocess.TimeoutExpired:
            launcher.terminate()
            launcher.wait(timeout=5)
            raise
        finally:
            shutil.rmtree(app)


if __name__ == '__main__':
    physical.main(native_check_in=native_check_in)
