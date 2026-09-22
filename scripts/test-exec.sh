#!/bin/sh
# test-exec.sh — dispatch, workspace handoff, task lifecycle, notifications.
#
# Same shape as test-fleet.sh and test-sync.sh: every peer is a real `agents`
# process with its own HOME, its own identity key and its own roster, talking
# over the `exec` carrier. Nothing here touches the user's real fleet; every
# task is a shell command written by this file into an isolated fixture.
set -u
repo=${N2_EXEC_REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
# Fast transport-failure regressions run before the process integration suite.
sh "$repo/scripts/test-exec-delivery.sh" || exit 1
sh "$repo/scripts/test-exec-prepare.sh" || exit 1
sh "$repo/scripts/test-exec-preferences.sh" || exit 1
sh "$repo/scripts/test-exec-prompt.sh" || exit 1
base=${N2_EXEC_BASE:-$(mktemp -d "${TMPDIR:-/tmp}/n2exec-test.XXXXXX")}
mkdir -p "$base"
pass=0; fail=0
# A completed task announces asynchronously and a peer whose HOME was destroyed
# mid-suite keeps dialling its roster for a moment afterwards, so the fixture
# can be written AFTER a removal that itself reported success.
cleanup() {
  [ -n "${N2_EXEC_KEEP:-}" ] && return 0
  # Removing once and testing [ -d ] reports success while state is quietly
  # recreated: a straggler that outlives the first removal writes its journal
  # into a path rm has already descended past. Remove repeatedly instead, and
  # only claim success once the tree has stayed gone across a quiet window long
  # enough for an in-flight writer to have landed. If churn outlasts the
  # window, say so — never report a clean teardown that did not happen.
  cl_try=0 cl_quiet=0
  while [ "$cl_try" -lt 40 ]; do
    if [ -d "$base" ]; then
      cl_quiet=0
      chmod -R u+w "$base" 2>/dev/null
      rm -rf "$base" 2>/dev/null
    else
      cl_quiet=$((cl_quiet+1))
      [ "$cl_quiet" -ge 6 ] && return 0      # ~3s with nothing recreated
    fi
    cl_try=$((cl_try+1))
    sleep 0.5
  done
  rm -rf "$base" 2>/dev/null
  if [ -d "$base" ]; then
    printf 'note: fixture not fully removed, writers still active: %s\n' "$base" >&2
  else
    printf 'note: fixture removed only after repeated recreation: %s\n' "$base" >&2
  fi
  return 0
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT

ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ case $3 in *"$2"*) ok "$1" ;; *) bad "$1" "want '$2' in '$3'" ;; esac; }
refute(){ case $3 in *"$2"*) bad "$1" "did not want '$2' in '$3'" ;; *) ok "$1" ;; esac; }
denied(){ if [ "$3" = 0 ]; then bad "$1" "succeeded but must be refused: $2"; else ok "$1"; fi; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want '$2', got '$3'"; fi; }
# N2_FLEET_NOTIFY is the seam the native banner goes through: a command, run
# with the event in the environment. Pointing it at a per-peer log is how a
# headless test observes desktop delivery without a desktop session.
peer() { h=$1; shift; env HOME="$base/$h" N2_FLEET_AGENTS="$repo/agents" \
           N2_FLEET_NOTIFY="printf '%s\t%s\n' \"\$N2_NOTIFY_KIND\" \"\$N2_NOTIFY_TASK\" >> $base/$h/banner.log" \
           "$repo/agents" "$@"; }
t0=$(date +%s)
sections=$(grep -c '^mark "' "$0")
tally() { printf '\n%s passed, %s failed%s\n' "$pass" "$fail" "${1:-}"; [ "$fail" -eq 0 ]; }
mark() {
  mark_n=${1%%.*}
  if [ -n "${N2_EXEC_STOP_AFTER:-}" ] && [ "$mark_n" -gt "$N2_EXEC_STOP_AFTER" ] 2>/dev/null; then
    tally " (sections 1-$N2_EXEC_STOP_AFTER of $sections; stopped by N2_EXEC_STOP_AFTER)"; exit $?
  fi
  printf '# --- %s  [t+%ss]\n' "$1" "$(( $(date +%s) - t0 ))"
}
# A dispatched task runs detached on the worker, so the dispatcher learns the
# outcome from the fan-out event rather than from the dispatch call. Wait for a
# terminal state instead of sleeping a guessed interval.
await_state() {  # <peer> <id> <state> [secs]
  as_end=$(( $(date +%s) + ${4:-25} ))
  while [ "$(date +%s)" -lt "$as_end" ]; do
    as_s=$(peer "$1" fleet task show "$2" 2>/dev/null | awk -F'\t' '$1=="state"{print $2}')
    [ "$as_s" = "$3" ] && { echo "$as_s"; return 0; }
    case $as_s in failed|completed) echo "$as_s"; return 1 ;; esac
    sleep 1
  done
  echo "${as_s:-<none>}"; return 1
}

