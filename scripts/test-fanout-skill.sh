#!/bin/sh
# The fan-out skill names only real loop commands and flags, and `agents
# shims` links it into every profile's Claude and Codex skills without
# touching a skill of the same name that someone made themselves.
# Needs .build/release/n2-loop (scripts/test.sh loop builds it).
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
skill="$repo/skills/n2-fanout/SKILL.md"
base=$(mktemp -d "${TMPDIR:-/tmp}/n2skill.XXXXXX")
trap 'rm -rf "$base"' EXIT
fail() { echo "FAIL fan-out skill: $*" >&2; exit 1; }

[ "$(sed -n 1p "$skill")" = --- ] && sed -n 2p "$skill" | grep -qx 'name: n2-fanout' \
  && sed -n 3p "$skill" | grep -q '^description: .\{40,\}' || fail "frontmatter needs name and description"

help=$(N2_AGENTS_CLI=/bin/true "$repo/.build/release/n2-loop" --help)
for verb in $(grep -o 'agents loop [a-z]*' "$skill" | awk '{print $3}' | sort -u); do
  printf '%s\n' "$help" | grep -q "agents loop $verb " || fail "names 'agents loop $verb', which --help doesn't list"
done
for flag in $(grep -o -- '--[a-z][a-z-]*' "$skill" | sort -u); do
  printf '%s\n' "$help" | grep -q -- "$flag" || fail "names $flag, which --help doesn't list"
done

export HOME="$base/home" N2_AGENTS_ROOT="$base/home/.n2-agents" PATH="/usr/bin:/bin"
mkdir -p "$HOME/.claude" "$HOME/.codex" "$N2_AGENTS_ROOT/Work/claude" "$N2_AGENTS_ROOT/Work/codex" \
  "$N2_AGENTS_ROOT/Mine/claude/skills/n2-fanout"
echo mine > "$N2_AGENTS_ROOT/Mine/claude/skills/n2-fanout/SKILL.md"
shims() { "$repo/agents" shims "$@" >/dev/null 2>&1 || true; }   # PATH links need an install; skills don't
linked() { [ -L "$1/skills/n2-fanout" ] && [ "$(readlink "$1/skills/n2-fanout")" = "$repo/skills/n2-fanout" ] \
  && cmp -s "$1/skills/n2-fanout/SKILL.md" "$skill"; }
shims; shims
for slot in "$HOME/.claude" "$HOME/.codex" "$N2_AGENTS_ROOT/Work/claude" "$N2_AGENTS_ROOT/Work/codex"; do
  linked "$slot" || fail "$slot/skills/n2-fanout isn't linked to the skill"
done
[ ! -L "$N2_AGENTS_ROOT/Mine/claude/skills/n2-fanout" ] \
  && [ "$(cat "$N2_AGENTS_ROOT/Mine/claude/skills/n2-fanout/SKILL.md")" = mine ] || fail "replaced someone's own skill"
shims --remove
[ ! -e "$HOME/.claude/skills/n2-fanout" ] && [ ! -e "$N2_AGENTS_ROOT/Work/codex/skills/n2-fanout" ] || fail "--remove left a link"
[ "$(cat "$N2_AGENTS_ROOT/Mine/claude/skills/n2-fanout/SKILL.md")" = mine ] || fail "--remove touched someone's own skill"
echo "Fan-out skill: commands and flags exist; linked into 4 slots, idempotent, own skill kept, removed cleanly"
