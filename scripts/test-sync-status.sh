#!/bin/sh
# `agents fleet sync status` is polled by the panel. It must answer from state
# recorded by the last pass, never by walking every profile file: on real
# profiles that walk took minutes and stacked a new one per poll.
set -u
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2status.XXXXXX")
trap 'rm -rf "$base"' EXIT HUP INT TERM
fail=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { fail=1; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
# Every find the CLI runs is recorded, then performed.
mkdir -p "$base/bin"
printf '#!/bin/sh\n: >> "%s/find-called"\nexec /usr/bin/find "$@"\n' "$base" > "$base/bin/find"
chmod +x "$base/bin/find"
peer() { h=$1; shift; env HOME="$base/$h" PATH="$base/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
           N2_FLEET_AGENTS="$repo/agents" "$repo/agents" "$@"; }
resources() { peer "$1" fleet sync status | awk -F'\t' '$1=="resources"{print $2}'; }
walked() { if [ -e "$base/find-called" ]; then rm -f "$base/find-called"; echo yes; else echo no; fi; }

mkdir -p "$base/alpha" "$base/beta"
peer alpha fleet init --machine alpha >/dev/null
B=$(peer beta fleet init --machine beta | awk '{print $2}')
mkdir -p "$base/alpha/.n2-agents/Work/claude/skills/a"
printf 'skill' > "$base/alpha/.n2-agents/Work/claude/skills/a/SKILL.md"
printf 'rules' > "$base/alpha/.n2-agents/Work/claude/CLAUDE.md"
peer beta fleet pair --home "$base/alpha" \
  --code "$(peer alpha fleet invite --peer "$B" 2>/dev/null)" >/dev/null 2>&1
walked >/dev/null

got=$(resources alpha)
[ "$got" = 0 ] && ok "before any pass, status reports no resources" || bad "before any pass" "resources=$got"
[ "$(walked)" = no ] && ok "status does not walk profiles" || bad "status walked profiles before a pass"

peer alpha fleet sync now >/dev/null 2>&1
walked >/dev/null
got=$(resources alpha)
[ "${got:-0}" -gt 0 ] && ok "after a pass, status reports the pass's resources ($got)" || bad "after a pass" "resources=$got"
[ "$(walked)" = no ] && ok "status still does not walk profiles" || bad "status walked profiles after a pass"

[ "$fail" = 0 ] && echo "Sync status tests passed"
exit "$fail"
