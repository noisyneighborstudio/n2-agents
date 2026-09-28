#!/usr/bin/env python3
"""Opt-in signed usage exchange over an existing trusted SSH route, synthetic accounts only."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time


def run(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=60, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{args[0]} exited {result.returncode}: {result.stderr}\n{result.stdout}')
    return result.stdout.strip()


def meta(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)


def patch(path, **values):
    data = meta(path)
    data.update(values)
    path.write_text(''.join(f'{key}={value}\n' for key, value in data.items()))


def fixture(root, home, origin, mode):
    # This helper is copied with the runtime. Every invocation reopens the journal.
    root = Path(root)
    spec = importlib.util.spec_from_file_location('usage_store', root / 'repo/usage-store.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    journal = module.Journal(root / home / '.n2-agents', origin)
    identity = {'status': 'verified', 'accountHash': 'a' * 64}
    healthy = {'status': 'ok', 'identity': identity, 'restrictions': []}
    try:
        if mode == 'evaluate':
            other = dict(healthy, identity={'status': 'verified', 'accountHash': 'b' * 64})
            result = {'matching': journal.effective('codex', 'LocalName', healthy),
                      'different': journal.effective('codex', 'RemoteName', other),
                      'restrictions': journal.active_rejections(), 'history': journal.events()}
        elif mode == 'observe':
            result = journal.append('codex', 'LocalName', 'measurement', healthy)
        else:
            clock = root / 'timeline'
            if mode == 'reject':
                clock.write_text(str(time.time() - 60))
            base = float(clock.read_text())
            offsets = {'reject': 0, 'old-success': 10, 'wrong-model': 20, 'recover': 30}
            data = dict(healthy, requestedModel='test-model',
                        attribution={'task': mode, 'totalTokens': None})
            kind = 'quota-rejected' if mode == 'reject' else 'execution-succeeded'
            data['status'] = 'restricted' if mode == 'reject' else 'ok'
            if mode != 'reject':
                data['startedAt'] = base - 1 if mode == 'old-success' else base + 1
            if mode == 'wrong-model':
                data['requestedModel'] = 'other-model'
            result = journal.append('codex', 'RemoteName', kind, data, base + offsets[mode])
        print(json.dumps(result))
    finally:
        journal.db.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--peer', required=True)
    parser.add_argument('--skip-exchange', action='store_true', help='negative control; must fail')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9._-]+@[0-9.]+', args.peer):
        parser.error('requires an existing trusted user@IPv4 route')
    user, address = args.peer.split('@')
    repo = Path(__file__).resolve().parent.parent
    root = Path(tempfile.mkdtemp(prefix='n2-physical-usage-', dir='/private/tmp'))
    root.chmod(0o700)
    ssh = ['/usr/bin/ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
           '-o', 'ConnectTimeout=10', args.peer]
    receipt = {'root': str(root), 'peer': args.peer, 'syntheticAccounts': True,
               'negativeControl': args.skip_exchange, 'stages': []}
    transcript = []

    def remote(command):
        return run(ssh + [command])

    def call(home, *arguments):
        output = run([str(root / 'wrapper'), *arguments], env={
            'HOME': str(root / home), 'USER': user, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
            'TMPDIR': str(root / 'tmp')})
        transcript.append({'home': home, 'args': arguments, 'stdout': output})
        return output

    def peer_meta(home, identity):
        paths = [p for p in (root / home / '.n2-agents/fleet/peers').glob('*/meta')
                 if meta(p).get('peer') == identity]
        assert len(paths) == 1
        return paths[0]

    def helper(home, origin, mode):
        command = ['/usr/bin/python3', str(root / 'acceptance.py'), '--fixture',
                   str(root), home, origin, mode]
        return json.loads(remote(shlex.join(command)) if home == 'beta' else run(command))

    try:
        receipt.update(localHost=socket.gethostname(), remoteHost=remote('hostname'))
        assert receipt['localHost'] != receipt['remoteHost']
        trusted = run(['/usr/bin/ssh-keygen', '-F', address, '-f', str(Path.home() / '.ssh/known_hosts')])
        keys = [line.split()[1:3] for line in trusted.splitlines()
                if line and not line.startswith('#') and line.split()[1] == 'ssh-ed25519']
        assert len(keys) == 1, 'requires one previously trusted ED25519 key'
        for name in ('alpha', 'beta', 'bin', 'repo', 'tmp'):
            (root / name).mkdir()
        for name in run(['git', 'ls-files'], cwd=repo).splitlines():
            if '/' not in name and (name == 'agents' or name.endswith(('.sh', '.py'))):
                shutil.copy2(repo / name, root / 'repo' / name)
        shutil.copy2(__file__, root / 'acceptance.py')
        security = root / 'bin/security'
        security.write_text('#!/bin/sh\nexit 1\n')
        security.chmod(0o700)
        wrapper = root / 'wrapper'
        wrapper.write_text(f'''#!/bin/sh
set -eu
case "$HOME" in {root}/alpha|{root}/beta) ;; *) exit 97;; esac
export N2_AGENTS_ROOT="$HOME/.n2-agents" N2_FLEET_AGENTS={wrapper}
export PATH={root}/bin:/usr/bin:/bin:/usr/sbin:/sbin N2_FLEET_NOTIFY=:
exec {root}/repo/agents "$@"
''')
        wrapper.chmod(0o700)
        alpha = call('alpha', 'fleet', 'init', '--machine', 'usage-receiver').split()[1]
        beta = call('beta', 'fleet', 'init', '--machine', 'usage-origin').split()[1]
        receipt.update(receiverOrigin=alpha, rejectionOrigin=beta)
        invite = call('alpha', 'fleet', 'invite', '--peer', beta)
        assert 'approved' in call('beta', 'fleet', 'pair', '--home', str(root / 'alpha'), '--code', invite)
        patch(peer_meta('beta', alpha), home=str(root / 'absent-receiver'))
        archive = root / 'fixture.tar'
        with tarfile.open(archive, 'w') as bundle:
            for name in ('beta', 'bin', 'repo', 'tmp', 'wrapper', 'acceptance.py'):
                bundle.add(root / name, arcname=name)
        remote(f'umask 077; mkdir {root}')
        with archive.open('rb') as source:
            transfer = subprocess.run(ssh + [f'tar -xf - -C {root}'], stdin=source,
                                      capture_output=True, timeout=60)
        assert transfer.returncode == 0, transfer.stderr.decode()
        command = f'env -i HOME={root}/beta USER={user} TMPDIR={root}/tmp PATH=/usr/bin:/bin:/usr/sbin:/sbin {wrapper}'
        patch(peer_meta('alpha', beta), transport='ssh', address=address, port='22', user=user,
              command=command, bootstrap=str(Path.home() / '.ssh/id_ed25519'))
        call('alpha', 'fleet', 'rehost', beta, '--host-key', 'usage-test ' + ' '.join(keys[0]))
        assert 'pong usage-origin' in call('alpha', 'fleet', 'ping', beta)
        helper('alpha', alpha, 'observe')
        rejection = helper('beta', beta, 'reject')
        receipt['rejection'] = rejection
        assert helper('alpha', alpha, 'evaluate')['matching']['status'] == 'ok'

        def stage(name, expected):
            if not args.skip_exchange:
                call('alpha', 'fleet', 'sync', 'tick', '--interval', '1')
            result = helper('alpha', alpha, 'evaluate')
            receipt['stages'].append({'name': name, **result})
            assert result['matching']['status'] == expected, f'{name}: matching account expected {expected}'
            assert result['different']['status'] == 'ok', 'different account must remain eligible'
            matches = [event for event in result['history'] if event['id'] == rejection['id']]
            assert matches == [rejection], 'original event and timestamp must survive exchange/replay'
            assert result['restrictions'] == ([rejection] if expected == 'restricted' else [])

        stage('received', 'restricted')
        stage('reopened-and-replayed', 'restricted')
        for mode in ('old-success', 'wrong-model', 'recover'):
            receipt[mode] = helper('beta', beta, mode)
            stage(mode, 'ok' if mode == 'recover' else 'restricted')
        stage('recovery-replayed', 'ok')
        receipt['passed'] = True
        print(json.dumps({'passed': True, 'receipt': str(root / 'receipt.json')}))
    finally:
        (root / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        (root / 'cli.json').write_text(json.dumps(transcript, indent=2) + '\n')
        print(f'Disposable roots retained on both machines: {root}', file=sys.stderr)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--fixture':
        fixture(*sys.argv[2:])
    else:
        main()
