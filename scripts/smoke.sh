#!/bin/sh
# Real CLI against a disposable home; synthetic provider only.
set -eu
cd "$(dirname "$0")/.."
smoke_root=$(mktemp -d)
trap 'rm -rf "$smoke_root"' EXIT HUP INT TERM
mkdir -p "$smoke_root/home/.n2-agents/Fixture/codex" "$smoke_root/bin"
cat > "$smoke_root/bin/codex" <<'PROVIDER'
#!/bin/sh
printf '%s\n' "$CODEX_HOME"
PROVIDER
chmod +x "$smoke_root/bin/codex"
export HOME="$smoke_root/home" PATH="$smoke_root/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset CODEX_HOME CLAUDE_CONFIG_DIR OPENAI_API_KEY
./agents help > "$smoke_root/help"
grep -Fq 'agents loop' "$smoke_root/help"
./agents run Fixture --vendor codex --version > "$smoke_root/route"
test "$(cat "$smoke_root/route")" = "$HOME/.n2-agents/Fixture/codex"
sh scripts/test-usage.sh
echo 'Smoke passed: real CLI routes to isolated profile.'