for h in alpha beta gamma; do mkdir -p "$base/$h"; done
A=$(peer alpha fleet init --machine alpha | awk '{print $2}')
B=$(peer beta  fleet init --machine beta  | awk '{print $2}')
G=$(peer gamma fleet init --machine gamma | awk '{print $2}')
peer beta  fleet pair --home "$base/alpha" --code "$(peer alpha fleet invite --peer "$B" 2>/dev/null)" >/dev/null 2>&1
peer gamma fleet pair --home "$base/alpha" --code "$(peer alpha fleet invite --peer "$G" 2>/dev/null)" >/dev/null 2>&1
peer gamma fleet pair --home "$base/beta"  --code "$(peer beta  fleet invite --peer "$G" 2>/dev/null)" >/dev/null 2>&1

# A dirty working tree: staged, unstaged, untracked and deleted, all at once.
ws=$base/ws; mkdir -p "$ws"
( cd "$ws" && git init -q . && git config user.email t@t && git config user.name t
  printf 'committed\n' > kept.txt
  printf 'original\n'  > edited.txt
  printf 'doomed\n'    > removed.txt
  git add . >/dev/null 2>&1 && git commit -qm base >/dev/null 2>&1
  printf 'staged change\n' > edited.txt && git add edited.txt >/dev/null 2>&1
  printf 'then unstaged\n' >> edited.txt
  rm removed.txt
  printf 'never committed\n' > untracked.txt ) >/dev/null 2>&1
ctx=$base/context.md
printf 'decision: reuse the existing carrier\nnext: assert the archive contents\n' > "$ctx"

# --- 1. eligibility is a filter that actually refuses ----------------------
mark "1. eligibility refuses rather than guessing"
out=$(peer alpha fleet task run --workspace "$ws" 'echo hi' 2>&1); rc=$?
denied "unprovable agent auth does not silently dispatch" "$out" "$rc"
check  "the refusal names the reason"  "no eligible machine" "$out"
check  "the refusal is per-candidate"  "auth" "$out"

# --- 2. the plan is inspectable and honest about assumptions ---------------
mark "2. --plan ranks candidates and names exclusions"
out=$(peer alpha fleet task run --plan --allow-unknown-auth --workspace "$ws" 'echo hi' 2>&1)
check "the plan has a ranked header"        "rank" "$out"
check "the plan breaks the estimate down"   "transfer" "$out"
check "the plan marks assumed components"   "assumed" "$out"
check "the plan names what it excluded"     "excluded:" "$out"
refute "--plan dispatches nothing"          "dispatched" "$(peer alpha fleet task list 2>&1)"

