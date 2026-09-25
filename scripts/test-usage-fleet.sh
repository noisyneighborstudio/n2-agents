#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2usagefleet.XXXXXX")
trap 'rm -rf "$base"' EXIT
peer() { h=$1; shift; HOME="$base/$h" N2_FLEET_AGENTS="$repo/agents" "$repo/agents" "$@"; }
mkdir -p "$base/a" "$base/b"
a=$(peer a fleet init --machine a | cut -f2)
b=$(peer b fleet init --machine b | cut -f2)
peer b fleet pair --home "$base/a" --code "$(peer a fleet invite --peer "$b" 2>/dev/null)" >/dev/null
printf '%s\n' '{"status":"restricted","identity":{"status":"unknown"},"restrictions":[{"scope":"unknown","reason":"quota-rejected"}]}' |
  peer a usage record --provider codex --profile Default --kind quota-rejected > "$base/original"
peer b fleet sync tick --interval 1 >/dev/null
peer b fleet sync tick --interval 1 >/dev/null
peer b usage history > "$base/history"
python3 - "$base/original" "$base/history" "$a" <<'PY'
import json,sys
original=json.load(open(sys.argv[1]))
history=json.load(open(sys.argv[2]))
assert history == [original], 'replayed observations must retain origin, time, and identity'
assert original['origin'] == sys.argv[3]
assert original['kind'] == 'quota-rejected'
PY
echo 'ok authenticated usage exchange retains original event without replay duplication'
