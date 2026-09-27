"""Exercise account reset using fake CLIs and an isolated home."""
import os
from pathlib import Path
import subprocess
import tempfile


def run_case(answer, failure="", args=()):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        slots = [root / ".n2-agents" / p / "codex" for p in ("Default", "Work")]
        for slot in slots:
            slot.mkdir(parents=True)
            (slot / "auth.json").write_text("old-account")
            (slot / "history.jsonl").write_text("keep")
            (slot.parent / "cursor").mkdir()
        fake = bin_dir / "codex"
        fake.write_text('''#!/bin/sh
echo "codex:$CODEX_HOME:$*" >> "$HOME/calls"
case "$1" in
  logout)
    [ "$FAILURE" != logout ] || exit 1
    [ "$FAILURE" = retained ] || rm "$CODEX_HOME/auth.json"
    ;;
  login)
    [ "${2:-}" != status ] || exit 0
    [ "$FAILURE" != login ] || exit 1
    echo new-account > "$CODEX_HOME/auth.json"
    ;;
esac
''')
        fake.chmod(0o755)
        cursor = bin_dir / "cursor-agent"
        cursor.write_text('''#!/bin/sh
echo "cursor:$CURSOR_CONFIG_DIR:$*" >> "$HOME/calls"
''')
        cursor.chmod(0o755)
        env = dict(os.environ, HOME=str(root), PATH=f"{bin_dir}:/usr/bin:/bin", FAILURE=failure)
        result = subprocess.run(["./agents", "reonboard", *args], input=answer,
                                text=True, capture_output=True, env=env)
        calls = (root / "calls").read_text().splitlines() if (root / "calls").exists() else []
        for slot in slots:
            assert (slot / "history.jsonl").read_text() == "keep"
        return result, calls


result, calls = run_case("no\n")
assert result.returncode == 0 and not calls
result, calls = run_case("SIGN OUT\n" + "\nYES\n" * 3)
assert result.returncode == 0, result.stdout + result.stderr
logouts = [i for i, call in enumerate(calls) if call.endswith(":logout")]
logins = [i for i, call in enumerate(calls) if call.endswith(":login")]
assert len(logouts) == 3 and len(logins) == 3, calls
assert max(logouts) < min(logins), calls
assert sum(call.startswith("cursor:") and call.endswith(":login") for call in calls) == 1
assert any("/Work/codex:login" in call for call in calls)
for failure in ("logout", "retained"):
    result, calls = run_case("SIGN OUT\n", failure)
    assert result.returncode != 0 and not any(call.endswith(":login") for call in calls)
result, calls = run_case("SIGN OUT\n\n", "login")
assert result.returncode != 0 and "setup stopped" in result.stderr
result, calls = run_case("SIGN OUT\n\nNO\n")
assert result.returncode != 0 and "account not confirmed" in result.stderr
print("Reonboard tests passed")

result, calls = run_case("", args=("--logout-only", "--yes"))
assert result.returncode == 0, result.stdout + result.stderr
assert len(calls) == 3 and all(call.endswith(":logout") for call in calls), calls
assert "Continue in the N2 Agents setup window" in result.stdout
result, calls = run_case("", "logout", ("--logout-only", "--yes"))
assert result.returncode != 0 and not any(call.endswith(":login") for call in calls)

# Claude can report logout success while symlink, canonical-path and legacy
# keychain entries survive. Clear exactly the credential aliases N2 reads.
import hashlib
import json


def claude_alias_case(profile, keychain_error=False):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        target = root / '.claude-profiles' / profile
        target.mkdir(parents=True)
        slot = root / '.claude' if profile == 'Default' else root / '.n2-agents' / profile / 'claude'
        slot.parent.mkdir(parents=True, exist_ok=True)
        slot.symlink_to(target)
        credentials = target / '.credentials.json'
        credentials.write_text(json.dumps({'claudeAiOauth': {'accessToken': 'stale'}, 'other': 'keep'}))
        (target / 'history.jsonl').write_text('keep history')
        aliases = ['Claude Code-credentials-' + hashlib.sha256(str(p).encode()).hexdigest()[:8]
                   for p in (slot, slot.resolve())]
        if profile == 'Default':
            aliases.append('Claude Code-credentials')
        untouched = ['unrelated-service']
        if profile != 'Default':
            untouched.append('Claude Code-credentials')
        keychain = root / 'keychain.json'
        keychain.write_text(json.dumps(aliases + untouched))
        (bin_dir / 'security').write_text('''#!/usr/bin/python3
import json, os, sys
path = os.path.join(os.environ['HOME'], 'keychain.json')
services = json.load(open(path))
with open(os.path.join(os.environ['HOME'], 'security-calls'), 'a') as log:
    log.write(repr(sys.argv) + chr(10))
service = sys.argv[sys.argv.index('-s') + 1]
if service not in services:
    sys.exit(44)
if sys.argv[1] == 'delete-generic-password':
    if os.environ.get('FAKE_KEYCHAIN_ERROR') == '1':
        sys.exit(36)
    services.remove(service)
    with open(path, 'w') as f:
        json.dump(services, f)
''')
        (bin_dir / 'claude').write_text('''#!/bin/sh
[ "$*" = 'auth logout' ] || exit 2
echo 'Successfully logged out from your Anthropic account.'
''')
        for name in ('security', 'claude'):
            (bin_dir / name).chmod(0o755)
        env = dict(os.environ, HOME=str(root), PATH=f'{bin_dir}:/usr/bin:/bin',
                   FAKE_KEYCHAIN_ERROR='1' if keychain_error else '0')
        result = subprocess.run(['./agents', 'reonboard', '--logout-only', '--yes'],
                                env=env, text=True, capture_output=True)
        if keychain_error:
            assert result.returncode != 0 and 'credential cleanup failed' in result.stderr
            assert json.loads(keychain.read_text()) == aliases + untouched
        else:
            assert result.returncode == 0, result.stdout + result.stderr
            assert json.loads(keychain.read_text()) == untouched, (result.stdout, json.loads(keychain.read_text()), aliases, (root/'security-calls').read_text())
            assert json.loads(credentials.read_text()) == {'other': 'keep'}
            status = subprocess.run(['./agents', 'authed', profile], env=env, text=True, capture_output=True)
            assert status.stdout.strip() == 'claude\tno', status.stdout
        assert (target / 'history.jsonl').read_text() == 'keep history'


claude_alias_case('Default')
claude_alias_case('Work')
claude_alias_case('Default', keychain_error=True)
print('Claude logout alias tests passed')