# --- 3. pinning: machine, agent, and both ----------------------------------
mark "3. pins are honoured"
out=$(peer alpha fleet task run --plan --allow-unknown-auth --machine beta 'echo hi' 2>&1)
check  "a machine pin keeps the pinned machine"   "beta" "$out"
refute "a machine pin drops the others"           "gamma" "$out"
out=$(peer alpha fleet task run --plan --allow-unknown-auth --agent cursor 'echo hi' 2>&1)
check  "an agent pin keeps the pinned agent"      "cursor" "$out"
refute "an agent pin drops the others"            "opencode" "$out"
out=$(peer alpha fleet task run --plan --allow-unknown-auth --machine gamma --agent cursor 'echo hi' 2>&1)
check  "both pins keep the one combination"       "gamma" "$out"
refute "both pins drop the other machine"         "beta" "$out"
out=$(peer alpha fleet task run --allow-unknown-auth --machine nosuchbox 'echo hi' 2>&1); rc=$?
denied "a pin to an unknown machine is refused, not ignored" "$out" "$rc"

# --- 4. the dirty workspace crosses the wire and the task runs -------------
mark "4. dispatch carries the dirty working tree and the context"
out=$(peer alpha fleet task run --machine beta --agent cursor --allow-unknown-auth \
        --workspace "$ws" --context "$ctx" --label handoff \
        'cat untracked.txt > result.txt; cat edited.txt >> result.txt; ls removed.txt 2>&1 | tail -1 > gone.txt; echo ran' 2>&1); rc=$?
same "the dispatch reports success" 0 "$rc"
T1=$(printf '%s' "$out" | cut -f1)
check "the dispatch names the machine it chose" "beta" "$out"
check "the dispatch reports its estimate"       "assumed=" "$out"
st=$(await_state alpha "$T1" completed); same "the task completes" completed "$st"
wd=$base/beta/.n2-agents/fleet/tasks/work/$T1
got=$(cat "$wd/workspace/result.txt" 2>/dev/null)
check "the untracked file arrived and was read"  "never committed" "$got"
check "the unstaged edit arrived, not the commit" "then unstaged" "$got"
same  "a deleted file is deleted at the destination too" "" "$(cat "$wd/workspace/removed.txt" 2>/dev/null)"
check "the committed file is still there"        "committed" "$(cat "$wd/workspace/kept.txt" 2>/dev/null)"
check "the context travelled with the task"      "reuse the existing carrier" "$(cat "$wd/spec/context" 2>/dev/null)"
refute "the source workspace is not modified by the dispatch" "result.txt" "$(ls "$ws")"

