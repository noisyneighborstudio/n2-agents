#!/bin/sh
# Deterministic planning with synthetic capability reports; no live auth claim.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2preferences.XXXXXX")
trap 'rm -rf "$base"' EXIT
. "$repo/fleet-sync.sh"
. "$repo/fleet-exec.sh"
fleet_root=$base/fleet
N2_VENDORS='codex claude'
mkdir -p "$base/plan"
: > "$base/requires"
fleet_peer_ids() { echo peer; }
fleet_peer_dir() { echo "$base/peer"; }
fleet_meta() { echo test-machine; }
fleet_approved() { return 0; }
fleet_slug() { echo peer; }
fleet_meta_get_file() { sed -n "s/^$2=//p" "$1"; }
exec_peer_caps() {
  printf 'running=0\nmean_task=100\nbps=10000\nvendor=codex\tinstalled=yes\tauth=yes\tmean=10\nvendor=claude\tinstalled=yes\tauth=yes\tmean=20\n' > "$2"
}
plan() { exec_plan "$base/plan" 0 '' "${1:-}" "$base/requires" ''; }
first() { head -1 "$base/plan/plan" | cut -f3; }
plan
[ "$(first)" = codex ]
echo 'ok default permits fastest supported agent'
exec_preferences set claude
plan
[ "$(first)" = claude ]
grep -q agent-excluded-by-preference "$base/plan/rejected"
echo 'ok preference excludes faster disallowed agent'
if plan codex; then echo 'FAIL pin bypassed preference'; exit 1; fi
echo 'ok pin cannot bypass eligibility policy'
if exec_preferences set unknown 2>/dev/null; then exit 1; fi
[ "$(exec_preferences show)" = claude ]
echo 'ok invalid update preserves prior preferences'
exec_preferences set claude codex claude
plan
[ "$(first)" = codex ]
[ "$(exec_preferences show | wc -l | tr -d ' ')" = 2 ]
echo 'ok allowed agents rank by completion time, not list order'
exec_preferences reset
plan codex
[ "$(first)" = codex ]
[ "$(exec_preferences show)" = all ]
echo 'ok explicit reset restores default policy'

# The preference is a replicated fleet resource, not a machine-local file: it
# must live at the address sync advertises, or setting it on one machine would
# silently stay there.
[ "$(exec_pref_file)" = "$(sync_agents_pref)" ]
[ "$(sync_classify - "$SYNC_AGENTS_REL")" = tools ]
[ "$(sync_addr tools - - "$SYNC_AGENTS_REL")" = "$SYNC_AGENTS_ADDR" ]
[ "$(sync_path tools - - "$SYNC_AGENTS_REL")" = "$(exec_pref_file)" ]
echo 'ok the preference is stored at its replicated sync address'
