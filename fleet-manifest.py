#!/usr/bin/python3
"""Hash one credential-authorized slot. Emits addresses and digests, never bytes.

The shell retains policy gates, conflict handling, tombstones and writes. This
path is only used after the provider's credential sharing has been authorized.
"""
import hashlib
import os
from pathlib import Path
import sys

slot, profile, vendor = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
base = slot.resolve()
skip_dirs = {'.git', '.trash', 'node_modules', '__pycache__', 'cache', 'tmp'}
root_skip = {'projects', 'statsig', 'sessions', 'todos', 'shell-snapshots', 'ide'}

def contained(path):
    try:
        path.resolve().relative_to(base)
        return True
    except (ValueError, OSError, RuntimeError):
        return False

def classify(rel):
    parts = rel.parts
    name = parts[-1]
    if parts[0] in root_skip or parts[0].startswith('history'):
        return None
    if any(p in skip_dirs for p in parts[:-1]) or name.endswith(('.log', '.lock', '.sock')) or name == '.DS_Store':
        return None
    if parts[0] == 'skills' and len(parts) > 1:
        return 'skills'
    if name in ('.credentials.json', 'auth.json', 'oauth_creds.json', 'credentials.json'):
        return 'auth'
    if name in ('.mcp.json', 'mcp.json', 'mcp_servers.json') or parts[0] == 'mcp' and len(parts) > 1:
        return 'mcp'
    if vendor == 'codex' and str(rel) == '.n2-owner.json':
        return 'settings'
    if str(rel) in ('settings.json', 'settings.local.json', 'config.toml', 'config.json', 'config.yaml', 'CLAUDE.md', 'AGENTS.md', 'GEMINI.md'):
        return 'settings'
    if parts[0] in ('agents', 'commands', 'rules', 'prompts', 'hooks') and len(parts) > 1:
        return 'settings'
    return None

for current, dirs, files in os.walk(slot, followlinks=True):
    here = Path(current)
    relative = here.relative_to(slot)
    ancestors = {slot.joinpath(*relative.parts[:n]).resolve() for n in range(len(relative.parts) + 1)}
    dirs[:] = [d for d in dirs if d not in skip_dirs and contained(here / d) and (here / d).resolve() not in ancestors
               and not (here == slot and (d in root_skip or d.startswith('history')))]
    for name in files:
        path = here / name
        rel = path.relative_to(slot)
        if any(c in str(rel) for c in ('\n', '\t')) or '\\n' in str(rel):
            continue
        kind = classify(rel)
        if kind is None or not contained(path) or not path.is_file():
            continue
        try:
            with path.open('rb') as stream:
                digest = hashlib.sha256()
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
            print(f'{kind}|{profile}|{vendor}|{rel}\t{digest.hexdigest()}')
        except OSError:
            continue