# --- 5. completion fans out to the fleet, in app and on the desktop --------
mark "5. completion notifications reach every online peer"
n=$(peer alpha fleet task notices 2>&1)
check "the dispatcher's feed records the completion" "completed" "$n"
check "the feed names the task"                      "$T1" "$n"
check "the feed names the machine that ran it"       "beta" "$n"
# The banner seam fired. Note honestly what this does and does not show: the
# `exec` carrier runs the receiving peer as a child of the calling process, so
# it inherits the CALLER's N2_FLEET_NOTIFY and every banner in this fixture
# lands in one log. That proves the native-notification path is reached for the
# completion; it does not attribute the banner to a receiver. Per-receiver
# delivery is proven instead by each peer's own notices feed, asserted above
# and below against separate HOMEs.
bn=$(cat "$base"/*/banner.log 2>/dev/null)
check "the native banner path fired for the completion" "completed" "$bn"
check "the banner carries the task id"                  "$T1" "$bn"
check "an uninvolved online peer is told too"        "$T1" "$(peer gamma fleet task notices 2>&1)"

# --- 6. outputs stay where the task ran until asked for --------------------
mark "6. outputs never move on their own"
refute "nothing was copied back automatically" "result.txt" "$(ls "$base/alpha" 2>&1)"
peer alpha fleet task fetch "$T1" "$base/alpha/got" >/dev/null 2>&1
check "an explicit fetch returns the output"  "ran" "$(cat "$base/alpha/got/out/stdout" 2>/dev/null)"
out=$(peer gamma fleet task fetch "$T1" "$base/gamma/got" 2>&1); rc=$?
denied "a peer that did not dispatch the task cannot fetch it" "$out" "$rc"

# --- 7. distribution is explicit, targeted and non-destructive -------------
mark "7. distribution needs an explicit target"
src=$base/dist; mkdir -p "$src"; printf 'the utility\n' > "$src/tool.sh"
mkdir -p "$base/gamma/.n2-agents/fleet/tasks/inbox/unrelated"
printf 'keep me\n' > "$base/gamma/.n2-agents/fleet/tasks/inbox/unrelated/mine.txt"
out=$(peer alpha fleet task distribute "$src" --name util 2>&1); rc=$?
denied "distribution without a target is refused" "$out" "$rc"
peer alpha fleet task distribute "$src" --name util --machine beta >/dev/null 2>&1
check  "the named machine received it" "the utility" \
       "$(find "$base/beta" -path '*inbox/util*' -name tool.sh -exec cat {} \; 2>/dev/null)"
refute "an untargeted machine did not"  "the utility" \
       "$(find "$base/gamma" -path '*inbox/util*' -name tool.sh -exec cat {} \; 2>/dev/null)"
peer alpha fleet task distribute "$src" --name util --all >/dev/null 2>&1
check "--all reaches the rest of the fleet" "the utility" \
      "$(find "$base/gamma" -path '*inbox/util*' -name tool.sh -exec cat {} \; 2>/dev/null)"
check "unrelated destination content survives" "keep me" \
      "$(cat "$base/gamma/.n2-agents/fleet/tasks/inbox/unrelated/mine.txt" 2>/dev/null)"
out=$(peer alpha fleet task distribute "$src" --name ../escape --machine beta 2>&1); rc=$?
denied "a traversing distribution name is refused" "$out" "$rc"

# --- 8. a disconnected worker is reported, never retried behind the user ---
mark "8. an unreachable worker waits for the user"
T2=$(peer alpha fleet task run --machine gamma --agent cursor --allow-unknown-auth \
       --label slowjob 'sleep 6; echo finished-offline > done.txt' 2>/dev/null | cut -f1)
# Cut the LINK, not the machine. Moving the worker's HOME aside also moves the
# running worker's state and the still-live process simply recreates the
# directory, so the "reconnect" would rejoin a different, empty machine. The
# honest simulation is the one the operator actually meets: gamma keeps
# running its copy, and alpha can no longer dial it. The exec carrier dials
# the `home` recorded in the CALLER's peer record, so that file is the wire.
gh=$(grep -rl '^machine=gamma$' "$base/alpha/.n2-agents/fleet/peers" 2>/dev/null | head -1)
[ -n "$gh" ] || { echo "FAIL section 8 setup: no peer record for gamma under alpha"; fail=$((fail+1)); }
cut_link() {  # <meta> <home>  — rewrite only the home= line, leave the rest intact
  awk -v h="$2" -F= '$1=="home"{print "home=" h; next} {print}' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
cut_link "$gh" "$base/gamma.unreachable"
grep -q "^home=$base/gamma.unreachable\$" "$gh" || { echo "FAIL section 8 setup: home= not rewritten"; fail=$((fail+1)); }
before=$(peer alpha fleet task list 2>&1 | wc -l | tr -d ' ')
out=$(peer alpha fleet task reconcile "$T2" 2>&1)
check "reconcile reports the worker unreachable" "unreachable" "$out"
refute "reconcile does not dispatch anything"    "dispatched to" "$out"
same  "no second task was created"               "$before" "$(peer alpha fleet task list 2>&1 | wc -l | tr -d ' ')"
check "the disconnection is notified"            "disconnected" "$(peer alpha fleet task notices 2>&1)"
# The worker keeps running its own copy while unreachable.
sleep 6
cut_link "$gh" "$base/gamma"          # the link comes back; the worker never left
out=$(peer alpha fleet task reconcile "$T2" 2>&1)
check "reconnect reconciles the task that finished offline" "completed" \
      "$(peer alpha fleet task show "$T2" 2>&1 | awk -F'\t' '$1=="state"{print $2}')"
check "the work it did offline is intact" "finished-offline" \
      "$(find "$base/gamma" -name done.txt -exec cat {} \; 2>/dev/null)"
check "the worker itself recorded the completion" "completed" \
      "$(peer gamma fleet task show "$T2" 2>&1 | awk -F'\t' '$1=="state"{print $2}')"

# --- 9. a retry is explicit and is a different task ------------------------
mark "9. retry is a new task, cross-linked to the original"
T3=$(peer alpha fleet task retry "$T2" --machine beta --agent cursor --allow-unknown-auth 2>/dev/null | cut -f1)
if [ -n "$T3" ] && [ "$T3" != "$T2" ]; then ok "the retry has its own identity"; else bad "the retry has its own identity" "got '$T3' vs '$T2'"; fi
check "the retry records what it retried"   "$T2" "$(peer alpha fleet task show "$T3" 2>&1)"
check "the original records its retry"      "$T3" "$(peer alpha fleet task show "$T2" 2>&1)"
check "the original keeps its own outcome"  "completed" \
      "$(peer alpha fleet task show "$T2" 2>&1 | awk -F'\t' '$1=="state"{print $2}')"

# --- 10. no required hub: a survivor dispatches without the originator -----
# This sits ahead of the machine-loss section deliberately: that section
# destroys alpha, and the preference here is expressed on alpha. Run after it
# and every assertion fails on "no fleet identity yet" rather than on the
# behaviour under test.
mark "10. the agent preference replicates and can be excepted"
same "a fleet with no expressed preference restricts nothing" all "$(peer alpha fleet task preferences show)"
peer alpha fleet task preferences set claude >/dev/null 2>&1
same "the preference is set where it was expressed" claude "$(peer alpha fleet task preferences show)"
same "it has not appeared on the other machine yet" all "$(peer beta fleet task preferences show)"
check "alpha advertises the preference address" 'tools|-|-|agents.allowed' \
  "$(peer alpha fleet sync scope 2>/dev/null)"
peer beta fleet sync now --peer "$A" >/dev/null 2>&1
same "it reached the other machine through sync" claude "$(peer beta fleet task preferences show)"
# The exception is the documented way to hold a machine out, and it is a
# statement about THIS machine only: gamma opting out must not disturb beta.
peer gamma fleet sync except add tools - - agents.allowed >/dev/null 2>&1
peer gamma fleet sync now --peer "$A" >/dev/null 2>&1
same "an excepted machine keeps its own policy" all "$(peer gamma fleet task preferences show)"
refute "the excepted machine does not advertise it either" 'agents.allowed' \
  "$(peer gamma fleet sync scope 2>/dev/null)"
same "the exception did not disturb the machine that accepted it" claude "$(peer beta fleet task preferences show)"
# Withdrawing the exception is not a back door around the conflict rule; it is
# enough here that the resource becomes addressable again.
peer gamma fleet sync except rm 1 >/dev/null 2>&1
peer gamma fleet sync now --peer "$A" >/dev/null 2>&1
check "withdrawing the exception restores a decision about it" 'claude' \
  "$(peer gamma fleet task preferences show; peer gamma fleet sync conflicts 2>/dev/null)"
# Every section below dispatches to `cursor`. The preference just expressed is
# a real fleet resource now, not a machine-local note, so leaving it at
# `claude` makes the remaining sections fail on eligibility instead of on the
# behaviour under test. Reset it on the machines that dispatch from here on;
# alpha is destroyed next, so nothing re-propagates it.
peer beta fleet task preferences reset >/dev/null 2>&1
peer gamma fleet task preferences reset >/dev/null 2>&1
same "a reset restores an unrestricted dispatcher" all "$(peer beta fleet task preferences show)"

mark "11. dispatch survives the loss of the originating machine"
chmod -R u+w "$base/alpha" 2>/dev/null; rm -rf "$base/alpha"
out=$(peer gamma fleet task run --machine beta --agent cursor --allow-unknown-auth \
        --label survivor 'echo still-here' 2>&1); rc=$?
same "a survivor still dispatches" 0 "$rc"
T4=$(printf '%s' "$out" | cut -f1)
same "the survivor's task completes" completed "$(await_state gamma "$T4" completed)"

# --- 11. the deferral rule reads live task state, not a guess --------------
# The `--disruptive` hold-off is only real if the worker's liveness record
# names a process that is actually alive. It did not: exec_run_local is
# backgrounded, `$$` is not re-set in a subshell, so the record named the
# request handler, which had already exited. sync_tasks_reap read a dead
# owner, filed the record stale, and the update applied through live work.
mark "12. a running task defers a disruptive managed update, and releases it"
peer gamma fleet tools add slowtool --version 2.0 \
  --check 'cat "$HOME/slowtool.v" 2>/dev/null' \
  --install 'printf 2.0 > "$HOME/slowtool.v"' --disruptive >/dev/null 2>&1
same "the tool is designated on the worker" 2.0 \
  "$(peer gamma fleet tools list 2>/dev/null | awk -F'|' '$1=="slowtool"{print $2}')"
out=$(peer beta fleet task run --machine gamma --agent cursor --allow-unknown-auth \
        --label slowwork 'sleep 6; echo done' 2>&1); rc=$?
same "the long task dispatches" 0 "$rc"
T5=$(printf '%s' "$out" | cut -f1)
# Wait for the worker to actually be running, not merely accepted.
w=$(( $(date +%s) + 15 ))
while [ "$(date +%s)" -lt "$w" ]; do
  [ "$(peer gamma fleet task show "$T5" 2>/dev/null | awk -F'\t' '$1=="state"{print $2}')" = running ] && break
  sleep 1
done
same "the worker reports the task running" running \
  "$(peer gamma fleet task show "$T5" 2>/dev/null | awk -F'\t' '$1=="state"{print $2}')"
# This is the assertion the old code failed: the count comes from
# sync_tasks_active, which reaps any record whose owner pid is dead.
busy=$(peer gamma fleet tools install slowtool 2>&1)
check "the disruptive update is deferred while the task runs" deferred "$busy"
refute "the installer did not run during live work" 2.0 \
  "$(cat "$base/gamma/slowtool.v" 2>/dev/null)"
check "the deferred list names it" slowtool "$(peer gamma fleet tools deferred 2>&1)"
# And the hold-off is not permanent: once the work ends the record is gone.
same "the task completes" completed "$(await_state gamma "$T5" completed 30)"
peer gamma fleet tools apply >/dev/null 2>&1
same "the deferred update applies once the work is done" 2.0 \
  "$(cat "$base/gamma/slowtool.v" 2>/dev/null)"

# --- 12. requirements are a hard filter, evaluated before any scoring -------
# Section 10 destroyed alpha, so these last two sections dispatch from beta and
# need two candidates of their own: two more isolated peers, enrolled the same
# way as the rest.
for h in delta epsilon; do mkdir -p "$base/$h"; done
D=$(peer delta   fleet init --machine delta   | awk '{print $2}')
E=$(peer epsilon fleet init --machine epsilon | awk '{print $2}')
peer delta   fleet pair --home "$base/beta" --code "$(peer beta fleet invite --peer "$D" 2>/dev/null)" >/dev/null 2>&1
peer epsilon fleet pair --home "$base/beta" --code "$(peer beta fleet invite --peer "$E" 2>/dev/null)" >/dev/null 2>&1
# The dispatch criterion names "capability exclusions", and the whole
# requirement branch of exec_plan had no coverage: a tool nobody can account
# for must remove the machine from the ranking entirely, while a tool that is
# missing but MANAGED must cost prepare seconds instead of eligibility.
mark "13. a requirement excludes a machine it cannot account for"
out=$(peer beta fleet task run --plan --allow-unknown-auth --requires n2-no-such-tool 'echo hi' 2>&1)
check  "an unaccountable tool names the exclusion" "missing-requirement(n2-no-such-tool)" "$out"
refute "and leaves nothing ranked"                 "1	" "$out"
out=$(peer beta fleet task run --allow-unknown-auth --requires n2-no-such-tool 'echo hi' 2>&1); rc=$?
denied "a requirement no machine can meet refuses the dispatch" "$out" "$rc"
# A tool that is simply on PATH satisfies the requirement without being
# managed — the question is whether the work can run there, not whether the
# operator happened to put the tool under fleet management.
out=$(peer beta fleet task run --plan --allow-unknown-auth --requires awk 'echo hi' 2>&1)
check  "a tool on PATH satisfies the requirement" "delta" "$out"
refute "and is never reported missing"            "missing-requirement" "$out"
# Managed-but-absent: still eligible, and the install shows up as prepare time.
peer delta fleet tools add prepkit --version 9.9 \
  --check 'cat "$HOME/prepkit.v" 2>/dev/null' \
  --install 'printf 9.9 > "$HOME/prepkit.v"' >/dev/null 2>&1
out=$(peer beta fleet task run --plan --allow-unknown-auth --machine delta --requires prepkit 'echo hi' 2>&1)
refute "a managed tool that needs installing is not an exclusion" "missing-requirement" "$out"
prep=$(printf '%s\n' "$out" | awk -F'\t' '$1=="1"{print $9}')
case ${prep:-} in
  ''|0|0:*) bad "the pending install is priced into the estimate" "prepare column was '${prep:-<none>}'" ;;
  *) ok "the pending install is priced into the estimate" ;;
esac
refute "planning never runs the installer" "9.9" "$(cat "$base/delta/prepkit.v" 2>/dev/null)"

# --- 13. the ranking is an order, not a list -------------------------------
# Asserting only that the header says "rank" passes on an unsorted plan. Seed
# each peer's own recorded history (the same files exec_stat_add writes) and
# assert the ORDER, then invert the history and assert the order inverts.
mark "14. the ranking follows the estimate, and each input moves it"
st() { mkdir -p "$base/$1/.n2-agents/fleet/tasks/stats"; printf '%s 5\n' "$3" > "$base/$1/.n2-agents/fleet/tasks/stats/$2"; }
top() { printf '%s\n' "$1" | awk -F'\t' '$1=="1"{print $3}'; }
plan() { peer beta fleet task run --plan --allow-unknown-auth --agent cursor "$@" 'echo hi' 2>&1; }
# gamma is in beta's roster too and earned a real (fast) history in section 11,
# so give it a deliberately slow one: the point here is the ORDER between two
# controlled candidates, not a race with a third peer's incidental history.
st gamma vendor.cursor 9000; st gamma bps 1000
st delta vendor.cursor 400; st epsilon vendor.cursor 100
same "the faster agent history ranks first" epsilon "$(top "$(plan)")"
st delta vendor.cursor 100; st epsilon vendor.cursor 400
same "inverting the history inverts the order" delta "$(top "$(plan)")"
# Sample counts describe confidence, not elapsed seconds. Different count
# widths used to concatenate onto the mean and could reverse this ordering.
printf '100 999\n' > "$base/delta/.n2-agents/fleet/tasks/stats/vendor.cursor"
printf '200 1\n' > "$base/epsilon/.n2-agents/fleet/tasks/stats/vendor.cursor"
same "sample count cannot make a faster mean rank slower" delta "$(top "$(plan)")"
# Transfer cost alone decides it: identical execute means, different link speed.
st delta vendor.cursor 100; st epsilon vendor.cursor 100
st delta bps 2000; st epsilon bps 200000000
same "the cheaper transfer wins when execution ties" epsilon "$(top "$(plan --workspace "$ws")")"
st delta bps 200000000; st epsilon bps 2000
same "inverting the link speed inverts the order" delta "$(top "$(plan --workspace "$ws")")"
# Queue depth is deliberately NOT asserted here: with no task running on either
# peer both queues are a known 0, so a "busy loses" assertion at this point
# would pass on an unsorted plan too. Queue pressure against a real running
# worker is exercised in section 11.

# --- 14. the agent preference is a fleet resource, not a machine-local file --
# The dispatcher's allowed-agent list decides eligibility everywhere, so a
# preference expressed on one machine has to reach the others by the ordinary
# replication path — and has to be withholdable by the same per-machine
# exception mechanism as anything else that syncs.

tally
