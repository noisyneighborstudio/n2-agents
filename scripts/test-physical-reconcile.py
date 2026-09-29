#!/usr/bin/env python3
"""Opt-in physical SSH acceptance; retained roots contain synthetic state only."""
import argparse
import contextlib
import errno
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time


def run(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=kwargs.pop('timeout', 90), **kwargs)
    if result.returncode:
        raise RuntimeError(f'{args[0]} exited {result.returncode}: {result.stderr}\n{result.stdout}')
    return result.stdout.strip()


def metadata(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)


def patch(path, **values):
    data = metadata(path)
    data.update(values)
    temporary = path.with_suffix('.new')
    temporary.write_text(''.join(f'{key}={value}\n' for key, value in data.items()))
    temporary.replace(path)


def wait_state(path, expected):
    # Watch the parent: production replaces the metadata file atomically.
    descriptor = os.open(path.parent, os.O_RDONLY)
    deadline = time.monotonic() + 60
    try:
        with contextlib.closing(select.kqueue()) as queue:
            event = select.kevent(descriptor, filter=select.KQ_FILTER_VNODE,
                                 flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                 fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_RENAME)
            queue.control([event], 0, 0)
            while True:
                state = metadata(path).get('state') if path.exists() else None
                if state == expected or (expected == 'terminal' and state in ('failed', 'completed')):
                    return
                if state in ('failed', 'completed'):
                    raise AssertionError(f'expected {expected}, got {state}')
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not queue.control(None, 1, remaining):
                    raise TimeoutError(f'waiting for {expected}: {path}')
    finally:
        os.close(descriptor)


def helper():
    mode, root = sys.argv[1:3]
    root = Path(root)
    if mode == '--worker':
        # One append per actual command execution; FIFO release is event driven.
        with (root / 'executions').open('a') as receipt:
            receipt.write(socket.gethostname() + '\n')
        (root / 'worker-pid').write_text(str(os.getpid()))
        descriptor = os.open(root / 'release', os.O_RDWR | os.O_NONBLOCK)
        try:
            # A timeout fails a stuck fixture even if the controller disappears.
            assert not (root / 'abort').exists(), 'controller aborted'
            assert select.select([descriptor], [], [], 120)[0], 'release timed out'
            assert os.read(descriptor, 128).strip() == b'complete'
        finally:
            os.close(descriptor)
            (root / 'worker-released').touch()
        (root / 'result').write_text('finished while disconnected\n')
        print('finished while disconnected')
    elif mode == '--abort':
        (root / 'abort').touch()
        try:
            descriptor = os.open(root / 'release', os.O_WRONLY | os.O_NONBLOCK)
        except OSError as error:
            if error.errno != errno.ENXIO:
                raise
        else:
            try:
                os.write(descriptor, b'abort\n')
            finally:
                os.close(descriptor)
        for path in (root / 'beta/.n2-agents/fleet/tasks/db').glob('*/meta'):
            wait_state(path, 'terminal')
    elif mode == '--wait-state':
        wait_state(root, sys.argv[3])
    else:
        raise ValueError(mode)


