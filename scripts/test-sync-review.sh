#!/bin/sh
# A machine joining a fleet cannot change the fleet's profiles until the
# operator shares its own. Real `agents` peers with disposable homes over the
# exec carrier; no real fleet, account or credential is involved.
set -u
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2review.XXXXXX")
trap 'rm -rf "$base"' EXIT HUP INT TERM
fail=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { fail=1; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want '$2', got '$3'"; fi; }
peer() { h=$1; shift; env HOME="$base/$h" N2_FLEET_AGENTS="$repo/agents" "$repo/agents" "$@"; }
put()  { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }
file() { cat "$base/$1/.n2-agents/$2/claude/CLAUDE.md" 2>/dev/null || echo absent; }
sync_both() { peer beta fleet sync now >/dev/null 2>&1; peer alpha fleet sync now >/dev/null 2>&1; }

mkdir -p "$base/alpha" "$base/beta"
A=$(peer alpha fleet init --machine alpha | awk '{print $2}')
B=$(peer beta fleet init --machine beta | awk '{print $2}')
# alpha holds the fleet's list; beta arrives with its own.
put "$base/alpha/.n2-agents/Work/claude/CLAUDE.md" 'alpha work'
put "$base/alpha/.n2-agents/Shared/claude/CLAUDE.md" 'alpha shared'
put "$base/beta/.n2-agents/Shared/claude/CLAUDE.md" 'beta shared'
put "$base/beta/.n2-agents/Client/claude/CLAUDE.md" 'beta client'
peer beta fleet pair --home "$base/alpha" \
  --code "$(peer alpha fleet invite --peer "$B" 2>/dev/null)" >/dev/null 2>&1

same "joiner holds the profiles it brought" "Client Shared" "$(peer beta fleet sync review | tr '\n' ' ' | sed 's/ $//')"
same "existing member holds nothing" "nothing to review" "$(peer alpha fleet sync review)"

sync_both
same "fleet copy of a shared name is not overwritten" "alpha shared" "$(file alpha Shared)"
same "joiner-only profile does not spread" "absent" "$(file alpha Client)"
same "joiner keeps its own copy while held" "beta shared" "$(file beta Shared)"
same "fleet profiles still reach the joiner" "alpha work" "$(file beta Work)"

same "sharing releases one profile" "shared	Client" "$(peer beta fleet sync share Client)"
sync_both
same "a shared profile joins the fleet" "beta client" "$(file alpha Client)"

peer beta fleet sync share Shared >/dev/null
sync_both
same "sharing a differing profile never overwrites the fleet copy" "alpha shared" "$(file alpha Shared)"
case $(peer beta fleet sync conflicts) in *Shared*) ok "the difference waits as a conflict" ;;
  *) bad "the difference waits as a conflict" "$(peer beta fleet sync conflicts)" ;; esac

if peer beta fleet sync share Client >/dev/null 2>&1; then bad "only held profiles can be shared" "accepted twice"
else ok "only held profiles can be shared"; fi

[ "$fail" = 0 ] && echo "Sync review tests passed"
exit "$fail"
