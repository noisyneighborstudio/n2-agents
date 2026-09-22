#!/bin/sh
# Native fleet UI tests. The Swift panel parses the fleet CLI's output, so the
# thing worth testing is that contract: these checks feed the parsers bytes
# captured from a live CLI fixture (regenerated below, not pasted from memory)
# and fail if either side drifts.
set -u
cd "$(dirname "$0")/.."
command -v swiftc >/dev/null || { echo "SKIP: swiftc not installed"; exit 0; }

work=$(mktemp -d "${TMPDIR:-/tmp}/n2nui.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

# 1. The captured shapes must still be what the CLI emits today. A fixture peer
#    runs under its own HOME, so nothing touches a real fleet.
peer() { n=$1; shift; HOME=$work/$n N2_FLEET_AUTHORIZED_KEYS=$work/$n/ak sh ./agents "$@" 2>&1; }
mkdir -p "$work/a"
peer a fleet init --machine alpha >/dev/null || { echo "FAIL: fleet init"; exit 1; }
peer a fleet tools add ripgrep --version 14.1.0 --check 'echo 13.0.0' --install 'true' >/dev/null
peer a fleet tools add jq --check 'false' --install 'true' --disruptive >/dev/null

fail=0
expect_shape() {  # <name> <regex> <text>
  if printf '%s\n' "$3" | grep -qE "$2"; then echo "ok $1"; else
    echo "FAIL $1 — got: $3"; fail=$((fail+1)); fi
}
expect_shape "fleet status emits a self line the panel can read" \
  '^self	alpha	SHA256:' "$(peer a fleet status --no-probe)"
expect_shape "fleet peers emits five tab-separated columns" \
  '^SHA256:[^	]+	alpha	self	approved	self$' "$(peer a fleet peers --no-probe)"
expect_shape "sync status still reports auth support per lab" \
  '^auth	[a-z]+	(full|partial|unverified|unsupported)	(on|off)$' "$(peer a fleet sync status)"
expect_shape "tools list is pipe-separated with a flags column" \
  '^jq\|\|false\|true\|disruptive$' "$(peer a fleet tools list)"
expect_shape "tools status reports the CLI's state vocabulary" \
  '^ripgrep	(ok|install|update|unmanaged|invalid)$' "$(peer a fleet tools status)"

# The exception list numbers its rows, and the panel withdraws by that number:
# if the prefix leaked into the address the label would read "1:profile".
peer a fleet sync except add profile Work claude >/dev/null
expect_shape "sync except list numbers each row before the address" \
  '^1:profile\|Work\|claude\|\*$' "$(peer a fleet sync except list)"

# The feeds the panel reads on every refresh. On a fleet that has done nothing
# they must be empty and exit 0 — an error here would draw a fake row.
for v in "sync conflicts" "task list" "task notices" "tools deferred"; do
  out=$(peer a fleet $v); rc=$?
  if [ "$rc" = 0 ] && [ -z "$out" ]; then echo "ok fleet $v is empty and quiet before anything happens"
  else echo "FAIL fleet $v — rc=$rc out: $out"; fail=$((fail+1)); fi
done

# Dispatch pins: the panel offers a machine pin and an agent pin, so the CLI
# has to document and accept both. `--plan` dispatches nothing, which makes
# this safe to run against a one-machine fixture fleet.
expect_shape "task help documents the machine pin" '\-\-machine <id\|name>' "$(peer a fleet task help)"
expect_shape "task help documents the agent pin" '\-\-agent <vendor>' "$(peer a fleet task help)"
expect_shape "an agent pin is accepted and still ranks, rather than erroring" \
  '^$|excluded:' "$(peer a fleet task run --agent claude --plan -- true)"
# A machine pin naming nothing in the fleet plans nothing and still exits 0.
# The panel must therefore treat an empty plan as "ineligible" rather than
# offering to send: FleetControl.fleetDispatch refuses before the Send button.
out=$(peer a fleet task run --machine no-such-mac --plan -- true); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then
  echo "ok an unsatisfiable machine pin plans nothing (and exits 0)"
else echo "FAIL unsatisfiable pin — rc=$rc out: $out"; fail=$((fail+1)); fi
if grep -q 'plan.status == 0, !plan.output.isEmpty' tray/FleetControl.swift; then
  echo "ok the panel refuses an empty plan instead of offering Send"
else echo "FAIL fleetDispatch would offer Send on an empty plan"; fail=$((fail+1)); fi

# The announce-once gate is tested compiled (see tests/native), which only
# means anything while FleetControl actually delegates to it. These two guard
# the wiring: the seen-set must not drift back into the untested file.
if grep -q 'announcer.adopt(notices)' tray/FleetControl.swift; then
  echo "ok the notifier delegates the announce-once rule to the tested type"
else echo "FAIL announce() decides for itself again — see FleetAnnouncer"; fail=$((fail+1)); fi
if grep -qE 'announcedNotices|firstRead' tray/FleetControl.swift tray/main.swift; then
  echo "FAIL the old empty-set-means-unread gate is back"; fail=$((fail+1))
else echo "ok no untested seen-set is left in the app delegate"; fi

# `fleet task reconcile` re-probes workers and can APPEND notices; the CLI has
# no verb that discards the feed. A button labelled "Clear" promised the
# opposite of what it does, so the label has to name the reconcile.
if grep -q 'Button("Clear")' tray/FleetView.swift; then
  echo "FAIL a button labelled Clear runs reconcile, which never clears"; fail=$((fail+1))
else echo "ok no button promises to clear a feed the CLI cannot clear"; fi
if grep -q 'fleet", "task", "reconcile"' tray/FleetControl.swift    && grep -q 'actions.fleetReconcileTasks()' tray/FleetView.swift; then
  echo "ok the activity feed's button is wired to the reconcile it runs"
else echo "FAIL the activity button is not wired to fleet task reconcile"; fail=$((fail+1)); fi
expect_shape "the CLI documents the reconcile the button runs" 'reconcile' "$(peer a fleet task help)"

# Packaging: the panel shells out to the CLI, and the CLI is only whole if its
# fleet halves ship beside it. install.sh ditto's this bundle as a unit, so
# this one list is what reaches /Applications.
for f in agents fleet.sh fleet-sync.sh fleet-exec.sh; do
  if grep -q "\.\./$f " tray/build.sh; then echo "ok the app bundle carries $f"
  else echo "FAIL tray/build.sh does not copy $f into Resources"; fail=$((fail+1)); fi
done

# Naming the files is not the same as shipping a working CLI: the panel runs
# Resources/agents with nothing else of the repo on disk. Rebuild that flat
# layout from build.sh's own copy list (so the check follows the list rather
# than a second copy of it) and drive the real CLI out of it.
res=$work/Resources; mkdir -p "$res"
copied=$(sed -n 's|^cp \(\.\./.*\) "$app/Contents/Resources/"$|\1|p' tray/build.sh | tr ' ' '\n' | sed 's|^\.\./||')
if [ -z "$copied" ]; then
  echo "FAIL could not read build.sh's Resources copy list"; fail=$((fail+1))
else
  for f in $copied; do [ -e "$f" ] && cp "$f" "$res/"; done
  chmod +x "$res"/*.sh "$res/agents" 2>/dev/null
  mkdir -p "$work/pkg"
  pkg() { HOME=$work/pkg N2_FLEET_AUTHORIZED_KEYS=$work/pkg/ak sh "$res/agents" "$@" 2>&1; }
  if pkg fleet init --machine packaged >/dev/null 2>&1 && \
     printf '%s' "$(pkg fleet status --no-probe)" | grep -q '^self	packaged	SHA256:'; then
    echo "ok the bundled Resources list alone is a working fleet CLI"
  else echo "FAIL Resources copy list is incomplete — fleet init failed outside the repo"; fail=$((fail+1)); fi
  expect_shape "the bundled CLI documents both pins the panel offers" \
    '\-\-agent <vendor>' "$(pkg fleet task help)"
  expect_shape "the bundled CLI exposes explicit output distribution" \
    'fleet task distribute' "$(pkg fleet task help)"
fi

# 2. The parsers themselves, against those bytes.
# Swift only allows top-level statements in a file called main.swift, so the
# checks are compiled under that name rather than kept under it in the tree.
cp tests/native/fleet-model-checks.swift "$work/main.swift"
swiftc -o "$work/checks" tray/FleetModel.swift "$work/main.swift" 2>"$work/err" || {
  echo "FAIL: parser checks did not compile"; cat "$work/err"; exit 1; }
"$work/checks" > "$work/out" || fail=$((fail+1))
cat "$work/out"
grep -q '^ALL PASS$' "$work/out" || fail=$((fail+1))

[ "$fail" = 0 ] && echo "native-ui: all checks passed" || echo "native-ui: $fail failed"
exit $((fail == 0 ? 0 : 1))
