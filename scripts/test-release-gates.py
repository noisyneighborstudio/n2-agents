#!/usr/bin/env python3
"""Execute the publication gate chain with disposable checks and publisher."""
from pathlib import Path
import os
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
verify = (repo / 'scripts/verify.sh').read_text()
workflow = (repo / '.github/workflows/release.yml').read_text()
# Publication must verify its own checkout before any signing or release step.
assert workflow.count('run: scripts/verify.sh') == 1
assert workflow.index('run: scripts/verify.sh') < workflow.index('- name: Import Developer ID')
assert workflow.index('run: scripts/verify.sh') < workflow.index('- name: Release')
assert 'continue-on-error' not in workflow
assert 'if:' not in workflow[:workflow.index('- name: Release')]
assert 'run: scripts/verify.sh' in (repo / '.github/workflows/ci.yml').read_text()

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
