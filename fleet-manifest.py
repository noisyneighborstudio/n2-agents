#!/usr/bin/python3
"""Hash one vendor slot. Emits addresses and digests, never bytes.

    fleet-manifest.py <slot> <profile> <vendor> <shareable 0|1> <owner-managed 0|1>
    fleet-manifest.py --carries-secret <file>    exit 0 when the file holds one

One process reads each file once, digests it and, unless the provider's
credentials may leave this machine, scans those same bytes with the rules of
the shell's sync_file_carries_secret. The shell retains every other policy
gate, conflict handling, tombstones and writes. The key lists come from the
shell (N2_SYNC_SECRET_KEYS, N2_SYNC_SECRET_HEADER_KEYS) so there is one source.
"""
import hashlib
import os
from pathlib import Path
import re
import sys

KEYS = os.environ['N2_SYNC_SECRET_KEYS'].encode()
HEADER_KEYS = os.environ['N2_SYNC_SECRET_HEADER_KEYS'].encode()
# The shell's four greps, over text with every whitespace run folded to one
# space. Case-insensitive except the environment-variable key names.
RULES = (re.compile(rb'\[[^\]]*(mcp_servers|mcpServers|mcp)[^\]]*\]', re.I),
         re.compile(rb'(mcp_servers|mcpServers|mcp)["\']?\s*\.', re.I),
         re.compile(rb'["\']?(' + KEYS + rb')["\']?\s*[:=]'),
         re.compile(rb'["\']?(' + HEADER_KEYS + rb')["\']?\s*[:=]', re.I))
SPACE = re.compile(rb'[ \t\n\v\f\r]+')
ESCAPE = re.compile(rb'\\u([0-9a-fA-F]{4})|\\U([0-9a-fA-F]{8})')


def matches(text):
    folded = SPACE.sub(b' ', text)
    return any(rule.search(folded) for rule in RULES)


def carries_secret(data):
    if matches(data):
        return True
    # A JSON key may be written escaped; only printable ASCII is decoded.
    if not re.search(rb'\\[uU]', data):
        return False
    def decode(m):
        value = int(m.group(1) or m.group(2), 16)
        return bytes([value]) if 32 <= value < 127 else m.group(0)
    return matches(ESCAPE.sub(decode, data))


if sys.argv[1] == '--carries-secret':
    sys.exit(0 if carries_secret(Path(sys.argv[2]).read_bytes()) else 1)

slot, profile, vendor = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
shareable, owner_managed = sys.argv[4] == '1', sys.argv[5] == '1'
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
        # Installed per Mac by the vendor's own tool; see sync_classify.
        if (vendor, parts[1]) in (('codex', '.system'), ('claude', 'synced')):
            return None
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

# Credential material leaves only under the provider's opt-in, and never from
# an owner-managed slot (the shell's sync_owner_payload_ok).
withheld = owner_managed or not shareable
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
        if kind in ('auth', 'mcp') and withheld:
            continue
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if withheld and carries_secret(data):
            continue
        print(f'{kind}|{profile}|{vendor}|{rel}\t{hashlib.sha256(data).hexdigest()}')