def main(native_check_in=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--peer', required=True, help='local for offline regression, or existing trusted user@IPv4 SSH destination')
    parser.add_argument('--artifacts', type=Path)
    parser.add_argument('--keep-request-streams', action='store_true',
                        help='negative control: restore the original fixture worker launch')
    parser.add_argument('--skip-reconcile', action='store_true', help='negative control; must fail')
    args = parser.parse_args()
    local = args.peer == 'local'
    if not local and not re.fullmatch(r'[A-Za-z0-9._-]+@[0-9.]+', args.peer):
        parser.error('use an existing trusted user@IPv4 destination')
    user, address = ('fixture', '') if local else args.peer.split('@')
    repo = Path(__file__).resolve().parent.parent
    root = Path(tempfile.mkdtemp(prefix='n2-physical-', dir='/private/tmp'))
    os.chmod(root, 0o700)
    args.artifacts = args.artifacts or root / 'evidence'
    args.artifacts.mkdir(parents=True, exist_ok=True)
    evidence = {'root': str(root), 'peer': args.peer, 'negativeControl': args.skip_reconcile or args.keep_request_streams,
                'transport': 'offline pipe fixture' if local else 'physical SSH'}
    transcript = []
    remote_ready = False
    ssh = ['/usr/bin/ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
           '-o', 'ConnectTimeout=10', args.peer]

    def remote(command):
        return run(['/bin/sh', '-c', command] if local else ssh + [command])

    def call(home, *arguments):
        env = {'HOME': str(root / home), 'USER': user, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
               'TMPDIR': str(root / 'tmp')}
        output = run([str(root / 'wrapper'), *arguments], env=env, timeout=30)
        transcript.append({'home': home, 'args': arguments, 'stdout': output})
        return output

    def peer_meta(home, identity):
        paths = list((root / home / '.n2-agents/fleet/peers').glob('*/meta'))
        paths = [path for path in paths if metadata(path).get('peer') == identity]
        assert len(paths) == 1, paths
        return paths[0]

    try:
        evidence['localHost'] = socket.gethostname()
        evidence['remoteHost'] = remote('hostname')
        if not local:
            assert evidence['remoteHost'] != evidence['localHost'], 'physical hosts must differ'
            trusted = run(['/usr/bin/ssh-keygen', '-F', address, '-f',
                           str(Path.home() / '.ssh/known_hosts')])
            keys = [line.split()[1:3] for line in trusted.splitlines()
                    if line and not line.startswith('#') and line.split()[1] == 'ssh-ed25519']
            assert len(keys) == 1, 'requires one previously trusted ED25519 host key'
        for name in ('alpha', 'beta', 'bin', 'repo', 'tmp'):
            (root / name).mkdir()
        tracked = run(['git', 'ls-files'], cwd=repo).splitlines()
        for name in tracked:
            if '/' not in name and (name == 'agents' or name.endswith(('.sh', '.py'))):
                shutil.copy2(repo / name, root / 'repo' / name)
        if args.keep_request_streams:
            source = root / 'repo/fleet-exec.sh'
            launch = 'exec_run_local "$1" </dev/null >"$esw_d/worker.log" 2>&1 &'
            assert source.read_text().count(launch) == 1
            source.write_text(source.read_text().replace(launch, 'exec_run_local "$1" &'))
        shutil.copy2(__file__, root / 'acceptance.py')
        for name, code in [('cursor-agent', 0), ('security', 1)]:
            file = root / 'bin' / name
            file.write_text(f'#!/bin/sh\nexit {code}\n')
            file.chmod(0o700)
        if local:
            # Model SSH's pipe lifetime, without network or SSH authentication.
            carrier = root / 'bin/ssh'
            carrier.write_text('''#!/usr/bin/python3
import subprocess, sys
if sys.argv[sys.argv.index('-p') + 1] != '22':
    sys.exit(255)
reply = subprocess.run(['/bin/sh', '-c', sys.argv[-1]],
                       input=sys.stdin.buffer.read(), capture_output=True)
sys.stdout.buffer.write(reply.stdout)
sys.stderr.buffer.write(reply.stderr)
sys.exit(reply.returncode)
''')
            carrier.chmod(0o700)
        wrapper = root / 'wrapper'
        wrapper.write_text(f'''#!/bin/sh
set -eu
case "$HOME" in {root}/alpha|{root}/beta) ;; *) exit 97;; esac
export N2_AGENTS_ROOT="$HOME/.n2-agents" N2_FLEET_AGENTS={root}/wrapper
export PATH={root}/bin:/usr/bin:/bin:/usr/sbin:/sbin N2_FLEET_NOTIFY=:
exec {root}/repo/agents "$@"
''')
        wrapper.chmod(0o700)
        alpha = call('alpha', 'fleet', 'init', '--machine', 'physical-dispatcher').split()[1]
        beta = call('beta', 'fleet', 'init', '--machine', 'physical-worker').split()[1]
        code = call('alpha', 'fleet', 'invite', '--peer', beta)
        assert 'approved' in call('beta', 'fleet', 'pair', '--home', str(root / 'alpha'), '--code', code)
        # Return announcements cannot reach the dispatcher, even after it restores SSH.
        patch(peer_meta('beta', alpha), home=str(root / 'absent-dispatcher'))
        os.mkfifo(root / 'release', 0o600)
        if not local:
            archive = root / 'fixture.tar'
            with tarfile.open(archive, 'w') as bundle:
                for name in ('beta', 'bin', 'repo', 'tmp', 'wrapper', 'acceptance.py', 'release'):
                    bundle.add(root / name, arcname=name)
            remote(f'umask 077; mkdir {shlex.quote(str(root))}')
            with archive.open('rb') as source:
                transfer = subprocess.run(ssh + [f'tar -xf - -C {root}'], stdin=source,
                                          capture_output=True, timeout=90)
            assert transfer.returncode == 0, transfer.stderr.decode()
        remote_ready = True
        command = f'env -i HOME={root}/beta USER={user} TMPDIR={root}/tmp PATH=/usr/bin:/bin:/usr/sbin:/sbin {wrapper}'
        route = peer_meta('alpha', beta)
        patch(route, transport='ssh', address=address or '127.0.0.1', port='22', user=user,
              command=command, bootstrap='1' if local else str(Path.home() / '.ssh/id_ed25519'))
        if not local:
            call('alpha', 'fleet', 'rehost', beta, '--host-key', 'physical-test ' + ' '.join(keys[0]))
        assert 'pong physical-worker' in call('alpha', 'fleet', 'ping', beta)
        task = call('alpha', 'fleet', 'task', 'run', '--machine', 'physical-worker',
                    '--agent', 'cursor', '--allow-unknown-auth', '--label', 'physical-reconcile',
                    f'/usr/bin/python3 {root}/acceptance.py --worker {root}').split('\t')[0]
        assert re.fullmatch('[a-f0-9]{8,64}', task), task
        evidence['task'] = task
        remote_meta = root / 'beta/.n2-agents/fleet/tasks/db' / task / 'meta'
        remote(f'/usr/bin/python3 {root}/acceptance.py --wait-state {remote_meta} running')
        # A refused fixture port cuts this route only; existing SSH remains untouched.
        if not local:
            remote("/usr/bin/python3 -c 'import socket; s=socket.socket(); s.settimeout(2); assert s.connect_ex((\"127.0.0.1\", 1)) != 0; s.close()'")
        patch(route, port='1')
        tick = call('alpha', 'fleet', 'sync', 'tick', '--interval', '1')
        assert 'unreachable' in tick, tick
        local_meta = root / 'alpha/.n2-agents/fleet/tasks/db' / task / 'meta'
        assert metadata(local_meta)['state'] == 'unreachable'
        remote(f"printf 'complete\\n' > {root}/release")
        remote(f'/usr/bin/python3 {root}/acceptance.py --wait-state {remote_meta} completed')
        assert metadata(local_meta)['state'] == 'unreachable', 'completion must require reconciliation'
        patch(route, port='22')
        if native_check_in is not None:
            native_check_in(evidence, local_meta)
        elif not args.skip_reconcile:
            call('alpha', 'fleet', 'task', 'reconcile', task)
        evidence['dispatcherState'] = metadata(local_meta)['state']
        assert evidence['dispatcherState'] == 'completed', 'dispatcher-completed assertion failed'
        executions = remote(f'cat {root}/executions').splitlines()
        assert executions == [evidence['remoteHost']], executions
        assert len(list(local_meta.parent.parent.iterdir())) == 1
        remote_state = remote(f'{command} fleet task show {task}')
        assert 'state\tcompleted' in remote_state, remote_state
        assert remote(f'cat {root}/result') == 'finished while disconnected'
        evidence.update(remoteState='completed', executions=len(executions), taskCount=1, passed=True)
        print(json.dumps(evidence, indent=2))
    finally:
        # Release only our FIFO task on failure, then observe its terminal receipt.
        cleanup_error = None
        if remote_ready:
            try:
                remote(f'/usr/bin/python3 {root}/acceptance.py --abort {root}')
                evidence['cleanup'] = 'owned task terminal'
            except Exception as error:
                cleanup_error = error
                evidence['cleanupError'] = str(error)
        # Preserve disposable roots for inspection; no delayed writer cleanup race.
        (args.artifacts / 'receipt.json').write_text(json.dumps(evidence, indent=2) + '\n')
        (args.artifacts / 'cli.json').write_text(json.dumps(transcript, indent=2) + '\n')
        print(f'Isolated fixture retained: {root}', file=sys.stderr)
        if cleanup_error is not None and sys.exc_info()[0] is None:
            raise cleanup_error


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] in ('--worker', '--wait-state', '--abort'):
        helper()
    else:
        main()
