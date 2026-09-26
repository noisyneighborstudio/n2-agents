#!/usr/bin/python3
"""Compare fast manifest output to the shell implementation on identical slots."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    home = base / 'home'
    home.mkdir()
    slot = home / '.n2-agents/Work/codex'
    files = {
        'config.toml': b'model="fixture"', 'auth.json': b'{"token":"synthetic-only"}',
        'skills/demo/SKILL.md': b'instructions', 'skills/demo/a.bin': b'\x00\xff\x01',
        'skills/demo/.trash/old.md': b'archived', 'skills/demo/node_modules/mod/a.js': b'cached',
        'skills/demo/__pycache__/mod.pyc': b'cached', 'skills/demo/.git/config': b'git',
        'skills/demo/cache/a': b'cache', 'skills/demo/file.log': b'log',
        'settings.json': b'{}', '.mcp.json': b'{}', 'mcp/server.json': b'{}',
        'rules/test.md': b'rule', 'sessions/history.jsonl': b'private history',
        'history.txt': b'history', 'unknown.txt': b'out of scope',
        'skills/demo/a|b.md': b'pipe in name', 'skills/demo/space name.md': b'space',
    }
    for rel, content in files.items():
        p = slot / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(content)
    (base / 'outside').write_bytes(b'never export')
    (slot / 'skills/demo/outside.md').symlink_to(base / 'outside')
    (slot / 'skills/demo/inside.md').symlink_to(slot / 'rules/test.md')
    (slot / 'skills/demo/cycle').symlink_to(slot / 'skills')
    slow = base / 'slow'
    slow.mkdir()
    for name in ('agents', 'vendors.sh', 'fleet.sh', 'fleet-sync.sh', 'fleet-exec.sh'):
        shutil.copy2(repo / name, slow / name)
    env = dict(os.environ, HOME=str(home))
    def cli(where, *args):
        return subprocess.check_output([str(where / 'agents'), *args], env=env, stderr=subprocess.DEVNULL, text=True)
    cli(repo, 'fleet', 'init')
    cli(repo, 'fleet', 'sync', 'auth', 'enable', 'codex')
    fast = sorted(cli(repo, 'fleet', 'sync', 'scope').splitlines())
    original = sorted(cli(slow, 'fleet', 'sync', 'scope').splitlines())
    assert fast == original, (set(fast) - set(original), set(original) - set(fast))
    assert not any('outside.md' in line or '/cycle/' in line for line in fast)
    assert any('inside.md' in line for line in fast)
    assert not any('.trash' in line or 'node_modules' in line for line in fast)
print('Fast manifest matches shell: binary files, scoped paths, symlinks, cycles, archived skills and credentials')
