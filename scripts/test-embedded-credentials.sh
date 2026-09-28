#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2embedded.XXXXXX")
trap 'rm -rf "$base"' EXIT
peer() { h=$1; shift; HOME="$base/$h" N2_FLEET_AGENTS="$repo/agents" "$repo/agents" "$@"; }
# Dotted TOML keys also embed MCP configuration without a table header.
printf 'mcp_servers.test.env.GH_PAT="synthetic-dotted"\n' > "$base/dotted.toml"
( . "$repo/fleet-sync.sh"; sync_file_carries_secret "$base/dotted.toml" )
echo 'ok dotted TOML MCP records require credential permission'
for encoded in '["\U0000006dcp_servers".test.env]' '"\U0000006dcp_servers".test.env.GH_PAT="synthetic"'; do
  printf '%s\n' "$encoded" > "$base/escaped.toml"
  ( . "$repo/fleet-sync.sh"; sync_file_carries_secret "$base/escaped.toml" )
done
echo 'ok eight-digit TOML Unicode keys require credential permission'
mkdir -p "$base/a" "$base/b"
a=$(peer a fleet init --machine a | cut -f2)
b=$(peer b fleet init --machine b | cut -f2)
peer b fleet pair --home "$base/a" --code "$(peer a fleet invite --peer "$b" 2>/dev/null)" >/dev/null
mkdir -p "$base/a/.n2-agents/Work/codex"
printf '[mcp_servers.test.env]\nGH_PAT="synthetic-review-credential"\n' > "$base/a/.n2-agents/Work/codex/config.toml"
peer a fleet sync now >/dev/null
[ ! -f "$base/b/.n2-agents/Work/codex/config.toml" ]
echo 'ok embedded MCP does not leave a credential-opted-out sender'
peer a fleet sync auth enable codex >/dev/null 2>&1
peer b fleet sync now >/dev/null
[ ! -f "$base/b/.n2-agents/Work/codex/config.toml" ]
echo 'ok incoming embedded MCP requires receiver credential permission'
peer b fleet sync auth enable codex >/dev/null 2>&1
peer a fleet sync now >/dev/null
cmp "$base/a/.n2-agents/Work/codex/config.toml" "$base/b/.n2-agents/Work/codex/config.toml"
echo 'ok explicit credential sharing permits embedded MCP'
mkdir -p "$base/qa/.n2-agents/Work/claude" "$base/qa/.n2-agents/Work/codex"
printf '{"env":{"ANTHROPIC_API_KEY":"synthetic-import-credential"}}' > "$base/qa/.n2-agents/Work/claude/settings.json"
printf '{"mcpServers":{"test":{"args":["positional-credential"]}}}' > "$base/qa/.n2-agents/Work/codex/config.json"
printf 'model="fixture"\n' > "$base/qa/.n2-agents/Work/codex/config.toml"
HOME="$base/qa" N2_FLEET_QA=1 /usr/bin/python3 "$repo/fleet-qa-import.py" >/dev/null
[ ! -f "$base/qa/.n2-agents-qa/Work/claude/settings.json" ]
[ ! -f "$base/qa/.n2-agents-qa/Work/codex/config.json" ]
cmp "$base/qa/.n2-agents/Work/codex/config.toml" "$base/qa/.n2-agents-qa/Work/codex/config.toml"
echo 'ok settings-only QA import excludes embedded credentials and keeps ordinary settings'
