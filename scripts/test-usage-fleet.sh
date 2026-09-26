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
# More durable restrictions than fit in one response must cross the actual
# signed carrier, even when diagnostic history has already expired.
python3 - "$repo" "$base/a/.n2-agents" "$a" <<'PY'
import importlib.util,sys,time
spec=importlib.util.spec_from_file_location('usage_store',sys.argv[1]+'/usage-store.py')
u=importlib.util.module_from_spec(spec); spec.loader.exec_module(u)
j=u.Journal(sys.argv[2],sys.argv[3])
for i in range(8105):
    j.append('codex','Paged'+str(i),'quota-rejected',{'status':'restricted'},time.time()-40*86400+i)
j.db.close()
PY
peer b fleet sync tick --interval 1 >/dev/null
peer b usage restrictions > "$base/partial-restrictions"
python3 - "$base/partial-restrictions" <<'PY'
import json,sys
assert len(json.load(open(sys.argv[1])))==1, 'eight-page tick must retain old state until remaining pages arrive'
PY
peer b fleet sync tick --interval 1 >/dev/null
peer b usage restrictions > "$base/restrictions"
python3 - "$base/restrictions" "$a" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1]))
assert len(rows)==8106, 'all durable restrictions must arrive across pages'
assert all(row['origin']==sys.argv[2] for row in rows)
PY
echo 'ok paginated signed exchange publishes all 8106 durable restrictions across bounded ticks'
