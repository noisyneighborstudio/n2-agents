#!/bin/sh
# The manifest's single-process secret scan must decide exactly as the shell's
# sync_file_carries_secret, which still guards scope checks and writes. Every
# case below, and every tracked file in the repo, is run through both.
set -u
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2scan.XXXXXX")
trap 'rm -rf "$base"' EXIT
root=$base/.n2-agents
. "$repo/fleet.sh"; . "$repo/fleet-sync.sh"
export N2_SYNC_SECRET_KEYS="$SYNC_SECRET_KEYS" N2_SYNC_SECRET_HEADER_KEYS="$SYNC_SECRET_HEADER_KEYS"

mkdir -p "$base/c"; n=0
case_() { n=$((n+1)); printf '%b' "$1" > "$base/c/$n"; }
case_ 'plain skill text\n'
case_ '{"env": {"ANTHROPIC_API_KEY": "x"}}'
case_ 'OPENAI_API_KEY = "x"\n'
case_ "'OPENAI_API_KEY' = 'x'\n"
case_ '{ "Authorization"\n  : "Bearer x" }'
case_ '{"\\u0041uthorization": "Bearer x"}'
case_ '{"\\U00000041uthorization": "Bearer x"}'
case_ '{"\\u00e9uthorization": "x"}'
case_ '[mcp_servers.github]\ncommand = "x"\n'
case_ 'mcp_servers.github.command = "x"\n'
case_ '{"mcpServers": {}}'
case_ 'CLAUDE_CODE_MAX_OUTPUT_TOKENS: 8192\n'
case_ '{"authorizationRequired": true}'
case_ 'anthropic_api_key = "x"\n'
case_ 'API_KEY: x\n'
case_ 'password=x\n'
case_ 'no secrets, just tokens of appreciation\n'
case_ ''
case_ 'line one\r\napiKey\r\n  : x\r\n'
case_ '\001\002\000binary\000token=\377'
case_ '# MCP.note\n'
for f in $(cd "$repo" && git ls-files); do
  [ -f "$repo/$f" ] && [ ! -L "$repo/$f" ] || continue
  n=$((n+1)); cp "$repo/$f" "$base/c/$n"
done

diff=0 secret=0
for f in "$base"/c/*; do
  if sync_file_carries_secret "$f"; then s=1; else s=0; fi
  if /usr/bin/python3 "$repo/fleet-manifest.py" --carries-secret "$f"; then p=1; else p=0; fi
  [ "$s" = 1 ] && secret=$((secret+1))
  [ "$s" = "$p" ] || { diff=$((diff+1)); echo "FAIL scan parity: case ${f##*/} shell=$s python=$p" >&2; }
done
echo "Scan parity: $n files, $secret carrying a secret, $diff disagreements"
[ "$diff" = 0 ] && [ "$secret" -ge 10 ]
