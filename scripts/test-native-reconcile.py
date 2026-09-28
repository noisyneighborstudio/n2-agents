#!/usr/bin/env python3
"""Compile and exercise the exact native reconciliation action and CLI bridge."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def method(path, start, end):
    source = (ROOT / path).read_text()
    first = source.index(start)
    return source[first:source.index(end, first)].rstrip()


with tempfile.TemporaryDirectory(prefix='n2-native-reconcile-') as temporary:
    base = Path(temporary)
    methods = method('tray/FleetControl.swift', '    func fleetReconcileTasks()',
                     '    func fleetOpenTerminal')
    methods += '\n' + method('tray/main.swift', '    @discardableResult\n    func runCLI',
                             '    func setActive')
    fixture = (ROOT / 'tests/FleetReconcileTests.swift').read_text()
    source = base / 'proof.swift'
    source.write_text(fixture.replace('    // PRODUCTION_METHODS', methods))
    executable = base / 'proof'
    subprocess.run(['swiftc', '-warnings-as-errors', '-parse-as-library', str(source),
                    '-o', str(executable)], check=True)
    for status in ('0', '1'):
        case = base / status
        case.mkdir()
        for name in ('started', 'release'):
            os.mkfifo(case / name, 0o600)
        cli = case / 'agents'
        cli.write_text('''#!/bin/sh
[ "$*" = 'fleet task reconcile' ] || exit 2
printf 'started\\n' > "$N2_TEST_DIR/started"
read -r receipt < "$N2_TEST_DIR/release"
[ "$N2_TEST_RC" = 0 ] || printf 'fixture refusal\\n'
exit "$N2_TEST_RC"
''')
        env = dict(os.environ, HOME=str(case), N2_ROOT=str(case / 'profiles'),
                   N2_TEST_DIR=str(case), N2_TEST_CLI=str(cli), N2_TEST_RC=status)
        child = subprocess.Popen([str(executable)], env=env, start_new_session=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            output, _ = child.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate()
            raise AssertionError('main thread could not release held reconciliation') from None
        assert child.returncode == 0, output.decode()
        expected = 'main-thread-receipt,' + ('error,' if status == '1' else '') + 'refresh'
        assert output.decode().strip() == expected, output.decode()
        print('Reconcile: ' + ('success' if status == '0' else 'refusal') + ' stays responsive and refreshes')
