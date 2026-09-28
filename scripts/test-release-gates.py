#!/usr/bin/env python3
"""Execute the publication gate chain with disposable checks and publisher."""
from pathlib import Path
import os
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
verify = (repo / 'scripts/verify.sh').read_text()
workflow = (repo / '.github/workflows/release.yml').read_text()
ci = (repo / '.github/workflows/ci.yml').read_text()
# CI runs every gate on every push, as parallel jobs: the checks, each test
# group, and each fleet shard with live SSH required.
assert ci.startswith('name: Verify slices\n')
for gate in ('run: scripts/check.sh format', 'run: scripts/check.sh lint', 'run: scripts/smoke.sh',
             'run: zsh scripts/test.sh ${{ matrix.group }}', 'group: [swift, cli, loop, auth, dispatch]',
             'suite: [transport, sync-1, sync-36, sync-48, exec]', 'N2_FLEET_REQUIRE_LIVE_SSH: "1"',
             'N2_FLEET_SUITES=transport sh scripts/test-fleet.sh', 'N2_SYNC_STOP_AFTER=35 sh scripts/test-sync.sh',
             'N2_SYNC_FRESH_FROM=36 N2_SYNC_STOP_AFTER=47 sh scripts/test-sync.sh',
             'N2_SYNC_FRESH_FROM=48 sh scripts/test-sync.sh', 'sh scripts/test-exec.sh && sh scripts/test-native-ui.sh'):
    assert gate in ci, gate
# Only pushes run on the self-hosted Macs. A pull request runs only from a fork,
# and then on GitHub-hosted macOS.
guard = ("    if: github.event_name == 'push' || github.event.pull_request.head.repo.fork\n"
         "    runs-on: ${{ github.event_name == 'push' && fromJSON('[\"self-hosted\",\"macOS\",\"n2\"]') || 'macos-26' }}\n")
assert ci.count(guard) == 3 and ci.count('runs-on:') == 3 and ci.count('if:') == 3
# Publication starts only from a successful CI run of a push, and publishes the
# exact commit that run verified, before any signing or release step.
assert 'workflow_run:\n    workflows: [Verify slices]\n    types: [completed]' in workflow
assert "if: github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.event == 'push'" in workflow
checkout = workflow.index('ref: ${{ github.event.workflow_run.head_sha }}')
assert checkout < workflow.index('- name: Import Developer ID') < workflow.index('- name: Release')
assert workflow.count('if:') == 2 and 'if: always()' in workflow  # the gate, and credential cleanup
assert 'continue-on-error' not in workflow and 'push:' not in workflow

def run(failure, source=verify):
    with tempfile.TemporaryDirectory(prefix='n2-release-gates-') as tmp:
        root = Path(tmp)
        (root / 'scripts').mkdir()
        (root / 'scripts/verify.sh').write_text(source)
        scripts = {
            'scripts/check.sh': 'gate=$1',
            'scripts/test.sh': 'gate=tests',
            'scripts/smoke.sh': 'gate=smoke',
            'publisher': 'gate=published',
        }
        for name, setup in scripts.items():
            (root / name).write_text('#!/bin/sh\n' + setup + '''
printf '%s\n' "$gate" >> "$RECEIPT"
[ "$gate" != "$FAIL_GATE" ]
''')
        for file in [root / 'scripts/verify.sh', *(root / n for n in scripts)]:
            file.chmod(0o755)
        receipt = root / 'receipt'
        result = subprocess.run(['/bin/sh', '-c', './scripts/verify.sh && ./publisher'],
                                cwd=root, env=dict(os.environ, RECEIPT=str(receipt),
                                                   FAIL_GATE=failure),
                                capture_output=True, text=True)
        return result.returncode, receipt.read_text().splitlines()

gates = ['format', 'lint', 'tests', 'smoke']
for index, gate in enumerate(gates):
    code, receipt = run(gate)
    assert code != 0 and receipt == gates[:index + 1], (gate, code, receipt)
assert run('none') == (0, gates + ['published'])

# Remove the real smoke invocation only in the disposable copy. The same
# failed-smoke assertion must detect that publication is now reachable.
code, receipt = run('smoke', verify.replace('scripts/smoke.sh\n', ''))
assert not (code != 0 and receipt == gates), 'negative control failed to break proof'
assert 'published' in receipt
print('Release gates passed: all failures block publisher; bypass control detected.')

# Exercise the real smoke assertion against a deliberately misrouted fake CLI.
with tempfile.TemporaryDirectory(prefix='n2-smoke-control-') as tmp:
    root = Path(tmp)
    (root / 'scripts').mkdir()
    for name in ['agents', 'vendors.sh']:
        (root / name).write_bytes((repo / name).read_bytes())
        (root / name).chmod(0o755)
    smoke = (repo / 'scripts/smoke.sh').read_text()
    broken = smoke.replace('"$CODEX_HOME"', '"wrong-profile"')
    assert broken != smoke
    (root / 'scripts/smoke.sh').write_text(broken)
    result = subprocess.run(['sh', 'scripts/smoke.sh'], cwd=root, capture_output=True)
    assert result.returncode != 0, 'misrouted CLI passed smoke'
print('Real smoke rejects a wrong profile route.')

# The real lint gate must reject syntax accepted by AST construction alone.
with tempfile.TemporaryDirectory(prefix='n2-lint-control-') as tmp:
    root = Path(tmp)
    (root / 'scripts').mkdir()
    (root / 'bin').mkdir()
    for name in ['agents', 'scripts/check.sh', 'scripts/verify.sh', 'scripts/smoke.sh']:
        (root / name).write_bytes((repo / name).read_bytes())
    (root / 'invalid.py').write_text('return 1')
    (root / 'bin/git').write_text('#!/bin/sh\nprintf "invalid.py\\n"\n')
    (root / 'bin/git').chmod(0o755)
    result = subprocess.run(['sh', 'scripts/check.sh', 'lint'], cwd=root,
                            env=dict(os.environ, PATH=str(root / 'bin') + ':' + os.environ['PATH']),
                            capture_output=True, text=True)
    assert result.returncode != 0 and 'outside function' in result.stderr, result
print('Real lint rejects compiler-invalid Python.')
