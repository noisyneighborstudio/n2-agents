#!/usr/bin/python3
"""Seed isolated QA profiles from local profile files. Never writes the source."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

if os.environ.get('N2_FLEET_QA') != '1':
    sys.exit('Import is available only in the fleet QA build.')
if sys.argv[1:] not in ([], ['--credentials']):
    sys.exit('usage: agents fleet sync import-local [--credentials]')
def carries_secret(path):
    # Use the same source/arrival gate as normal fleet replication. Failure to
    # inspect a file is not permission to import its credential material.
    result = subprocess.run(['sh', '-c', '. "$1"; sync_file_carries_secret "$2"',
                             'n2-import', str(Path(__file__).with_name('fleet-sync.sh')), str(path)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode != 1

credentials = '--credentials' in sys.argv
home = Path.home()
source, target = home / '.n2-agents', home / '.n2-agents-qa'
os.umask(0o077)
target.mkdir(exist_ok=True)
if target.is_symlink():
    sys.exit('QA profile root must not be a symlink.')
vendors = ('claude', 'codex', 'grok', 'cursor', 'opencode', 'muse')
settings = {'settings.json', 'settings.local.json', 'config.toml', 'config.json', 'config.yaml', 'CLAUDE.md', 'AGENTS.md', 'GEMINI.md'}
auth = {'.credentials.json', 'auth.json', 'oauth_creds.json', 'credentials.json'}
mcp = {'.mcp.json', 'mcp.json', 'mcp_servers.json'}
subdirs = {'skills', 'agents', 'commands', 'rules', 'prompts', 'hooks', 'mcp'}
count = 0
for profile in sorted(source.iterdir()) if source.exists() else []:
    if not profile.is_dir() or not re.fullmatch('[A-Za-z0-9]+', profile.name) or profile.name.lower() == 'fleet':
        continue
    dest_profile = target / profile.name
    if dest_profile.is_symlink():
        sys.exit('Refusing a symlinked QA profile.')
    dest_profile.mkdir(exist_ok=True)
    for vendor in vendors:
        slot_rel = vendor + '/' + vendor if vendor in ('opencode', 'muse') else vendor
        slot = profile / slot_rel
        if not slot.is_dir():
            continue
        resolved = slot.resolve()
        dest = dest_profile / slot_rel
        for current, dirs, files in os.walk(slot, followlinks=False):
            rel_dir = Path(current).relative_to(slot)
            if rel_dir == Path('.'):
                dirs[:] = [d for d in dirs if d in subdirs]
            dirs[:] = [d for d in dirs if d not in ('.trash', '.git', 'node_modules', '__pycache__') and not (Path(current) / d).is_symlink()]
            for name in files:
                rel = rel_dir / name
                if rel_dir == Path('.') and name not in settings | auth | mcp:
                    continue
                src = slot / rel
                try:
                    src.resolve().relative_to(resolved)
                except ValueError:
                    continue
                if not credentials and (name in auth | mcp or rel.parts[0] == 'mcp' or carries_secret(src)):
                    continue
                out = dest / rel
                if any(p.is_symlink() for p in [out] + list(out.parents) if p == target or target in p.parents):
                    continue
                if out.exists():
                    continue
                out.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, out)
                out.chmod(src.stat().st_mode & 0o700 | 0o600)
                count += 1
        if any(p.is_symlink() for p in [dest] + list(dest.parents) if p == target or target in p.parents):
            continue
        if credentials and vendor == 'claude' and not (dest / '.credentials.json').exists() and not (dest / '.credentials.json').is_symlink():
            paths = {str(slot), str(resolved)}
            services = ['Claude Code-credentials-' + hashlib.sha256(p.encode()).hexdigest()[:8] for p in paths]
            if profile.name == 'Default':
                services.append('Claude Code-credentials')
            candidates = []
            for service in services:
                result = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', service, '-w'], capture_output=True)
                if result.returncode == 0:
                    try:
                        value = json.loads(result.stdout)
                        if value.get('claudeAiOauth', {}).get('accessToken'):
                            candidates.append(value)
                    except (ValueError, TypeError):
                        pass
            if candidates:
                value = max(candidates, key=lambda v: v['claudeAiOauth'].get('expiresAt', 0))
                dest.mkdir(parents=True, exist_ok=True)
                with (dest / '.credentials.json').open('x') as f:
                    json.dump(value, f)
                count += 1
print(f'Imported {count} files into isolated QA profiles. Existing QA files were preserved.')
