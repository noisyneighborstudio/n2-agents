#!/bin/sh
# test-sync.sh — shared profile replication, conflicts and managed utilities.
#
# Same shape as test-fleet.sh: every peer is a real `agents` process with its
# own HOME, its own identity key and its own roster, talking over the `exec`
# carrier. Nothing here touches the user's real fleet, and every credential in
# this file is a synthetic string invented for the test.
set -u
repo=${N2_SYNC_REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
# N2_SYNC_START_AT=<n> runs sections <n>..end against a fixture an earlier
# bounded run left behind (N2_SYNC_BASE + N2_SYNC_KEEP). Sections build forward
# on fixture state, so they cannot simply be skipped in place: the run re-execs
# a trimmed copy of this file -- the same preamble, then section <n> onward --
# which is why the preamble above must be re-enterable against existing state.
if [ -n "${N2_SYNC_START_AT:-}" ] && [ -z "${N2_SYNC_TRIMMED:-}" ]; then
  [ -n "${N2_SYNC_BASE:-}" ] || { echo "N2_SYNC_START_AT needs N2_SYNC_BASE" >&2; exit 2; }
  if [ ! -f "${N2_SYNC_BASE}/.ids" ]; then
    echo "no fixture at $N2_SYNC_BASE: sections build forward, so 1..$((N2_SYNC_START_AT - 1)) must run first." >&2
    echo "  N2_SYNC_BASE=$N2_SYNC_BASE N2_SYNC_KEEP=1 N2_SYNC_STOP_AFTER=$((N2_SYNC_START_AT - 1)) sh $0" >&2
    echo "  N2_SYNC_BASE=$N2_SYNC_BASE N2_SYNC_KEEP=1 N2_SYNC_START_AT=$N2_SYNC_START_AT sh $0" >&2
    exit 2
  fi
  # Sections build forward AND leave their replicated bytes behind, so a
  # fixture that already ran section <n> is not a valid starting point for it:
  # the negative "never reached the peer" assertions would re-find the previous
  # run's bytes and report a bypass that never happened. Refuse loudly rather
  # than emit believable-looking failures.
  _through=$(cat "${N2_SYNC_BASE}/.through" 2>/dev/null || echo '')
  if [ "${_through:-none}" != "$((N2_SYNC_START_AT - 1))" ]; then
    echo "fixture $N2_SYNC_BASE ran through section ${_through:-<unrecorded>}, but START_AT=$N2_SYNC_START_AT needs one stopped after $((N2_SYNC_START_AT - 1))." >&2
    echo "  a fixture cannot re-run a section it already completed; build a fresh prefix:" >&2
    echo "  N2_SYNC_BASE=<new> N2_SYNC_KEEP=1 N2_SYNC_STOP_AFTER=$((N2_SYNC_START_AT - 1)) sh $0" >&2
    exit 2
  fi
  # Peer carrier commands embed absolute HOME paths under the fixture root, so
  # a fixture copied or moved to a new root still drives the ORIGINAL tree: the
  # resumed sections then fail as if replication broke. Refuse instead.
  _fbase=$(cat "${N2_SYNC_BASE}/.base" 2>/dev/null || echo '')
  if [ -n "$_fbase" ] && [ "$_fbase" != "$N2_SYNC_BASE" ]; then
    echo "fixture $N2_SYNC_BASE was built at $_fbase; peers still point there." >&2
    echo "  resume at the original path, or rebuild a prefix at this one." >&2
    exit 2
  fi
  _first=$(grep -n '^# --- 1\.' "$0" | head -1 | cut -d: -f1)
  _from=$(grep -n "^# --- ${N2_SYNC_START_AT}\." "$0" | head -1 | cut -d: -f1)
  [ -n "$_from" ] || { echo "no section $N2_SYNC_START_AT in $0" >&2; exit 2; }
  _trim=$(mktemp "${TMPDIR:-/tmp}/n2sync-trim.XXXXXX")
  { sed -n "1,$((_first-1))p" "$0"; sed -n "${_from},\$p" "$0"; } > "$_trim"
  N2_SYNC_TRIMMED=1 N2_SYNC_REPO="$repo" N2_SYNC_SECTIONS=$(grep -c '^mark "' "$0") \
    sh "$_trim"; _rc=$?
  rm -f "$_trim"; exit $_rc
fi
# N2_SYNC_BASE names the fixture root instead of letting mktemp pick one, so a
# bounded prefix run can be resumed later against the state it left behind.
if [ -n "${N2_SYNC_BASE:-}" ]; then
  base=$N2_SYNC_BASE; mkdir -p "$base"
else
  base=$(mktemp -d "${TMPDIR:-/tmp}/n2sync-test.XXXXXX")
fi
pass=0; fail=0
cleanup() { [ -n "${N2_SYNC_KEEP:-}" ] || { chmod -R u+w "$base" 2>/dev/null; rm -rf "$base"; }; }
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT

ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ case $3 in *"$2"*) ok "$1" ;; *) bad "$1" "want '$2' in '$3'" ;; esac; }
refute(){ case $3 in *"$2"*) bad "$1" "did not want '$2' in '$3'" ;; *) ok "$1" ;; esac; }
denied(){ if [ "$3" = 0 ]; then bad "$1" "succeeded but must be refused: $2"; else ok "$1"; fi; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want '$2', got '$3'"; fi; }
peer() { h=$1; shift; env HOME="$base/$h" N2_FLEET_AGENTS="$repo/agents" "$repo/agents" "$@"; }
t0=$(date +%s)
# counted from the file so the tally cannot drift when a section is added
sections=${N2_SYNC_SECTIONS:-$(grep -c '^mark "' "$0")}
# The tally, printed once. `mark` reuses it for a bounded run so that a partial
# pass is still an honest, self-describing artifact rather than a truncated log.
tally() {
  printf '\n%s passed, %s failed%s\n' "$pass" "$fail" "${1:-}"
  [ "$fail" -eq 0 ]
}
# N2_SYNC_STOP_AFTER=<n> stops cleanly at the end of section <n> and prints the
# tally for sections 1..<n>. Sections only ever build forward on fixture state,
# so a prefix is a valid run -- it is a shorter suite, not a sampled one.
mark() {
  mark_n=${1%%.*}
  if [ -n "${N2_SYNC_STOP_AFTER:-}" ] \
     && [ "$mark_n" -gt "$N2_SYNC_STOP_AFTER" ] 2>/dev/null; then
    echo "$N2_SYNC_STOP_AFTER" > "$base/.through"
    echo "$base" > "$base/.base"
    tally " (sections ${N2_SYNC_START_AT:-1}-$N2_SYNC_STOP_AFTER of $sections; stopped by N2_SYNC_STOP_AFTER)"
    exit $?
  fi
  printf '# --- %s  [t+%ss]\n' "$1" "$(( $(date +%s) - t0 ))"
}

# slot for (peer, profile, vendor) — the same layout `agents` uses
slot() { echo "$base/$1/.n2-agents/$2/$3"; }
put()  { mkdir -p "$(dirname "$2")"; printf '%s' "$3" > "$2"; }

# A resumed run inherits the fleet the first run built; only a fresh fixture
# enrolls one. The ids are recorded rather than re-derived so that a resumed
# section compares against the same identities the earlier sections used.
if [ -f "$base/.ids" ]; then
  . "$base/.ids"
else
  for h in alpha beta gamma; do mkdir -p "$base/$h"; done
  A=$(peer alpha fleet init --machine alpha | awk '{print $2}')
  B=$(peer beta  fleet init --machine beta  | awk '{print $2}')
  G=$(peer gamma fleet init --machine gamma | awk '{print $2}')
  peer beta fleet pair --home "$base/alpha" \
    --code "$(peer alpha fleet invite --peer "$B" 2>/dev/null)" >/dev/null 2>&1
  peer gamma fleet pair --home "$base/alpha" \
    --code "$(peer alpha fleet invite --peer "$G" 2>/dev/null)" >/dev/null 2>&1
  printf 'A=%s\nB=%s\nG=%s\n' "$A" "$B" "$G" > "$base/.ids"
fi

# --- shared fixture state, re-entered on every run -------------------------
# A resumed run replays this preamble and then the named section onward, so a
# variable a later section reads must be defined here, not in the section that
# happened to introduce it. Everything below is a pure function of $base and
# idempotent, so re-entering it costs nothing and changes no section's meaning.

# alpha's claude slot, read by the symlink sections.
sa=$(slot alpha Work claude)

# An invented credential. It is not a real key and reaches no real provider;
# it exists so the redaction assertions have something to look for.
SECRET='sk-ant-synthetic-DO-NOT-USE-0000'

# The managed-tool fixture: a version file plus a controlled installer.
# Nothing here reaches the network or the real machine.
T="$base/tools"; mkdir -p "$T"
cat > "$T/install.sh" <<'EOS'
#!/bin/sh
# $1 = tool name, $2 = version to write, $3 = optional "lie" or "break"
case ${3:-} in
  break) exit 1 ;;
  lie)   printf '%s' "0.0-wrong" > "$1.version"; exit 0 ;;
esac
printf '%s' "$2" > "$1.version"
EOS
chmod +x "$T/install.sh"

# --- 1. scope: an allowlist, not everything under the slot -----------------
mark "1. scope is an allowlist"
put alpha "$(slot alpha Work claude)/skills/demo/SKILL.md" 'skill one'
put alpha "$(slot alpha Work claude)/settings.json" '{"a":1}'
put alpha "$(slot alpha Work claude)/.mcp.json" '{"mcpServers":{}}'
put alpha "$(slot alpha Work claude)/projects/x/session.jsonl" 'transcript line'
put alpha "$(slot alpha Work claude)/history.jsonl" 'history line'
sc=$(peer alpha fleet sync scope)
check  "scope: a skill is in scope"          "skills|Work|claude|skills/demo/SKILL.md" "$sc"
check  "scope: agent settings are in scope"  "settings|Work|claude|settings.json" "$sc"
# The whole `mcp` class is credential material by policy, not by scan: an MCP
# record carries its secrets in `args`, in a `postgresql://user:pass@` URL, in
# a header or in an arbitrarily named `env` entry, so it rides the same
# per-vendor opt-in as `auth` rather than whatever a key-name scan recognises.
refute "scope: mcp config is out of scope without the vendor opt-in" \
       "mcp|Work|claude|.mcp.json" "$sc"
peer alpha fleet sync auth enable claude >/dev/null 2>&1
sc=$(peer alpha fleet sync scope)
check  "scope: mcp config is in scope once the vendor is opted in" \
       "mcp|Work|claude|.mcp.json" "$sc"
peer alpha fleet sync auth disable claude >/dev/null 2>&1
sc=$(peer alpha fleet sync scope)
refute "scope: transcripts are never synced" "projects/x/session.jsonl" "$sc"
refute "scope: history is never synced"      "history.jsonl" "$sc"

# --- 2. a change made on one machine reaches the other ---------------------
mark "2. push from alpha to beta"
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "push: the skill is pushed"    "pushed	skills|Work|claude|skills/demo/SKILL.md" "$out"
check "push: settings are pushed"    "pushed	settings|Work|claude|settings.json" "$out"
same  "push: beta received the skill bytes" "skill one" \
      "$(cat "$(slot beta Work claude)/skills/demo/SKILL.md" 2>/dev/null)"
refute "push: the mcp config is withheld while neither side opted in" \
       "pushed	mcp|Work|claude|.mcp.json" "$out"
if [ -f "$(slot beta Work claude)/.mcp.json" ]; then
  bad "push: beta did not receive the mcp config" "it was replicated with no opt-in"
else ok "push: beta did not receive the mcp config"; fi
# ...and with both vendors opted in it does replicate: withholding is the
# opt-in, not a ban on the class.
peer alpha fleet sync auth enable claude >/dev/null 2>&1
peer beta  fleet sync auth enable claude >/dev/null 2>&1
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "push: opted in on both sides, the mcp config is pushed" \
      "pushed	mcp|Work|claude|.mcp.json" "$out"
same  "push: beta received the mcp config" '{"mcpServers":{}}' \
      "$(cat "$(slot beta Work claude)/.mcp.json" 2>/dev/null)"

# --- 3. a repeated pass is a no-op, not a re-copy --------------------------
mark "3. repeated sync is idempotent"
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
refute "repeat: nothing is pushed again" "pushed	" "$out"
refute "repeat: nothing is pulled"       "pulled	" "$out"
check  "repeat: the resource is a noop"  "noop	skills|Work|claude|skills/demo/SKILL.md" "$out"

# --- 4. any machine can originate: beta edits, alpha follows ---------------
mark "4. change originates on beta"
put beta "$(slot beta Work claude)/settings.json" '{"a":2,"origin":"beta"}'
out=$(peer beta fleet sync now --peer "$A" 2>&1)
check "origin: beta pushes its edit" "pushed	settings|Work|claude|settings.json" "$out"
same  "origin: alpha has beta's bytes" '{"a":2,"origin":"beta"}' \
      "$(cat "$(slot alpha Work claude)/settings.json" 2>/dev/null)"

# --- 5. a deletion replicates as a deletion --------------------------------
mark "5. deletion replicates"
rm -f "$(slot beta Work claude)/.mcp.json"
out=$(peer beta fleet sync now --peer "$A" 2>&1)
check "delete: the tombstone is pushed" "pushed	mcp|Work|claude|.mcp.json" "$out"
if [ -f "$(slot alpha Work claude)/.mcp.json" ]; then
  bad "delete: alpha removed the file"; else ok "delete: alpha removed the file"; fi
# The class opt-in was for sections 2-5 only; the rest of the suite reasons
# about alpha and beta as machines that never opted claude in.
peer alpha fleet sync auth disable claude >/dev/null 2>&1
peer beta  fleet sync auth disable claude >/dev/null 2>&1

# --- 6. an exception keeps this machine deliberately different -------------
mark "6. machine-local exception"
peer gamma fleet sync except add settings Work claude 'settings.json' >/dev/null
put alpha "$(slot alpha Work claude)/settings.json" '{"a":3}'
out=$(peer alpha fleet sync now --peer "$G" 2>&1)
check "except: gamma still takes the skill" "pushed	skills|Work|claude|skills/demo/SKILL.md" "$out"
if [ -f "$(slot gamma Work claude)/settings.json" ]; then
  bad "except: gamma did not receive the excepted file" "file present"; else
  ok  "except: gamma did not receive the excepted file"; fi
same "except: alpha's own copy is untouched" '{"a":3}' \
     "$(cat "$(slot alpha Work claude)/settings.json")"
# the exception is a statement about gamma only — it never travels
refute "except: the exception is machine-local" "settings|Work|claude" \
       "$(peer alpha fleet sync except list 2>/dev/null)"

# --- 7. divergent offline edits conflict and are preserved -----------------
mark "7. conflicting offline edits"
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
put alpha "$(slot alpha Work claude)/settings.json" '{"edited":"on alpha"}'
put beta  "$(slot beta  Work claude)/settings.json" '{"edited":"on beta"}'
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "conflict: the pass reports a conflict" "conflict	settings|Work|claude|settings.json" "$out"
same  "conflict: alpha's bytes are untouched" '{"edited":"on alpha"}' \
      "$(cat "$(slot alpha Work claude)/settings.json")"
same  "conflict: beta's bytes are untouched"  '{"edited":"on beta"}' \
      "$(cat "$(slot beta Work claude)/settings.json")"
cid=$(peer alpha fleet sync conflicts | awk '{print $1}' | head -1)
[ -n "$cid" ] && ok "conflict: it is visible in 'sync conflicts'" ||
  bad "conflict: it is visible in 'sync conflicts'" "no conflict listed"
check "conflict: both candidates are preserved" "remote_bytes=" "$(peer alpha fleet sync show "$cid" 2>&1)"
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "conflict: an unresolved conflict pins the resource" \
      "pinned	settings|Work|claude|settings.json" "$out"

# --- 8. resolution is the operator's, and it propagates --------------------
mark "8. explicit resolution"
# Re-derived rather than inherited from section 7 so this section stands on
# its own under N2_SYNC_START_AT, and so the id is keyed to the resource
# instead of to whatever happens to sort first.
cid=$(peer alpha fleet sync conflicts \
      | awk -F'\t' '$2=="settings|Work|claude|settings.json"{print $1}' | head -1)
out=$(peer alpha fleet sync resolve "$cid" --remote 2>&1)
check "resolve: the choice is recorded" "resolved" "$out"
same  "resolve: alpha now holds beta's bytes" '{"edited":"on beta"}' \
      "$(cat "$(slot alpha Work claude)/settings.json")"
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
refute "resolve: the conflict does not come back" "conflict	settings" "$out"
same   "resolve: no conflicts remain" "" "$(peer alpha fleet sync conflicts)"

# --- 9. deletion versus edit is a conflict, not a silent win ---------------
mark "9. delete versus edit"
put alpha "$(slot alpha Work claude)/skills/demo/SKILL.md" 'edited on alpha'
rm -f "$(slot beta Work claude)/skills/demo/SKILL.md"
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "delete-vs-edit: conflicts" "conflict	skills|Work|claude|skills/demo/SKILL.md" "$out"
same  "delete-vs-edit: the edit is not destroyed" "edited on alpha" \
      "$(cat "$(slot alpha Work claude)/skills/demo/SKILL.md")"
dcid=$(peer alpha fleet sync conflicts | awk '$2 ~ /^skills\|/ {print $1}' | head -1)
check "delete-vs-edit: the remote side is recorded as deleted" "remote=deleted" \
      "$(peer alpha fleet sync show "$dcid" 2>&1)"
peer alpha fleet sync resolve "$dcid" --local >/dev/null 2>&1
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
# The operator has already chosen once, with beta's deletion in front of them:
# the conflict record names beta's exact state (remote=deleted, asserted
# above). Asking beta's operator the same question again is not a second
# safeguard, it is the same answer typed twice -- and with four machines it is
# the same answer typed four times. So the resolution travels: alpha pushes,
# and beta, which has not touched the resource since alpha looked, takes it
# without pinning a mirror-image conflict. A beta edit made *after* alpha
# looked moves beta's live digest off the base alpha declares and the conflict
# stands instead; section 42 proves that half.
check "delete-vs-edit: the resolution is pushed, not re-conflicted" "pushed	skills|Work|claude" "$out"
bcid=$(peer beta fleet sync conflicts | awk '$2 ~ /^skills\|/ {print $1}' | head -1)
[ -z "$bcid" ] && ok "delete-vs-edit: beta is not asked the same question twice" ||
  bad "delete-vs-edit: beta is not asked the same question twice" "beta pinned $bcid"
same "delete-vs-edit: alpha's edit is what beta now holds" "edited on alpha" \
     "$(cat "$(slot beta Work claude)/skills/demo/SKILL.md" 2>/dev/null)"

# --- 10. auth replicates only after an explicit, evidence-based opt-in -----
mark "10. auth opt-in"
put alpha "$(slot alpha Work codex)/auth.json" '{"tokens":{"access":"SYNTHETIC-NOT-A-REAL-TOKEN"},"last_refresh":"1"}'
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
refute "auth: nothing moves before opt-in" "auth|Work|codex" "$out"
if [ -f "$(slot beta Work codex)/auth.json" ]; then
  bad "auth: beta has no credential before opt-in" "file present"; else
  ok  "auth: beta has no credential before opt-in"; fi
check "auth: the matrix reports claude as partial" "partial" "$(peer alpha fleet sync auth list)"
check "auth: the matrix explains the keychain limit" "keychain" "$(peer alpha fleet sync auth list)"
out=$(peer alpha fleet sync auth enable gemini 2>&1); rc=$?
denied "auth: an unsupported provider cannot be opted in" "$out" "$rc"
peer alpha fleet sync auth enable codex >/dev/null 2>&1
peer beta  fleet sync auth enable codex >/dev/null 2>&1
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "auth: opted-in credentials replicate" "pushed	auth|Work|codex|auth.json" "$out"
same  "auth: beta received the synthetic credential" \
      '{"tokens":{"access":"SYNTHETIC-NOT-A-REAL-TOKEN"},"last_refresh":"1"}' \
      "$(cat "$(slot beta Work codex)/auth.json" 2>/dev/null)"
same  "auth: the replicated credential is not group/world readable" "600" \
      "$(stat -f '%OLp' "$(slot beta Work codex)/auth.json" 2>/dev/null || stat -c '%a' "$(slot beta Work codex)/auth.json")"

# --- 11. a credential change (reset) propagates, and conflicts are visible --
mark "11. credential reset and refresh conflict"
put alpha "$(slot alpha Work codex)/auth.json" '{"tokens":{"access":"SYNTHETIC-AFTER-RESET"},"last_refresh":"2"}'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
same "auth: a reset on alpha reaches beta" '{"tokens":{"access":"SYNTHETIC-AFTER-RESET"},"last_refresh":"2"}' \
     "$(cat "$(slot beta Work codex)/auth.json")"
put alpha "$(slot alpha Work codex)/auth.json" '{"tokens":{"access":"SYNTHETIC-ALPHA-REFRESH"},"last_refresh":"3"}'
put beta  "$(slot beta  Work codex)/auth.json" '{"tokens":{"access":"SYNTHETIC-BETA-REFRESH"},"last_refresh":"4"}'
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "auth: independent refreshes conflict rather than clobber" "conflict	auth|Work|codex|auth.json" "$out"
refute "auth: the newer timestamp does not silently win" "pushed	auth|Work|codex" "$out"

# --- 12. secrets never reach the journal or the conflict display ------------
mark "12. redaction"
j=$(cat "$base/alpha/.n2-agents/fleet/events.log" 2>/dev/null)
refute "redact: no synthetic token in the journal" "SYNTHETIC" "$j"
acid=$(peer alpha fleet sync conflicts | awk '$2 ~ /^auth\|/ {print $1}' | head -1)
refute "redact: no synthetic token in the conflict display" "SYNTHETIC" \
       "$(peer alpha fleet sync show "$acid" 2>&1)"
refute "redact: no synthetic token in sync status" "SYNTHETIC" "$(peer alpha fleet sync status 2>&1)"

# --- 13. managed tools: a missing tool installs, a wrong version updates ----
# The "tool" is a controlled fixture: a version file plus an installer script.
# Nothing here reaches the network or the real machine.
mark "13. managed tools install and update"
peer alpha fleet tools add widget --version 1.0 \
  --check "cat $T/widget.version 2>/dev/null" \
  --install "sh $T/install.sh $T/widget 1.0" >/dev/null
check "tools: a missing managed tool reports install" "widget	install" \
      "$(peer alpha fleet tools status)"
check "tools: apply installs it"        "install	widget" "$(peer alpha fleet tools apply)"
same  "tools: the requested version landed" "1.0" "$(cat "$T/widget.version")"
check "tools: a satisfied tool reports ok" "widget	ok" "$(peer alpha fleet tools status)"
check "tools: a repeated apply is a noop"  "ok	widget" "$(peer alpha fleet tools apply)"
peer alpha fleet tools add widget --version 2.0 \
  --check "cat $T/widget.version 2>/dev/null" \
  --install "sh $T/install.sh $T/widget 2.0" >/dev/null
check "tools: a version mismatch reports update" "widget	update" \
      "$(peer alpha fleet tools status)"
check "tools: apply updates it"          "update	widget" "$(peer alpha fleet tools apply)"
same  "tools: the new version landed"    "2.0" "$(cat "$T/widget.version")"

# --- 14. authorization: only designated tools may be installed -------------
mark "14. managed tools authorization"
out=$(peer alpha fleet tools install rogue 2>&1); rc=$?
denied "tools: an unlisted tool is refused" "$out" "$rc"
check  "tools: the refusal names the missing designation" "not fleet-managed" "$out"
if [ -e "$T/rogue.version" ]; then bad "tools: refusal installed nothing" "rogue was installed"
else ok "tools: refusal installed nothing"; fi
out=$(peer alpha fleet tools add naked --version 1 --check "true" 2>&1); rc=$?
denied "tools: a tool with no installer cannot be designated" "$out" "$rc"
refute "tools: the refused tool is not in the manifest" "naked" \
       "$(peer alpha fleet tools list)"
# A record with no check command can never be told apart from `install`: its
# installer would re-run on every tick and a successful install would still
# report `failed`, because the post-install re-check can never reach `ok`.
out=$(peer alpha fleet tools add blind --install "touch $T/blind.marker" 2>&1); rc=$?
denied "tools: a tool with no check command cannot be designated" "$out" "$rc"
check  "tools: the refusal says the check is how the version is read" "--check" "$out"
refute "tools: the uncheckable tool is not in the manifest" "blind" \
       "$(peer alpha fleet tools list)"
if [ -e "$T/blind.marker" ]; then bad "tools: the refused designation installed nothing" "blind ran"
else ok "tools: the refused designation installed nothing"; fi
# The same rule holds for a record that arrives already written — a replicated
# or hand-edited manifest line is refused as invalid, not run unverifiably.
# Five well-formed fields, empty check: the shape `tools add` itself would
# have written before the check became mandatory, so the only thing wrong
# with it is the missing check.
printf 'ghost|||%s|\n' "touch $T/ghost.marker" \
  >> "$base/alpha/.n2-agents/fleet/tools/manifest"
check "tools: an uncheckable manifest line is listed invalid" "invalid|ghost" \
      "$(peer alpha fleet tools list)"
check "tools: its state is invalid, not install" "ghost	invalid" \
      "$(peer alpha fleet tools status)"
check "tools: apply refuses it loudly" "invalid	ghost" "$(peer alpha fleet tools apply)"
out=$(peer alpha fleet tools install ghost 2>&1); rc=$?
denied "tools: naming it explicitly does not run it either" "$out" "$rc"
if [ -e "$T/ghost.marker" ]; then bad "tools: the invalid record installed nothing" "ghost ran"
else ok "tools: the invalid record installed nothing"; fi
peer alpha fleet tools rm ghost >/dev/null 2>&1

# --- 15. active tasks: compatible work applies, disruptive work defers ------
mark "15. managed tools and active tasks"
mkdir -p "$base/alpha/.n2-agents/fleet/tasks/active"
: > "$base/alpha/.n2-agents/fleet/tasks/active/task-1"
peer alpha fleet tools add quicktool --version 1.0 \
  --check "cat $T/quicktool.version 2>/dev/null" \
  --install "sh $T/install.sh $T/quicktool 1.0" >/dev/null
peer alpha fleet tools add bigtool --version 1.0 --disruptive \
  --check "cat $T/bigtool.version 2>/dev/null" \
  --install "sh $T/install.sh $T/bigtool 1.0" >/dev/null
out=$(peer alpha fleet tools apply)
check "tools: a compatible update does not wait for the fleet to go idle" \
      "install	quicktool" "$out"
check "tools: a disruptive update defers while a task runs" "deferred	bigtool" "$out"
check "tools: the deferral names the active task count" "active_tasks=1" "$out"
if [ -e "$T/bigtool.version" ]; then bad "tools: deferral did not install" "bigtool installed anyway"
else ok "tools: deferral did not install"; fi
check "tools: deferred work is listed, not dropped" "bigtool" \
      "$(peer alpha fleet tools deferred)"
rm -f "$base/alpha/.n2-agents/fleet/tasks/active/task-1"
out=$(peer alpha fleet tools apply)
check "tools: the deferred update applies once the task ends" "install	bigtool" "$out"
same  "tools: the deferred tool reached its version" "1.0" "$(cat "$T/bigtool.version")"
same  "tools: nothing is left deferred" "" "$(peer alpha fleet tools deferred)"

# --- 16. installer failures are reported as failures, not successes --------
mark "16. managed tool failure modes"
peer alpha fleet tools add lyingtool --version 9.9 \
  --check "cat $T/lyingtool.version 2>/dev/null" \
  --install "sh $T/install.sh $T/lyingtool 9.9 lie" >/dev/null
check "tools: an installer that exits 0 without the version is a failure" \
      "failed	lyingtool" "$(peer alpha fleet tools apply)"
peer alpha fleet tools add brokentool --version 1.0 \
  --check "cat $T/brokentool.version 2>/dev/null" \
  --install "sh $T/install.sh $T/brokentool 1.0 break" >/dev/null
check "tools: a non-zero installer is a failure" "failed	brokentool" \
      "$(peer alpha fleet tools apply)"
out=$(peer alpha fleet tools install brokentool 2>&1); rc=$?
denied "tools: a single-tool install reports the failure in its exit status" "$out" "$rc"
peer alpha fleet tools rm lyingtool >/dev/null
peer alpha fleet tools rm brokentool >/dev/null
refute "tools: an unmanaged tool leaves the manifest" "lyingtool" \
       "$(peer alpha fleet tools list)"

# --- 17. an adopted profile is a symlink; its contents sync, the link does not
mark "17. adopted profile symlinks"
mkdir -p "$base/gamma/.claude-profiles/Adopted/claude/skills/ad"
printf '%s' 'adopted skill' > "$base/gamma/.claude-profiles/Adopted/claude/skills/ad/SKILL.md"
ln -s "$base/gamma/.claude-profiles/Adopted" "$base/gamma/.n2-agents/Adopted"
out=$(peer alpha fleet sync now --peer "$G" 2>&1)
check "adopted: the contents of an adopted slot replicate" \
      "skills|Adopted|claude|skills/ad/SKILL.md" "$out"
same  "adopted: alpha received the bytes" "adopted skill" \
      "$(cat "$(slot alpha Adopted claude)/skills/ad/SKILL.md" 2>/dev/null)"
if [ -L "$base/alpha/.n2-agents/Adopted" ]; then
  bad "adopted: the link itself is never reproduced" "alpha's profile is a symlink"
else ok "adopted: the link itself is never reproduced"; fi
if [ -L "$base/gamma/.n2-agents/Adopted" ]; then
  ok "adopted: the source link is left intact"
else bad "adopted: the source link is left intact" "gamma's adopted link was replaced"; fi

# --- 18. a symlink escaping a slot never carries outside bytes to a peer ----
mark "18. symlink escape"
mkdir -p "$base/outside"
printf '%s' 'OUTSIDE-SECRET' > "$base/outside/secret.txt"
mkdir -p "$(slot alpha Work claude)/skills/escape"
ln -s "$base/outside/secret.txt" "$(slot alpha Work claude)/skills/escape/SKILL.md"
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
refute "escape: the outside file's bytes never reach the peer" "OUTSIDE-SECRET" \
       "$(cat "$(slot beta Work claude)/skills/escape/SKILL.md" 2>/dev/null)"
same "escape: the original outside file is untouched" "OUTSIDE-SECRET" \
     "$(cat "$base/outside/secret.txt")"

# --- 19. a receiver's exception is not a deletion --------------------------
# The originating machine must keep its own file when a peer declines the
# resource. Silence from a peer used to read as a tombstone.
mark "19. an exception on the receiver never deletes the originator's copy"
put alpha "$(slot alpha Work claude)/skills/keep/SKILL.md" 'keep me'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
same "except-vs-delete: beta has the file before the exception" "keep me" \
     "$(cat "$(slot beta Work claude)/skills/keep/SKILL.md" 2>/dev/null)"
peer beta fleet sync except add skills Work claude 'skills/keep/*' >/dev/null 2>&1
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check  "except-vs-delete: the pass reports the exception as an exception" \
       "excepted	skills|Work|claude|skills/keep/SKILL.md" "$out"
refute "except-vs-delete: the pass does not report a deletion" \
       "deleted	skills|Work|claude|skills/keep/SKILL.md" "$out"
same "except-vs-delete: alpha still has its own file" "keep me" \
     "$(cat "$(slot alpha Work claude)/skills/keep/SKILL.md" 2>/dev/null)"
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
same "except-vs-delete: alpha still has it after a repeated pass" "keep me" \
     "$(cat "$(slot alpha Work claude)/skills/keep/SKILL.md" 2>/dev/null)"
xn=$(peer beta fleet sync except list | grep 'skills/keep' | cut -d: -f1 | tail -1)
peer beta fleet sync except rm "$xn" >/dev/null 2>&1

# --- 20. a conflict raised by the receiver preserves real candidates --------
# A rejected push used to record empty candidates, so resolving --local
# restored nothing and destroyed the very edit it was meant to keep.
mark "20. a rejected push records both candidates"
put alpha "$(slot alpha Work claude)/skills/both/SKILL.md" 'shared start'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
put alpha "$(slot alpha Work claude)/skills/both/SKILL.md" 'ALPHA EDIT'
put beta  "$(slot beta  Work claude)/skills/both/SKILL.md" 'BETA EDIT'
# beta discovers the divergence first, so alpha's next push is the rejected one
peer beta  fleet sync now --peer "$A" >/dev/null 2>&1
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "rejected-push: alpha sees a conflict" "conflict	skills|Work|claude|skills/both/SKILL.md" "$out"
cid=$(peer alpha fleet sync conflicts | awk -F'\t' '$2=="skills|Work|claude|skills/both/SKILL.md"{print $1}' | tail -1)
sd="$base/alpha/.n2-agents/fleet/sync/conflicts/$cid"
same "rejected-push: the local candidate holds alpha's real bytes" "ALPHA EDIT" \
     "$(cat "$sd/local" 2>/dev/null)"
same "rejected-push: the remote candidate holds beta's real bytes" "BETA EDIT" \
     "$(cat "$sd/remote" 2>/dev/null)"
peer alpha fleet sync resolve "$cid" --local >/dev/null 2>&1
same "rejected-push: choosing local keeps the local edit" "ALPHA EDIT" \
     "$(cat "$(slot alpha Work claude)/skills/both/SKILL.md" 2>/dev/null)"
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
same "rejected-push: the resolution still stands after a pass" "ALPHA EDIT" \
     "$(cat "$(slot alpha Work claude)/skills/both/SKILL.md" 2>/dev/null)"

# --- 21. a symlinked *directory* cannot export outside bytes ---------------
# find -L descends through a directory link, so the exported file is not
# itself a link and the file-level check never sees it.
mark "21. directory symlink escape"
mkdir -p "$base/outside2"
printf '%s' 'OUTSIDE-DIR-SECRET' > "$base/outside2/SKILL.md"
ln -s "$base/outside2" "$(slot alpha Work claude)/skills/dirlink"
sc=$(peer alpha fleet sync scope 2>&1)
refute "dirlink: the address is never advertised" "skills/dirlink/SKILL.md" "$sc"
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
refute "dirlink: the outside bytes never reach the peer" "OUTSIDE-DIR-SECRET" \
       "$(cat "$(slot beta Work claude)/skills/dirlink/SKILL.md" 2>/dev/null)"
same "dirlink: the original outside file is untouched" "OUTSIDE-DIR-SECRET" \
     "$(cat "$base/outside2/SKILL.md")"
rm -f "$(slot alpha Work claude)/skills/dirlink"

# --- 22. `tools install` does not interrupt running work -------------------
mark "22. a named disruptive install still defers while a task is live"
tb="$base/toolbox2"; mkdir -p "$tb"
printf '%s' '' > "$tb/ver"
cat > "$tb/install.sh" <<EOS
#!/bin/sh
printf '%s' '3.0' > "$tb/ver"
EOS
chmod +x "$tb/install.sh"
peer alpha fleet tools add loudtool --version 3.0 \
  --check "cat '$tb/ver'" --install "$tb/install.sh" --disruptive >/dev/null 2>&1
mkdir -p "$base/alpha/.n2-agents/fleet/tasks/active"
printf 'id=t1\n' > "$base/alpha/.n2-agents/fleet/tasks/active/t1"
out=$(peer alpha fleet tools install loudtool 2>&1)
check "named install: a disruptive tool defers while a task is live" "deferred	loudtool" "$out"
same  "named install: nothing was installed" "" "$(cat "$tb/ver")"
check "named install: the deferral is listed" "loudtool" "$(peer alpha fleet tools deferred 2>&1)"
rm -f "$base/alpha/.n2-agents/fleet/tasks/active/t1"
out=$(peer alpha fleet tools install loudtool 2>&1)
check "named install: it installs once the fleet is idle" "loudtool" "$out"
same  "named install: the version was reached" "3.0" "$(cat "$tb/ver")"
peer alpha fleet tools rm loudtool >/dev/null 2>&1

# --- 23. the auth matrix reports where a credential actually lives ---------
# opencode was labelled `supported` on the strength of "it keeps one auth.json".
# The shipped binary resolves that file from XDG_DATA_HOME, not XDG_CONFIG_HOME,
# and profile isolation only repoints the config dir - so the credential is
# machine-wide and no amount of slot syncing carries it. That is structural, so
# the tier is `unsupported`: `partial` asserts replication is implemented, and
# an opt-in that would carry nothing is a false affordance, not a partial one.
mark "23. auth matrix honesty"
am=$(peer alpha fleet sync auth list 2>&1)
refute "auth matrix: opencode is not claimed fully supported" "opencode	supported" "$am"
refute "auth matrix: opencode does not claim partial either"  "opencode	partial" "$am"
check  "auth matrix: opencode is reported unsupported"        "opencode	unsupported" "$am"
check  "auth matrix: it names the data dir the token lives in" ".local/share/opencode/auth.json" "$am"
check  "auth matrix: it names the var isolation repoints"      "XDG_CONFIG_HOME" "$am"
# The refusal is the point: an accepted opt-in that replicates nothing would be
# indistinguishable from a sync that is quietly broken.
out=$(peer alpha fleet sync auth enable opencode 2>&1); rc=$?
denied "auth matrix: an inert opt-in is refused, not accepted" "auth enable opencode" "$rc"
check "auth matrix: the refusal says why"                     "cannot be replicated" "$out"
check "auth matrix: the refusal names the real location"      ".local/share/opencode/auth.json" "$out"
refute "auth matrix: a refused opt-in is not recorded" "opencode" "$(peer alpha fleet sync auth list 2>&1 | awk -F'\t' '$3=="opted-in"{print $1}')"

# No provider may claim the word `supported`. The design doc sets that bar at an
# authenticated call succeeding on the receiving machine from synced state, and
# development is not permitted to make that call against real credentials. A
# copied auth.json is evidence of file portability and nothing more, so codex -
# the provider with the cleanest file shape - must say what it has NOT shown.
refute "auth matrix: no provider claims the unearned word" "	supported	" "$am"
check  "auth matrix: codex is reported partial"            "codex	partial" "$am"
check  "auth matrix: codex names its conflict behaviour"   "refresh-conflict aware" "$am"
check  "auth matrix: codex states what was not verified"   "NOT verified" "$am"
check  "auth matrix: it says file copying is not sign-in"  "live authenticated call" "$am"
out=$(peer alpha fleet sync auth enable codex 2>&1)
check "auth matrix: codex opt-in warns too" "partially portable" "$out"
peer alpha fleet sync auth disable codex >/dev/null 2>&1

# --- 24. concurrent passes do not lose an agreed base ----------------------
# The state file is a read-modify-write. Two passes running at once (alpha
# talks to beta and gamma on a reconnect) used to rebuild from stale snapshots
# and drop each other's lines; a lost base reads as "never seen" next pass,
# which is a spurious pull or conflict. Run both at once and count the rows.
mark "24. concurrent state writes"
put alpha "$(slot alpha Work claude)/skills/race/SKILL.md" 'race bytes'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1 &
p1=$!
peer alpha fleet sync now --peer "$G" >/dev/null 2>&1 &
p2=$!
wait $p1; wait $p2
st="$base/alpha/.n2-agents/fleet/sync/state"
nb=$(awk -F'\t' -v p="$B" '$1==p' "$st" 2>/dev/null | grep -c . || true)
ng=$(awk -F'\t' -v p="$G" '$1==p' "$st" 2>/dev/null | grep -c . || true)
case ${nb:-0} in ''|0) bad "race: beta's agreed base survived" "no rows for $B" ;; *) ok "race: beta's agreed base survived" ;; esac
case ${ng:-0} in ''|0) bad "race: gamma's agreed base survived" "no rows for $G" ;; *) ok "race: gamma's agreed base survived" ;; esac
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
refute "race: the next pass is not a spurious conflict" "conflict	skills|Work|claude|skills/race" "$out"
refute "race: the next pass has nothing left to push"   "pushed	skills|Work|claude|skills/race" "$out"
if [ -d "$base/alpha/.n2-agents/fleet/sync/state.lock" ]; then
  bad "race: the lock is released" "state.lock still present"
else
  ok  "race: the lock is released"
fi

# --- 25. the managed-tool manifest replicates, and lands installed ---------
# Designating a tool is a fleet fact, so the manifest is a synced resource like
# anything else. The receiving machine then applies it without a second
# command — with a controlled installer, so nothing real is installed.
mark "25. managed-tool manifest replicates and applies"
bin="$base/toolbin"; mkdir -p "$bin"
peer alpha fleet tools add demotool --version 2.0 \
  --check "cat '$base/beta/demotool.v' 2>/dev/null" \
  --install "mkdir -p '$base/beta' && printf 2.0 > '$base/beta/demotool.v'" >/dev/null 2>&1
sc=$(peer alpha fleet sync scope 2>&1)
check "tools: the manifest is an addressable resource" "tools|-|-|manifest" "$sc"
# beta designates something of its own *now*, after the last agreed state, so
# the divergence this section exercises is genuine on both sides rather than
# an artefact of earlier passes: alpha's manifest is no longer a descendant of
# beta's. The first pass must report that rather than pick a winner. This is
# the same rule as any other resource.
peer beta fleet tools add betatool --version 1.5 \
  --check "printf 1.5" --install "true" >/dev/null 2>&1
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
# Assert the *word*, not just the address: any line mentioning the address
# would satisfy a bare substring check, including a silent overwrite.
# `sync now --peer` prefixes every line with the peer id, so the fields are
# peer<TAB>word<TAB>addr.
w=$(printf '%s\n' "$out" | awk -F'\t' '$3=="tools|-|-|manifest"{print $2}' | tail -1)
case ${w:-none} in
  conflict|pinned) ok "tools: independent designations conflict rather than overwrite" ;;
  *) bad "tools: independent designations conflict rather than overwrite" \
       "word was '${w:-none}'; pass said: $(printf '%s' "$out" | tr '\n' ';')" ;;
esac
# One pin per *peer*, so selecting a single id resolved whichever machine's
# divergence happened to sort last and left the pin that actually blocks the
# push to beta still held. Every pin on this address is resolved, and the
# address is asserted clear afterwards, so a half-resolution is reported
# where it happens rather than downstream as an approval-gate failure.
cids=$(peer alpha fleet sync conflicts 2>/dev/null | awk -F'\t' '$2=="tools|-|-|manifest"{print $1}')
[ -n "$cids" ] || cids=$(peer alpha fleet sync conflicts 2>/dev/null | grep 'tools|-|-|manifest' | awk '{print $1}')
if [ -n "$cids" ]; then ok "tools: the divergence is a visible conflict"; else bad "tools: the divergence is a visible conflict" "no conflict id for the manifest; conflicts were: $(peer alpha fleet sync conflicts 2>&1 | tr '\n' ';')"; fi
# Assert the resolution itself. Discarding it hid the real cause once: every
# later assertion in this section depends on the resolved manifest actually
# reaching beta, so a silent resolve failure reads as an approval-gate bug.
rout=; rbad=
for cid in ${cids:-none}; do
  r=$(peer alpha fleet sync resolve "$cid" --local 2>&1)
  rout="$rout$r
"
  case $r in *resolved*) ;; *) rbad="$rbad $cid:$(printf '%s' "$r" | tr '\n' ' ')" ;; esac
done
check "tools: the conflict resolves to the local manifest" "resolved" "$rout"
left=$(peer alpha fleet sync conflicts 2>/dev/null | grep -c 'tools|-|-|manifest' || true)
case ${left:-0} in
  0) ok "tools: no pin is left on the manifest" ;;
  *) bad "tools: no pin is left on the manifest" \
       "$left pin(s) still held after resolving '$(printf '%s' "$cids" | tr '\n' ' ')'${rbad:+; failures:$rbad}" ;;
esac
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "tools: the resolved manifest is pushed" "pushed	tools|-|-|manifest" "$out"
out=$(peer beta fleet tools list 2>&1)
check "tools: beta now has the designation" "demotool|2.0" "$out"
# The designation replicated; the *command* did not come with permission to
# run. beta has never approved this installer, so nothing executed on arrival.
if [ -e "$base/beta/demotool.v" ]; then
  bad "tools: an arriving installer does not run unapproved" \
      "the peer's install command executed on arrival"
else
  ok "tools: an arriving installer does not run unapproved"
fi
out=$(peer beta fleet tools status 2>&1)
check "tools: beta reports it as pending approval" "demotool	pending-approval" "$out"
out=$(peer beta fleet tools list 2>&1)
check "tools: the pending approval is visible in the listing" "pending-approval" "$out"
# Naming the tool is not approving it either.
out=$(peer beta fleet tools install demotool 2>&1); rc=$?
if [ "$rc" -eq 0 ] || [ -e "$base/beta/demotool.v" ]; then
  bad "tools: install by name does not bypass the approval" "it ran anyway"
else
  ok "tools: install by name does not bypass the approval"
fi
check "tools: the refusal names the approval step" "approve" "$out"
# The local operator approves that exact command once, and then it applies.
out=$(peer beta fleet tools approve demotool 2>&1)
check "tools: the approval is recorded" "approved	demotool" "$out"
peer beta fleet tools apply >/dev/null 2>&1
same  "tools: the approved installer runs" "2.0" "$(cat "$base/beta/demotool.v" 2>/dev/null)"
out=$(peer beta fleet tools status 2>&1)
check "tools: beta reports the tool ok" "demotool	ok" "$out"

# --- 26. an unapproved tool never rides in on a manifest -------------------
# Replication must not become a way to install arbitrary software: only what
# is written in the manifest is authorized, so an absent name still refuses.
mark "26. replication is not blanket install authority"
out=$(peer beta fleet tools install notdesignated 2>&1); rc=$?
denied "tools: an unlisted tool is refused on the receiver too" "$out" "$rc"
check  "tools: the refusal names the designation step" "not fleet-managed" "$out"

# --- 27. the automatic trigger: reconnect and interval ---------------------
# `sync tick` is the entry point a timer or the tray calls. A peer that was
# unreachable and comes back is a reconnect; a peer already online is only
# passed when it is overdue.
mark "27. automatic sync trigger"
put alpha "$(slot alpha Work claude)/skills/tick/SKILL.md" 'tick bytes'
out=$(peer alpha fleet sync tick --interval 3600 2>&1)
check "tick: the first sight of a peer is a reconnect" "pass	$B	reconnect" "$out"
same  "tick: the pass actually replicated" "tick bytes" \
      "$(cat "$(slot beta Work claude)/skills/tick/SKILL.md" 2>/dev/null)"
out=$(peer alpha fleet sync tick --interval 3600 2>&1)
check  "tick: an already-online peer inside the interval is left alone" "fresh	$B" "$out"
refute "tick: no pass is run when nothing is due" "pass	$B" "$out"
out=$(peer alpha fleet sync tick --interval 0 2>&1)
check "tick: an overdue peer is passed on the interval" "pass	$B	interval" "$out"

# --- 28. an unreachable peer is recorded, and its return triggers a pass ---
mark "28. offline then reconnect"
mv "$base/gamma" "$base/gamma.away"
out=$(peer alpha fleet sync tick --interval 3600 2>&1)
check "tick: the unreachable peer is reported offline" "offline	$G" "$out"
mv "$base/gamma.away" "$base/gamma"
put alpha "$(slot alpha Work claude)/skills/back/SKILL.md" 'back bytes'
out=$(peer alpha fleet sync tick --interval 3600 2>&1)
check "tick: the returning peer is a reconnect, not a wait" "pass	$G	reconnect" "$out"
same  "tick: the reconnect pass carried the missed change" "back bytes" \
      "$(cat "$(slot gamma Work claude)/skills/back/SKILL.md" 2>/dev/null)"

# --- 29. reconcile runs a sync round ---------------------------------------
# Coming back from time offline is exactly when replication is owed, so the
# reconnect command does it rather than leaving it to the operator.
mark "29. reconcile syncs"
put alpha "$(slot alpha Work claude)/skills/recon/SKILL.md" 'recon bytes'
out=$(peer alpha fleet reconcile 2>&1)
check "reconcile: it reports a sync round" "sync	" "$out"
same  "reconcile: the change reached the peer" "recon bytes" \
      "$(cat "$(slot beta Work claude)/skills/recon/SKILL.md" 2>/dev/null)"
put alpha "$(slot alpha Work claude)/skills/nosync/SKILL.md" 'nosync bytes'
out=$(peer alpha fleet reconcile --no-sync 2>&1)
refute "reconcile: --no-sync does not replicate" "sync	pass" "$out"
if [ -f "$(slot beta Work claude)/skills/nosync/SKILL.md" ]; then
  bad "reconcile: --no-sync left the peer untouched" "the file was replicated anyway"
else
  ok  "reconcile: --no-sync left the peer untouched"
fi

# --- 30. a credential hidden in a settings file is still a credential ------
# Claude Code reads an `env` block and `apiKeyHelper` out of settings.json, so a
# live token can sit in a file whose *path* classifies as `settings`. Class is a
# pure function of the path (so an address is stable), therefore the gate has to
# be content-aware or the token would replicate without the auth opt-in.
mark "30. credential material inside a settings-class file"
put alpha "$(slot alpha Work claude)/settings.local.json" \
    "{\"env\":{\"ANTHROPIC_API_KEY\":\"$SECRET\"},\"model\":\"opus\"}"
sc=$(peer alpha fleet sync scope 2>&1)
refute "secret-in-settings: it drops out of scope without the opt-in" \
       "settings|Work|claude|settings.local.json" "$sc"
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
refute "secret-in-settings: nothing is pushed without the opt-in" \
       "pushed	settings|Work|claude|settings.local.json" "$out"
refute "secret-in-settings: the value never appears in the pass output" "$SECRET" "$out"
if grep -rqF "$SECRET" "$(slot beta Work claude)" 2>/dev/null; then
  bad "secret-in-settings: beta never received the token" "the token was replicated"
else
  ok  "secret-in-settings: beta never received the token"
fi
# A peer that tries to push it anyway is refused on the receiving side too: beta
# has no opt-in for claude, so the arriving payload is rejected at the write.
# The opt-in itself is asserted: a mistyped verb would make both refusal
# assertions above pass for the wrong reason.
out=$(peer alpha fleet sync auth enable claude 2>&1)
check "secret-in-settings: the sender opts in" "auth-optin	claude" "$out"
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
if grep -rqF "$SECRET" "$(slot beta Work claude)" 2>/dev/null; then
  bad "secret-in-settings: the receiver refuses a credential it never opted into" \
      "beta stored the token with no opt-in of its own"
else
  ok  "secret-in-settings: the receiver refuses a credential it never opted into"
fi
# With the opt-in on both machines it is ordinary, explicitly shared auth material.
out=$(peer beta fleet sync auth enable claude 2>&1)
check "secret-in-settings: the receiver opts in" "auth-optin	claude" "$out"
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
same "secret-in-settings: opted in on both sides, it replicates" "$SECRET" \
     "$(sed -n 's/.*"ANTHROPIC_API_KEY":"\([^"]*\)".*/\1/p' \
        "$(slot beta Work claude)/settings.local.json" 2>/dev/null)"
# And a settings file with no credential in it is unaffected by any of this.
put alpha "$(slot alpha Work codex)/config.toml" 'model = "gpt-5"'
sc=$(peer alpha fleet sync scope 2>&1)
check "secret-in-settings: an ordinary settings file still syncs" \
      "settings|Work|codex|config.toml" "$sc"

# --- 31. the automatic round is installed, not just available -------------
# `sync tick` is only automatic if something calls it. This section installs
# the launchd job against a fixture LaunchAgents directory and a stub
# launchctl, so it exercises the real plist writer and the real load/unload
# path without touching the operator's login session.
mark "31. the installed launchd timer"
lad="$base/LaunchAgents"; lcbin="$base/bin/launchctl"; lclog="$base/launchctl.log"
mkdir -p "$lad" "$base/bin" "$base/loaded"
cat > "$lcbin" <<'STUB'
#!/bin/sh
# Records what the CLI asked for and models load state as a file, so "is it
# loaded" is answered by what bootstrap/bootout actually did.
printf '%s\n' "$*" >> "$LCLOG"
case ${1:-} in
  bootstrap) [ -f "$3" ] || exit 1; : > "$LCSTATE/loaded"; exit 0 ;;
  bootout)   [ -f "$LCSTATE/loaded" ] || exit 3; rm -f "$LCSTATE/loaded"; exit 0 ;;
  print)     [ -f "$LCSTATE/loaded" ] || exit 113; exit 0 ;;
esac
exit 64
STUB
chmod +x "$lcbin"
svc() { env HOME="$base/alpha" LCLOG="$lclog" LCSTATE="$base/loaded" \
  N2_FLEET_LAUNCH_DIR="$lad" N2_FLEET_LAUNCHCTL="$lcbin" N2_FLEET_AGENTS="$repo/agents" \
  "$repo/agents" "$@"; }

out=$(svc fleet sync service status 2>&1)
check "service: nothing is installed to begin with" "plist	none" "$out"
check "service: and nothing is loaded"              "loaded	no"   "$out"

denied "service: a sub-minute interval is refused" "$(svc fleet sync service install --interval 5 2>&1)" \
       "$(svc fleet sync service install --interval 5 >/dev/null 2>&1; echo $?)"

out=$(svc fleet sync service install --interval 120 2>&1)
check "service: install reports the plist it wrote" "$lad/com.n2agents.fleet-sync.plist" "$out"
check "service: launchd loaded it"                  "loaded	com.n2agents.fleet-sync	interval=120" "$out"
pl="$lad/com.n2agents.fleet-sync.plist"
if [ -f "$pl" ]; then ok "service: the plist exists on disk"; else bad "service: the plist exists on disk" "missing"; fi
check "service: it runs the tick verb"   "<string>tick</string>" "$(cat "$pl")"
check "service: on the declared interval" "<key>StartInterval</key><integer>120</integer>" "$(cat "$pl")"
check "service: it runs at load"          "<key>RunAtLoad</key><true/>" "$(cat "$pl")"
check "service: it points at this HOME"   "<string>$base/alpha</string>" "$(cat "$pl")"
check "service: it points at the real entry point" "<string>$repo/agents</string>" "$(cat "$pl")"
check "service: launchctl was asked to bootstrap it" "bootstrap gui/" "$(cat "$lclog")"
# A plist is world-readable config; no credential may ever be written into it.
refute "service: the plist carries no secret" "$SECRET" "$(cat "$pl")"

out=$(svc fleet sync service status 2>&1)
check "service: status sees the installed plist" "plist	$pl" "$out"
check "service: status reports the interval"     "interval	120" "$out"
check "service: status reports it loaded"        "loaded	yes" "$out"

# Reinstalling replaces the job rather than stacking a second copy.
out=$(svc fleet sync service install --interval 300 2>&1)
check "service: reinstall reloads"           "loaded	com.n2agents.fleet-sync	interval=300" "$out"
same  "service: only one plist exists"       "1" "$(ls "$lad" | grep -c . )"
check "service: the interval was rewritten"  "<integer>300</integer>" "$(cat "$pl")"

# The installed job is the same code path a manual tick takes, so proving the
# verb it invokes actually replicates is what makes the install meaningful.
put alpha "$(slot alpha Work claude)/skills/timer/SKILL.md" 'installed by the timer'
out=$(svc fleet sync tick --interval 0 2>&1)
check "service: the installed verb replicates" "pass	$B" "$out"
same  "service: beta received the timer-driven change" "installed by the timer" \
      "$(cat "$(slot beta Work claude)/skills/timer/SKILL.md" 2>/dev/null)"

out=$(svc fleet sync service uninstall 2>&1)
check "service: uninstall reports removal" "removed	com.n2agents.fleet-sync	yes" "$out"
if [ -f "$pl" ]; then bad "service: the plist is gone" "still present"; else ok "service: the plist is gone"; fi
check "service: launchctl was asked to unload it" "bootout gui/" "$(cat "$lclog")"
out=$(svc fleet sync service status 2>&1)
check "service: status is honest after removal" "loaded	no" "$out"

# --- 32. a symlink *chain* cannot escape, and a loop does not hang ---------
# One hop of resolution is not enough: a link inside the slot can name a second
# link inside the slot that points out. A self-referential link must fail
# closed rather than spin.
mark "32. symlink chains and cycles"
mkdir -p "$base/outside3"
printf '%s' 'TWO-HOP-SECRET' > "$base/outside3/value"
mkdir -p "$sa/skills/chain"
ln -s "$base/outside3/value" "$sa/second"
ln -s ../second "$sa/skills/chain/SKILL.md"
ln -s SKILL.md "$sa/skills/loop/SKILL.md" 2>/dev/null || {
  mkdir -p "$sa/skills/loop"; ln -s SKILL.md "$sa/skills/loop/SKILL.md"; }
sc=$(peer alpha fleet sync scope 2>&1)
refute "chain: the two-hop address is never advertised" "skills/chain/SKILL.md" "$sc"
refute "chain: the cyclic address is never advertised" "skills/loop/SKILL.md" "$sc"
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
refute "chain: the outside bytes never reach the peer" "TWO-HOP-SECRET" \
       "$(cat "$(slot beta Work claude)/skills/chain/SKILL.md" 2>/dev/null)"
same "chain: the original outside file is untouched" "TWO-HOP-SECRET" \
     "$(cat "$base/outside3/value")"

# A chain that stays inside the slot is a deliberate adopted layout, not an
# escape, and must still replicate.
printf '%s' 'IN-SLOT-CHAIN' > "$sa/skills/target.md"
ln -s target.md "$sa/skills/mid.md"
ln -s mid.md "$sa/skills/inchain.md"
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
same "chain: an in-slot chain still replicates" "IN-SLOT-CHAIN" \
     "$(cat "$(slot beta Work claude)/skills/inchain.md" 2>/dev/null)"
rm -f "$sa/skills/chain/SKILL.md" "$sa/skills/loop/SKILL.md" "$sa/second"
rmdir "$sa/skills/chain" "$sa/skills/loop" 2>/dev/null || true

# --- 33. a write never creates directories outside the slot ----------------
# mkdir -p walks through a symlinked ancestor. The receiver must refuse before
# anything is created, not after the bytes are already staged outside.
mark "33. an escaping ancestor is refused before mkdir"
mkdir -p "$base/outside4"
sb=$(slot beta Work claude)
mkdir -p "$sb/skills"
ln -s "$base/outside4" "$sb/skills/esc"
put alpha "$sa/skills/esc/deep/SKILL.md" 'SHOULD-NOT-LAND'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
same "ancestor: no directory was created outside the slot" "" \
     "$(ls -A "$base/outside4" 2>/dev/null)"
refute "ancestor: the bytes never landed outside" "SHOULD-NOT-LAND" \
       "$(cat "$base/outside4/deep/SKILL.md" 2>/dev/null)"
rm -f "$sb/skills/esc"
rm -rf "$sa/skills/esc"

# --- 34. withholding a credential is not deleting the peer's copy ----------
# Reproduces a real data-loss defect. Once alpha and beta agree on a synthetic
# credential, beta turning auth sharing back off dropped the address from its
# manifest entirely. Alpha saw no digest, read the gap as a tombstone, and
# deleted a credential that beta still held.
mark "34. an opted-out credential is withheld, not tombstoned"
# Uses a profile of its own so the address carries no history from the earlier
# sections (which deliberately leave a pinned credential conflict behind, and a
# pin outranks every decision below).
mkdir -p "$(slot alpha Withhold codex)" "$(slot beta Withhold codex)"
peer alpha fleet sync auth enable codex >/dev/null 2>&1
peer beta  fleet sync auth enable codex >/dev/null 2>&1
put alpha "$(slot alpha Withhold codex)/auth.json" '{"tokens":{"access":"SYNTHETIC-WITHHOLD"},"last_refresh":"9"}'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
same "withhold: both machines start from the same credential" \
     '{"tokens":{"access":"SYNTHETIC-WITHHOLD"},"last_refresh":"9"}' \
     "$(cat "$(slot beta Withhold codex)/auth.json" 2>/dev/null)"
peer beta fleet sync auth disable codex >/dev/null 2>&1
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
same "withhold: alpha still holds its credential" \
     '{"tokens":{"access":"SYNTHETIC-WITHHOLD"},"last_refresh":"9"}' \
     "$(cat "$(slot alpha Withhold codex)/auth.json" 2>/dev/null)"
refute "withhold: the opt-out is not reported as a deletion" \
       "deleted	auth|Withhold|codex|auth.json" "$out"
check  "withhold: it is reported as excepted" \
       "excepted	auth|Withhold|codex|auth.json" "$out"
same "withhold: beta keeps its own copy too" \
     '{"tokens":{"access":"SYNTHETIC-WITHHOLD"},"last_refresh":"9"}' \
     "$(cat "$(slot beta Withhold codex)/auth.json" 2>/dev/null)"
# Symmetric: the holder of the opt-out must not read the *other* side as gone.
out=$(peer beta fleet sync now --peer "$A" 2>&1)
same "withhold: beta still holds its credential after its own pass" \
     '{"tokens":{"access":"SYNTHETIC-WITHHOLD"},"last_refresh":"9"}' \
     "$(cat "$(slot beta Withhold codex)/auth.json" 2>/dev/null)"
refute "withhold: beta does not delete alpha's copy either" "deleted	auth|Withhold|codex" "$out"
peer beta fleet sync auth enable codex >/dev/null 2>&1

# --- 35. a pinned conflict is not overwritten by a third machine -----------
# The pin is a statement about the resource. A third peer whose base happens to
# agree with ours must not push straight through an unresolved conflict and
# destroy the candidate the operator was asked to choose between.
mark "35. a third peer cannot write through a pin"
put alpha "$(slot alpha Work claude)/skills/pin3/SKILL.md" 'SHARED-ORIGIN'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
peer alpha fleet sync now --peer "$G" >/dev/null 2>&1
put alpha "$(slot alpha Work claude)/skills/pin3/SKILL.md" 'ALPHA-EDIT'
put beta  "$(slot beta  Work claude)/skills/pin3/SKILL.md" 'BETA-EDIT'
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "pin3: alpha and beta conflict" "conflict	skills|Work|claude|skills/pin3/SKILL.md" "$out"
put gamma "$(slot gamma Work claude)/skills/pin3/SKILL.md" 'GAMMA-EDIT'
out=$(peer gamma fleet sync now --peer "$A" 2>&1)
same "pin3: alpha's pinned candidate survives gamma's push" "ALPHA-EDIT" \
     "$(cat "$(slot alpha Work claude)/skills/pin3/SKILL.md" 2>/dev/null)"
refute "pin3: gamma is not told the push landed" "pushed	skills|Work|claude|skills/pin3/SKILL.md" "$out"
check  "pin3: the conflict is still listed for the operator" \
       "skills|Work|claude" "$(peer alpha fleet sync conflicts 2>&1)"
# And it is still resolvable afterwards, by the operator, to a real candidate.
cid=$(peer alpha fleet sync conflicts | awk -F'\t' '$2 ~ /pin3/ {print $1; exit}')
peer alpha fleet sync resolve "$cid" --local >/dev/null 2>&1
same "pin3: the operator's choice is what finally lands" "ALPHA-EDIT" \
     "$(cat "$(slot alpha Work claude)/skills/pin3/SKILL.md" 2>/dev/null)"

# --- 36. the conflict count is a single integer ----------------------------
# grep -c prints "0" and exits 1 on no match, so `|| echo 0` emitted two lines
# and every numeric comparison downstream died with "integer expression
# expected". The count has to be one line, always.
mark "36. the conflict count is one integer"
while :; do
  cid=$(peer alpha fleet sync conflicts | awk -F'\t' 'NR==1{print $1}')
  [ -n "$cid" ] || break
  peer alpha fleet sync resolve "$cid" --local >/dev/null 2>&1 || break
done
cnt=$(peer alpha fleet sync status 2>&1 | awk -F'\t' '$1=="conflicts"{print $2}')
same "count: zero conflicts reports exactly one line" "1" "$(printf '%s\n' "$cnt" | grep -c .)"
same "count: zero conflicts reports 0"                "0" "$cnt"
refute "count: status does not raise a shell error" "integer expression expected" \
       "$(peer alpha fleet sync status 2>&1)"
refute "count: a sync pass does not raise a shell error" "integer expression expected" \
       "$(peer alpha fleet sync now --peer "$B" 2>&1)"

# --- 37. an unfetchable remote candidate is not a deletion -----------------
# The pass advertises a remote edit and then fails to fetch it. Recording that
# as an empty candidate made `resolve --remote` mean "write nothing", i.e.
# delete a file the peer still holds. Not knowing is not a deletion.
mark "37. an unfetchable remote candidate is not a deletion"
# The fault is injected at the carrier, not inside the product: this wrapper
# forwards every message to the real `agents` except a sync-get, which it drops
# the way a broken link would.
cat > "$base/dropget" <<EOS
#!/bin/sh
m=\$(mktemp "\${TMPDIR:-/tmp}/dropget.XXXXXX"); cat > "\$m"
if grep -q '^verb=sync-get\$' "\$m"; then rm -f "\$m"; exit 1; fi
env N2_FLEET_AGENTS="\$0" "$repo/agents" "\$@" < "\$m"; rc=\$?; rm -f "\$m"; exit \$rc
EOS
chmod +x "$base/dropget"
dropget() { dh=$1; shift; env HOME="$base/$dh" N2_FLEET_AGENTS="$base/dropget" "$repo/agents" "$@"; }
ua="skills|Unavail|claude|skills/u/SKILL.md"
mkdir -p "$(slot beta Unavail claude)"
put alpha "$(slot alpha Unavail claude)/skills/u/SKILL.md" 'shared start'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
put alpha "$(slot alpha Unavail claude)/skills/u/SKILL.md" 'ALPHA U'
put beta  "$(slot beta  Unavail claude)/skills/u/SKILL.md" 'BETA U'
out=$(dropget alpha fleet sync now --peer "$B" 2>&1)
check "unavail: a failed fetch still pins the conflict" "conflict	$ua" "$out"
cid=$(peer alpha fleet sync conflicts | awk -F'\t' -v k="$ua" '$2==k{print $1}' | tail -1)
check "unavail: the remote candidate is marked unavailable" "remote:unavailable" \
      "$(peer alpha fleet sync conflicts | grep "$cid")"
sd="$base/alpha/.n2-agents/fleet/sync/conflicts/$cid"
if [ -f "$sd/remote.deleted" ]; then
  bad "unavail: an unfetchable candidate is not recorded as a deletion" "remote.deleted was written"
else ok "unavail: an unfetchable candidate is not recorded as a deletion"; fi
out=$(peer alpha fleet sync resolve "$cid" --remote 2>&1); rc=$?
denied "unavail: choosing the remote side is refused while it cannot be fetched" "$out" "$rc"
same "unavail: the refused resolution left the local file alone" "ALPHA U" \
     "$(cat "$(slot alpha Unavail claude)/skills/u/SKILL.md" 2>/dev/null)"
check "unavail: the conflict is still pinned for the operator" "$ua" \
      "$(peer alpha fleet sync conflicts 2>&1)"
# It heals by itself: the next working pass refreshes the candidate.
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
check "unavail: a working pass upgrades the candidate to present" "remote:present" \
      "$(peer alpha fleet sync conflicts | grep "$cid")"
peer alpha fleet sync resolve "$cid" --remote >/dev/null 2>&1
same "unavail: the remote choice then lands the peer's real bytes" "BETA U" \
     "$(cat "$(slot alpha Unavail claude)/skills/u/SKILL.md" 2>/dev/null)"

# --- 38. a zero-byte remote is a candidate, not a tombstone ----------------
# The rejected-push path tested the fetched body with -s, so a legitimately
# empty file was indistinguishable from "nothing came back".
mark "38. an empty remote candidate is preserved"
ea="settings|Empt|claude|settings.json"
mkdir -p "$(slot beta Empt claude)"
put alpha "$(slot alpha Empt claude)/settings.json" 'start'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
put alpha "$(slot alpha Empt claude)/settings.json" 'ALPHA NONEMPTY'
: > "$(slot beta Empt claude)/settings.json"
peer beta fleet sync now --peer "$A" >/dev/null 2>&1
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "empty: the rejected push is a conflict" "conflict	$ea" "$out"
cid=$(peer alpha fleet sync conflicts | awk -F'\t' -v k="$ea" '$2==k{print $1}' | tail -1)
sd="$base/alpha/.n2-agents/fleet/sync/conflicts/$cid"
check "empty: the empty remote is recorded as present" "remote:present" \
      "$(peer alpha fleet sync conflicts | grep "$cid")"
if [ -f "$sd/remote" ] && [ ! -f "$sd/remote.deleted" ]; then
  ok "empty: the zero-byte candidate is stored as a candidate"
else bad "empty: the zero-byte candidate is stored as a candidate" "recorded as a deletion"; fi
peer alpha fleet sync resolve "$cid" --remote >/dev/null 2>&1
if [ -f "$(slot alpha Empt claude)/settings.json" ]; then
  ok "empty: resolving to the remote empties the file instead of deleting it"
else bad "empty: resolving to the remote empties the file instead of deleting it" "the file was removed"; fi
same "empty: and its contents are the peer's empty bytes" "" \
     "$(cat "$(slot alpha Empt claude)/settings.json" 2>/dev/null)"

# --- 39. managed tools are reconciled on every tick ------------------------
# Applying only when something had been deferred meant designating a tool never
# installed it on its own, and a tool that vanished stayed broken until a human
# ran `tools apply`. The automatic trigger has to repair, not just retry.
mark "39. managed tools are reconciled on every tick"
# The check and install commands are $HOME-relative so each peer reconciles its
# own copy: the manifest replicates, but what lands is per machine.
peer alpha fleet tools add gizmo --version 1.0 \
  --check 'cat $HOME/gizmo.version 2>/dev/null' \
  --install "sh $T/install.sh \$HOME/gizmo 1.0" >/dev/null
gv="$base/alpha/gizmo.version"
out=$(peer alpha fleet sync tick --interval 0 2>&1)
check "tick-tools: designating a tool is enough; the tick installs it" "tools	install	gizmo" "$out"
same  "tick-tools: the designated version landed" "1.0" "$(cat "$gv" 2>/dev/null)"
rm -f "$gv"
out=$(peer alpha fleet sync tick --interval 0 2>&1)
check "tick-tools: a tool that disappeared is repaired on the next tick" "tools	install	gizmo" "$out"
same  "tick-tools: the repair restored the version" "1.0" "$(cat "$gv" 2>/dev/null)"
out=$(peer alpha fleet sync tick --interval 0 2>&1)
check "tick-tools: a satisfied tool is reported ok, not reinstalled" "tools	ok	gizmo" "$out"
refute "tick-tools: reconciliation never reaches an undesignated tool" "rogue" "$out"

# --- 40. a pinned candidate belongs to the peer that raised it -------------
# Surviving a third peer's push (section 35) is not enough: the *candidate*
# must survive too. Refreshing a pin from whichever peer happened to be visited
# next replaced beta's edit with the pre-divergence bytes gamma still held, and
# `resolve --remote` then restored a file nobody had written.
mark "40. a candidate is not replaced by an unrelated peer"
put alpha "$(slot alpha Work claude)/skills/pin4/SKILL.md" 'ORIGIN-4'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
peer alpha fleet sync now --peer "$G" >/dev/null 2>&1
put alpha "$(slot alpha Work claude)/skills/pin4/SKILL.md" 'ALPHA-4'
put beta  "$(slot beta  Work claude)/skills/pin4/SKILL.md" 'BETA-4'
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "pin4: alpha and beta conflict" "conflict	skills|Work|claude|skills/pin4/SKILL.md" "$out"
cid=$(peer alpha fleet sync conflicts | awk -F'\t' '$2 ~ /pin4/ {print $1; exit}')
before=$(peer alpha fleet sync show "$cid" 2>&1)
# gamma has changed nothing; it still advertises ORIGIN-4.
out=$(peer alpha fleet sync now --peer "$G" 2>&1)
check "pin4: the pin holds against the unrelated peer" \
      "pinned	skills|Work|claude|skills/pin4/SKILL.md" "$out"
after=$(peer alpha fleet sync show "$cid" 2>&1)
same "pin4: the recorded candidate is unchanged" \
     "$(printf '%s\n' "$before" | grep '^remote=')" \
     "$(printf '%s\n' "$after"  | grep '^remote=')"
check "pin4: the pin still names the peer that raised it" "peer=$B" "$after"
check "pin4: gamma's divergence is reported beside the pin, not as the candidate" \
      "also_diverged=$G" "$after"
peer alpha fleet sync resolve "$cid" --remote >/dev/null 2>&1
same "pin4: --remote lands the edit of the peer that raised the conflict" "BETA-4" \
     "$(cat "$(slot alpha Work claude)/skills/pin4/SKILL.md" 2>/dev/null)"

# --- 41. a pipeline in an installer cannot move the disruptive flag --------
# The manifest is five delimited fields. An installer is a shell command and may
# contain a pipe; written raw it shifted `disruptive` out of field 5, so a
# disruptive installer ran during active work instead of being deferred.
mark "41. tool command fields cannot shift the record"
mkdir -p "$base/alpha/.n2-agents/fleet/tasks/active"
printf 'id=t9\n' > "$base/alpha/.n2-agents/fleet/tasks/active/t9"
canary="$base/piper.canary"; rm -f "$canary"
peer alpha fleet tools add piper --version 2.0 \
  --check 'cat $HOME/piper.version 2>/dev/null' \
  --install "touch $canary | cat; sh $T/install.sh \$HOME/piper 2.0" --disruptive >/dev/null
out=$(peer alpha fleet tools apply 2>&1)
check "pipe: the pipelined disruptive installer is deferred, not run" "deferred	piper" "$out"
if [ -e "$canary" ]; then bad "pipe: a deferred installer did not execute" "canary exists"; else
  ok "pipe: a deferred installer did not execute"; fi
out=$(peer alpha fleet tools install piper 2>&1)
check "pipe: naming it explicitly still defers it" "deferred	piper" "$out"
if [ -e "$canary" ]; then bad "pipe: the named install did not execute either" "canary exists"; else
  ok "pipe: the named install did not execute either"; fi
check "pipe: the round-tripped install command is the operator's command" \
      "touch $canary | cat" "$(peer alpha fleet tools list 2>&1)"
rm -f "$base/alpha/.n2-agents/fleet/tasks/active/t9"
out=$(peer alpha fleet tools apply 2>&1)
check "pipe: with no active task the pipeline runs as written" "install	piper" "$out"
if [ -e "$canary" ]; then ok "pipe: the pipeline's first stage really ran"; else
  bad "pipe: the pipeline's first stage really ran" "no canary"; fi
same "pipe: and the tool reached its designated version" "2.0" \
     "$(cat "$base/alpha/piper.version" 2>/dev/null)"
# A hand-edited manifest line with the wrong shape is refused, not parsed.
printf 'bogus|1|true|touch %s|extra|disruptive\n' "$base/bogus.canary" \
  >> "$base/alpha/.n2-agents/fleet/tools/manifest"
out=$(peer alpha fleet tools apply 2>&1)
check "pipe: a malformed manifest record is refused" "invalid	bogus" "$out"
if [ -e "$base/bogus.canary" ]; then bad "pipe: a malformed record is not authorization" "canary exists"; else
  ok "pipe: a malformed record is not authorization"; fi
denied "pipe: it cannot be installed by name either" "bogus" \
       "$(peer alpha fleet tools install bogus >/dev/null 2>&1; echo $?)"

# --- 42. an operator's resolution travels once, and only that far ---------
# Resolving on one machine used to leave the *other* machine pinning the mirror
# image of the same conflict: it judged the incoming push against its own stale
# agreed base, saw "both sides changed", and answered `conflict` forever. A
# push now declares the base it was made from, and a receiver holding exactly
# those bytes accepts the decision. A receiver that edited after the sender
# looked is not holding those bytes, and it still conflicts.
mark "42. a resolution travels, but only over the bytes it was made against"
put alpha "$(slot alpha Work claude)/skills/trav/SKILL.md" 'ORIGIN-T'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
put alpha "$(slot alpha Work claude)/skills/trav/SKILL.md" 'ALPHA-T'
put beta  "$(slot beta  Work claude)/skills/trav/SKILL.md" 'BETA-T'
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "trav: the divergence is a conflict" "conflict	skills|Work|claude|skills/trav/SKILL.md" "$out"
cid=$(peer alpha fleet sync conflicts | awk -F'\t' '$2 ~ /trav/ {print $1; exit}')
peer alpha fleet sync resolve "$cid" --local >/dev/null 2>&1
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "trav: the resolution is pushed, not re-conflicted" \
      "pushed	skills|Work|claude|skills/trav/SKILL.md" "$out"
same "trav: the chosen bytes land on the peer" "ALPHA-T" \
     "$(cat "$(slot beta Work claude)/skills/trav/SKILL.md" 2>/dev/null)"
refute "trav: and the peer is left with no mirror-image conflict to resolve" \
       "trav" "$(peer beta fleet sync conflicts 2>&1)"
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "trav: a repeated pass is quiet" "noop	skills|Work|claude|skills/trav/SKILL.md" "$out"

# The negative case: the receiver edits *after* the sender looked. The declared
# base no longer describes what it holds, so nothing is overwritten.
put alpha "$(slot alpha Work claude)/skills/trav2/SKILL.md" 'ORIGIN-T2'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
put alpha "$(slot alpha Work claude)/skills/trav2/SKILL.md" 'ALPHA-T2'
put beta  "$(slot beta  Work claude)/skills/trav2/SKILL.md" 'BETA-T2'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
cid=$(peer alpha fleet sync conflicts | awk -F'\t' '$2 ~ /trav2/ {print $1; exit}')
peer alpha fleet sync resolve "$cid" --local >/dev/null 2>&1
# beta moves on while the operator was deciding.
put beta "$(slot beta Work claude)/skills/trav2/SKILL.md" 'BETA-T2-LATER'
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "trav2: a later edit on the receiver is not fast-forwarded away" \
      "conflict	skills|Work|claude|skills/trav2/SKILL.md" "$out"
same "trav2: the receiver's later bytes are still there" "BETA-T2-LATER" \
     "$(cat "$(slot beta Work claude)/skills/trav2/SKILL.md" 2>/dev/null)"

# --- 43. a local edit inside the apply window is never overwritten ---------
# A pass decides from a manifest snapshot and applies after a peer round trip.
# Everything above drives whole processes, which cannot place an edit *inside*
# that window on purpose. These two run the real fleet-sync.sh with the fetch
# boundary made deterministic, so the lost-update case is an assertion rather
# than a race nobody can schedule.
mark "43. no lost update across the apply window"
race() {  # race <remote-digest-mode: body|tomb> -> "<words>|<final-bytes>|<conflicts>"
  env HOME="$base/race-$1" N2_FLEET_AGENTS="$repo/agents" sh -c '
    set -u
    cd "$1" || exit 1
    root=$HOME/profiles
    . ./fleet.sh
    . ./fleet-sync.sh
    config_dir() { echo "$root/$1/$2"; }
    all_profiles() { echo Work; }
    N2_VENDORS=claude
    mkdir -p "$root/Work/claude" "$fleet_root"
    sync_init
    rm -f "$(sync_tools_manifest)"
    addr="settings|Work|claude|settings.json"
    file=$root/Work/claude/settings.json
    printf ORIGINAL > "$file"
    # Local and base agree, so the pass decides `pull`: the clean precondition.
    sync_base_set peer "$addr" "$(sync_digest_file "$file")"
    if [ "$2" = tomb ]; then
      # The peer advertises a real tombstone: the decision is "delete locally".
      sync_remote_manifest() { printf "%s\t%s\n" "$addr" "$SYNC_TOMBSTONE"; }
      # That path has no fetch of its own, so the boundary that matters is the
      # local manifest read. The edit lands immediately after it.
      sync_manifest() { printf "%s\t%s\n" "$addr" "$(sync_digest_file "$file")"
                        printf EDIT-INSIDE-WINDOW > "$file"; }
    else
      printf REMOTE > "$HOME/remote"
      sync_remote_manifest() { printf "%s\t%s\n" "$addr" "$(sync_digest_file "$HOME/remote")"; }
      # The editor lands while the body is in flight.
      fleet_call() { printf EDIT-INSIDE-WINDOW > "$file"; cat "$HOME/remote"; }
    fi
    w=$(sync_pass_peer peer | cut -f1 | tr "\n" , )
    printf "%s|%s|%s" "$w" "$(cat "$file" 2>/dev/null)" "$(sync_conflict_count)"
  ' _ "$repo" "$1"
}
mkdir -p "$base/race-body" "$base/race-tomb"
r=$(race body)
same "race: the edit that landed during the fetch is still on disk" \
     "EDIT-INSIDE-WINDOW" "$(printf '%s' "$r" | cut -d'|' -f2)"
check "race: and the pass reports a conflict, not a silent pull" \
      "conflict" "$(printf '%s' "$r" | cut -d'|' -f1)"
refute "race: the stale decision is not carried out" \
       "pulled" "$(printf '%s' "$r" | cut -d'|' -f1)"
same "race: the operator is given something to resolve" \
     "1" "$(printf '%s' "$r" | cut -d'|' -f3)"
r=$(race tomb)
same "race: a remote deletion does not take an edit that landed after the read" \
     "EDIT-INSIDE-WINDOW" "$(printf '%s' "$r" | cut -d'|' -f2)"
refute "race: and the file is not reported deleted" \
       "deleted" "$(printf '%s' "$r" | cut -d'|' -f1)"

# --- 44. two responders racing the same resource cannot lose an edit -------
mark "44. concurrent absorbs of one resource"
# Section 43 covers an edit that lands *during* a fetch. This is the other
# shape: two independent responder processes, each handling a push for the same
# address, each deciding against the same agreed base. Both are released by a
# barrier before either enters the mutated region, so they genuinely contend
# for the resource rather than deadlocking inside it. Exactly one may apply;
# the other has to raise a conflict, because silently writing second is a lost
# update that no operator would ever be shown.
rc="$base/race-concurrent"; mkdir -p "$rc/home/Work/claude"
cat > "$rc/worker" <<'WORKER'
root=$rcroot
. "$repo/fleet.sh"
. "$repo/fleet-sync.sh"
config_dir() { echo "$root/$1/$2"; }
a='settings|Work|claude|settings.json'
touch "$barrier/ready-$worker"
while [ ! -f "$barrier/ready-A" ] || [ ! -f "$barrier/ready-B" ]; do sleep 0.01; done
sync_absorb "$a" "$barrier/$worker" "$(sync_digest_file "$barrier/$worker")" "$worker" ''
WORKER
race_concurrent() {
  rm -rf "$rc/run"; mkdir -p "$rc/run/profiles/Work/claude" "$rc/run/home"
  printf ORIGINAL > "$rc/run/profiles/Work/claude/settings.json"
  printf EDIT-A > "$rc/run/A"; printf EDIT-B > "$rc/run/B"
  env HOME="$rc/run/home" repo="$repo" rcroot="$rc/run/profiles" barrier="$rc/run" sh -c '
    root=$rcroot
    . "$repo/fleet.sh"; . "$repo/fleet-sync.sh"
    config_dir() { echo "$root/$1/$2"; }
    a="settings|Work|claude|settings.json"
    sync_init
    d=$(sync_digest_file "$root/Work/claude/settings.json")
    sync_base_set A "$a" "$d"; sync_base_set B "$a" "$d"
    worker=A sh "$0" > "$barrier/out-A" & p1=$!
    worker=B sh "$0" > "$barrier/out-B" & p2=$!
    wait "$p1"; wait "$p2"
    printf "%s|%s|%s|%s" "$(cat "$barrier/out-A")" "$(cat "$barrier/out-B")" \
      "$(cat "$root/Work/claude/settings.json")" "$(sync_conflict_count)"
  ' "$rc/worker"
}
r=$(race_concurrent)
ra=$(printf '%s' "$r" | cut -d'|' -f1); rb=$(printf '%s' "$r" | cut -d'|' -f2)
rcontent=$(printf '%s' "$r" | cut -d'|' -f3); rconf=$(printf '%s' "$r" | cut -d'|' -f4)
same "concurrent: exactly one responder applies its edit" \
     "1" "$( n=0; [ "$ra" = pull ] && n=$((n+1)); [ "$rb" = pull ] && n=$((n+1)); echo $n )"
same "concurrent: the loser raises a conflict rather than overwriting" \
     "1" "$( n=0; [ "$ra" = conflict ] && n=$((n+1)); [ "$rb" = conflict ] && n=$((n+1)); echo $n )"
same "concurrent: the operator is given exactly one thing to resolve" "1" "$rconf"
case $rcontent in EDIT-A|EDIT-B) ok "concurrent: the winner's bytes are on disk intact" ;;
  *) bad "concurrent: the winner's bytes are on disk intact" "got '$rcontent'" ;; esac
refute "concurrent: neither responder reports a silent success" "pull|pull" "$ra|$rb"

# The lock is the thing that makes the above true, and it must not be broken
# while its holder is alive: reclaiming a live holder's lock turns the mutex
# into a delay after which both parties run the critical section at once.
env HOME="$rc/run/home" repo="$repo" sh -c '
  . "$repo/fleet.sh"; . "$repo/fleet-sync.sh"
  sleep 60 & held=$!
  d="$(sync_root)/res.lock/$(sync_res_key live)"
  mkdir -p "$(sync_root)/res.lock"; mkdir "$d"; echo "$held" > "$d/pid"
  # Backdate well past the staleness threshold; a live pid must still hold it.
  touch -t 200001010000 "$d" 2>/dev/null
  if sync_lock_holder_alive "$d"; then echo ALIVE; else echo REAPED; fi
  kill "$held" 2>/dev/null; wait "$held" 2>/dev/null
  if sync_lock_holder_alive "$d"; then echo STILL; else echo DEAD; fi
' > "$rc/liveness" 2>/dev/null
same "concurrent: an aged lock whose holder still runs is not reclaimed" \
     "ALIVE" "$(sed -n 1p "$rc/liveness")"
same "concurrent: a lock whose holder died is reclaimable" \
     "DEAD" "$(sed -n 2p "$rc/liveness")"

# --- 45. the shell completions cover the verbs the usage text documents ----
# A verb that `sync help` / `tools help` advertises but no shell completes is a
# surface that drifts silently. This reads the verbs out of the usage text
# itself, so adding a verb without completing it fails here.
mark "45. completions track the documented verbs"
usage_verbs() {  # usage_verbs sync|tools -> one verb per line
  env HOME="$base/alpha" sh -c '. "$1/fleet.sh"; . "$1/fleet-sync.sh"; '"$1"'_usage' _ "$repo" \
    | sed -n 's/^  \([a-z][a-z]*\).*/\1/p' | sort -u
}
bash_comp() {  # bash_comp <fleet-verb> -> completions offered at word 3
  bash -c 'cd "$1" || exit 1; . ./shell/agents.bash
           COMP_WORDS=(agents fleet "$2" ""); COMP_CWORD=3
           _n2agents_complete; printf "%s\n" "${COMPREPLY[@]}"' _ "$repo" "$1" | sort -u
}
for v in sync tools; do
  want=$(usage_verbs "$v"); got=$(bash_comp "$v")
  # Guard the guard: an empty expectation would pass vacuously.
  if [ -z "$want" ]; then bad "completions: '$v' usage lists verbs" "usage text produced none"; continue; fi
  if [ -z "$got" ]; then bad "completions: bash offers '$v' verbs" "no completions"; continue; fi
  missing=$(printf '%s\n' "$want" | grep -vxF "$got" | tr '\n' ' ')
  same "completions: bash completes every documented '$v' verb" "" "${missing% }"
done
# The fleet-verb list must not leak into the third position, or the operator is
# offered `approve` where only sync verbs are legal.
refute "completions: fleet verbs do not leak into 'sync <verb>'" "approve" "$(bash_comp sync)"
# The check above executes bash's completion function. zsh and fish publish
# their sub-verb lists as literal text instead, and that text was covered only
# by a parse check -- so a verb added to `sync help` but not to those two lists
# drifted silently, the exact failure `route` demonstrated at the fleet level.
# Reading the literal lists holds all three shells to one standard, and does it
# without zsh or fish installed: drift in a list this host cannot execute is
# still drift on the host that can.
zsh_comp() {  # zsh_comp <fleet-verb> -> verbs shell/agents.zsh offers for it
  sed -n "s/^[[:space:]]*$1)[[:space:]]*_values '$1 verb'[[:space:]]*\(.*\);;.*/\1/p" \
    "$repo/shell/agents.zsh" | tr ' ' '\n' | sed '/^$/d' | sort -u
}
fish_comp() {  # fish_comp <fleet-verb> -> verbs shell/agents.fish offers for it
  grep "__fish_seen_subcommand_from $1'" "$repo/shell/agents.fish" \
    | sed -n "s/.*-a '\([^']*\)'.*/\1/p" | tr ' ' '\n' | sed '/^$/d' | sort -u
}
for v in sync tools; do
  want=$(usage_verbs "$v")
  [ -n "$want" ] || continue   # the bash loop above already reported the empty case
  for sname in zsh fish; do
    got=$(${sname}_comp "$v")
    if [ -z "$got" ]; then
      bad "completions: $sname lists '$v' verbs" "read none out of shell/agents.$sname"
      continue
    fi
    missing=$(printf '%s\n' "$want" | grep -vxF "$got" | tr '\n' ' ')
    same "completions: $sname completes every documented '$v' verb" "" "${missing% }"
  done
done
refute "completions: zsh does not offer fleet verbs as sync verbs" "approve" "$(zsh_comp sync)"
refute "completions: fish does not offer fleet verbs as sync verbs" "approve" "$(fish_comp sync)"
# zsh and fish must also parse and define the same entry points.
if command -v zsh >/dev/null 2>&1; then
  if zsh -n "$repo/shell/agents.zsh" 2>/dev/null; then ok "completions: zsh script parses"
  else bad "completions: zsh script parses" "zsh -n failed"; fi
  zf=$(zsh -f -c "source '$repo/shell/agents.zsh' 2>/dev/null; functions _n2agents_cli" 2>/dev/null)
  check "completions: zsh dispatches on the fleet verb" "CURRENT == 4" "$zf"
fi
if command -v fish >/dev/null 2>&1; then
  fs=$(fish -c "source '$repo/shell/agents.fish'; complete -C'agents fleet sync '" 2>/dev/null | tr '\n' ' ')
  check "completions: fish completes a sync verb" "resolve" "$fs"
  refute "completions: fish does not offer fleet verbs there" "approve" "$fs"
fi

# --- 46. an exception added while a conflict is pinned wins --------------
# A pin outlives the scope it was made in. Once an exception covers the
# address, a sync pass skips it, so nothing re-examines the pin -- and taking
# the peer's side would overwrite the very difference the operator just asked
# this machine to keep.
mark "46. a pinned conflict obeys an exception added afterwards"
xa="settings|Xcept|claude|settings.json"
mkdir -p "$(slot beta Xcept claude)"
put alpha "$(slot alpha Xcept claude)/settings.json" '{"v":0}'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
put alpha "$(slot alpha Xcept claude)/settings.json" '{"v":"ALPHA X"}'
put beta  "$(slot beta  Xcept claude)/settings.json" '{"v":"BETA X"}'
peer beta fleet sync now --peer "$A" >/dev/null 2>&1
xcid=$(peer beta fleet sync conflicts | awk -F'\t' -v k="$xa" '$2==k{print $1}' | tail -1)
[ -n "$xcid" ] && ok "except-pin: the divergent edit is pinned on beta" ||
  bad "except-pin: the divergent edit is pinned on beta" "no conflict for $xa"
check "except-pin: while in scope the row says so" "scope:in" \
      "$(peer beta fleet sync conflicts | grep "$xcid")"
# Now the operator declares this machine keeps its own settings.
peer beta fleet sync except add settings Xcept claude 'settings.json' >/dev/null 2>&1
refute "except-pin: the address leaves the sync scope" "$xa" \
       "$(peer beta fleet sync scope 2>&1)"
check "except-pin: the pinned row is marked out of scope" "scope:out" \
      "$(peer beta fleet sync conflicts | grep "$xcid")"
xout=$(peer beta fleet sync resolve "$xcid" --remote 2>&1); xrc=$?
denied "except-pin: taking the peer's side is refused" "$xout" "$xrc"
check  "except-pin: the refusal names the reason" "no longer in this machine's sync scope" "$xout"
check  "except-pin: the refusal points at the escape hatch" "resolve it with --local" "$xout"
same "except-pin: the excepted local copy is untouched" '{"v":"BETA X"}' \
     "$(cat "$(slot beta Xcept claude)/settings.json" 2>/dev/null)"
check "except-pin: the pin survives the refusal" "$xcid" \
      "$(peer beta fleet sync conflicts 2>&1)"
# --local writes nothing, so it clears the pin without contradicting the
# exception -- the operator's way out.
peer beta fleet sync resolve "$xcid" --local >/dev/null 2>&1
same "except-pin: --local keeps this machine's bytes" '{"v":"BETA X"}' \
     "$(cat "$(slot beta Xcept claude)/settings.json" 2>/dev/null)"
refute "except-pin: --local clears the pin" "$xcid" \
       "$(peer beta fleet sync conflicts 2>&1)"
# And the exception still holds: a later pass does not quietly re-import it.
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
same "except-pin: a later pass respects the exception" '{"v":"BETA X"}' \
     "$(cat "$(slot beta Xcept claude)/settings.json" 2>/dev/null)"
xn=$(peer beta fleet sync except list | grep 'Xcept' | cut -d: -f1 | tail -1)
[ -n "$xn" ] && peer beta fleet sync except rm "$xn" >/dev/null 2>&1

# --- 47. a removal verb reports only what it actually removed --------------
# Both removal verbs used to rewrite the file with awk and print success
# unconditionally. Removing an exception is how a resource re-enters sync
# scope and `tools rm` is how install authority is withdrawn, so a removal
# that matched nothing and still said "removed" pointed the operator at
# exactly the wrong belief about the machine.
mark "47. removal verbs report only what they removed"
# Earlier sections legitimately left exceptions on this peer (section 2 adds
# one), and this section asserts on absolute indexes and on an emptied file,
# so it starts from a known-empty list. Draining through the public verb is
# deliberate: it is the same path under test, and it ends where the section
# ends anyway.
while [ "$(peer gamma fleet sync except list | wc -l | tr -d ' ')" != 0 ]; do
  peer gamma fleet sync except rm 1 >/dev/null 2>&1 || break
done
peer gamma fleet sync except add settings Rm1 claude settings.json >/dev/null
peer gamma fleet sync except add skills   Rm2 claude '*'           >/dev/null
xbefore=$(peer gamma fleet sync except list)

o=$(peer gamma fleet sync except rm 99 2>&1); rc=$?
denied "rm: an out-of-range exception number is refused" "$o" "$rc"
check  "rm: the refusal names the list command" "except list" "$o"
o=$(peer gamma fleet sync except rm banana 2>&1); rc=$?
denied "rm: a non-numeric exception index is refused" "$o" "$rc"
check  "rm: the refusal says it wants a line number" "not 'banana'" "$o"
o=$(peer gamma fleet sync except rm 0 2>&1); rc=$?
denied "rm: index 0 is refused" "$o" "$rc"
same "rm: three refusals removed nothing" "$xbefore" \
     "$(peer gamma fleet sync except list)"

# The valid path still works, and renumbers the way `except list` shows.
o=$(peer gamma fleet sync except rm 1 2>&1)
check "rm: a real index is removed" "removed" "$o"
same "rm: the surviving exception moved up" "1:skills|Rm2|claude|*" \
     "$(peer gamma fleet sync except list)"
peer gamma fleet sync except rm 1 >/dev/null 2>&1
o=$(peer gamma fleet sync except rm 1 2>&1); rc=$?
denied "rm: an emptied exception file refuses index 1" "$o" "$rc"
check  "rm: the count in the refusal is one integer" "(0 on this machine)" "$o"

# `fleet sync status` is parsed by the tray and by --porcelain consumers, so a
# counter that printed "0" twice injected an unlabelled record into it.
same "rm: status emits no bare zero line" "0" \
     "$(peer gamma fleet sync status 2>/dev/null | grep -c '^0$')"
same "rm: exceptions is reported exactly once" "1" \
     "$(peer gamma fleet sync status 2>/dev/null | grep -c '^exceptions')"

# Withdrawing install authority: a typo must not report success.
peer gamma fleet tools add rmwidget --version 1.0 --check 'echo 1.0' \
     --install 'true' >/dev/null
o=$(peer gamma fleet tools rm rmwidgt 2>&1); rc=$?
denied "rm: an unmanaged tool name is refused" "$o" "$rc"
check  "rm: the refusal says it is not fleet-managed" "not fleet-managed" "$o"
check  "rm: the real tool is still managed after the refusal" "rmwidget" \
       "$(peer gamma fleet tools list 2>&1)"
o=$(peer gamma fleet tools rm rmwidget 2>&1)
check  "rm: the real tool name is removed" "unmanaged" "$o"
refute "rm: the manifest no longer carries it" "rmwidget" \
       "$(peer gamma fleet tools list 2>&1)"

# An invalid record is still removable: matching is on the name field alone,
# so a bad line cannot become unremovable scenery.
tf="$base/gamma/.n2-agents/fleet/tools/manifest"
printf 'rmghost|||touch /dev/null|\n' >> "$tf"
check "rm: the planted record is visible as invalid" "rmghost" \
      "$(peer gamma fleet tools list 2>&1)"
o=$(peer gamma fleet tools rm rmghost 2>&1)
check  "rm: an invalid record can still be withdrawn" "unmanaged" "$o"
refute "rm: the invalid record is gone" "rmghost" \
       "$(peer gamma fleet tools list 2>&1)"

# --- 48. a conflict id is an id, not a path -------------------------------
# `resolve` ends in `rm -rf "$(sync_conflict_dir)/$id"`, so an id that is
# allowed to contain `/` or `..` is a delete primitive aimed at whatever the
# operator (or a script wrapping the CLI) happened to type. `show` has the same
# shape and would cat a meta file from anywhere on disk. Both must refuse
# anything that is not the 12 hex characters `sync conflicts` prints.
mark "48. conflict ids are validated before they become paths"
vic="$base/delta-victim"
mkdir -p "$base/delta" "$vic"
peer delta fleet init --machine delta >/dev/null 2>&1
printf 'important\n' > "$vic/data.txt"
# a meta file with an addr= line is the only thing the old code looked for
printf 'addr=settings|Work|claude|settings.json\n' > "$vic/meta"
# The traversal has to actually land on the victim, or the test proves nothing:
# derive the hop count from where the conflict store really sits under $base.
peer delta fleet sync status >/dev/null 2>&1
cdir=$(find "$base/delta" -type d -name conflicts 2>/dev/null | head -1)
up=$(printf '%s' "${cdir#$base/}" | awk -F/ '{printf "%d", NF}')
trav=$(awk -v n="$up" 'BEGIN{ s=""; for(i=0;i<n;i++) s=s "../"; printf "%s", s }')delta-victim
[ -d "$cdir/$trav" ] && ok "id: the traversal really reaches the victim directory" ||
  bad "id: the traversal really reaches the victim directory" "cdir=$cdir up=$up trav=$trav"
o=$(peer delta fleet sync resolve "$trav" --local 2>&1); rc=$?
denied "id: a traversal is not accepted as a conflict id" "$o" "$rc"
check  "id: the refusal names the real shape of an id" "not a conflict id" "$o"
same   "id: the directory it aimed at is untouched" "important" \
       "$(cat "$vic/data.txt" 2>/dev/null)"
o=$(peer delta fleet sync show "$trav" 2>&1); rc=$?
denied "id: show refuses a traversal too" "$o" "$rc"
refute "id: show leaked nothing from the foreign meta file" "settings.json" "$o"
for bad_id in . .. ABCDEF123456 abc abcdef1234567 'abcdef12345g' 'ab/cdef12345'; do
  o=$(peer delta fleet sync resolve "$bad_id" --local 2>&1); rc=$?
  denied "id: '$bad_id' is refused" "$o" "$rc"
done
# the gate must not swallow well-formed ids: a real 12-hex id that simply does
# not exist has to fail with the *other* message, or a legitimate id could be
# rejected as malformed and the operator would never find their conflict.
o=$(peer delta fleet sync resolve deadbeefcafe --local 2>&1); rc=$?
denied "id: a well-formed id that does not exist still fails" "$o" "$rc"
check  "id: ...and fails as missing, not as malformed" "no such conflict" "$o"
refute "id: a well-formed id is not called malformed" "not a conflict id" "$o"

# --- 49. an exception that could never match is refused ------------------
mark "49. an exception that could never match is refused, not stored"
# `except add` validated the class and nothing else. A typo in the vendor --
# `clade` for `claude` -- appended a record, printed `excepted` and exited 0,
# while the resource stayed in sync scope and the next pass overwrote this
# machine's copy with the fleet's. That is the exception feature reporting the
# exact opposite of what it did. The gate below refuses only records that are
# inert by construction; a profile that does not exist here yet is still fine.
mkdir -p "$base/epsilon"
peer epsilon fleet init --machine epsilon >/dev/null 2>&1
xf="$base/epsilon/.n2-agents/fleet/sync/exceptions"
put epsilon "$(slot epsilon Work claude)/settings.json" '{"v":"epsilon"}'

# baseline: the resource is in scope with no exception standing
scope0=$(peer epsilon fleet sync scope 2>/dev/null)
check "except: the resource starts in sync scope" "settings|Work|claude|settings.json" "$scope0"

for bad_x in "settings Work clade settings.json" \
             "settings Work CLAUDE settings.json" \
             "settings Work claudex settings.json" \
             "settings . claude settings.json" \
             "settings .. claude settings.json" \
             "settings Work ../x settings.json"; do
  # shellcheck disable=SC2086
  o=$(peer epsilon fleet sync except add $bad_x 2>&1); rc=$?
  denied "except: '$bad_x' is refused" "$o" "$rc"
done
# the record separator and the line separator cannot enter a field: a stored
# record that parses differently from the line echoed back is the same class of
# lie as a typo, just quieter.
o=$(peer epsilon fleet sync except add settings 'a|b' claude 'settings.json' 2>&1); rc=$?
denied "except: a '|' in the profile is refused" "$o" "$rc"
o=$(peer epsilon fleet sync except add settings Work 'cla|ude' 'settings.json' 2>&1); rc=$?
denied "except: a '|' in the vendor is refused" "$o" "$rc"
o=$(peer epsilon fleet sync except add settings Work claude "$(printf 'a\tb')" 2>&1); rc=$?
denied "except: a tab in the glob is refused" "$o" "$rc"

# nothing above may have been written: a refusal that still appends is worse
# than no gate, because `except list` then shows a record nobody accepted.
same "except: no refused record reached the store" "0" "$(awk 'END{print NR+0}' "$xf" 2>/dev/null)"

# the refusals are honest about *why*, so the operator can fix the typo
o=$(peer epsilon fleet sync except add settings Work clade 'settings.json' 2>&1)
check "except: an unknown vendor names the known set" "claude codex grok" "$o"

# --- the gate must not be over-broad ---------------------------------------
# a profile this machine has never seen is legitimate: excepting a profile
# before it arrives from the fleet is exactly what a new machine does.
o=$(peer epsilon fleet sync except add settings NotYetHere claude 'settings.json' 2>&1); rc=$?
same "except: an unknown profile is accepted (it may arrive later)" "0" "$rc"
check "except: ...and is stored as written" "settings|NotYetHere|claude|settings.json" "$o"
o=$(peer epsilon fleet sync except add tools - - manifest 2>&1); rc=$?
same "except: the reserved '-' tools slot is accepted" "0" "$rc"
o=$(peer epsilon fleet sync except add '*' '*' '*' '*' 2>&1); rc=$?
same "except: the all-wildcards exception is accepted" "0" "$rc"
o=$(peer epsilon fleet sync except add skills Work claude 'skills/*' 2>&1); rc=$?
same "except: a glob with a '/' is accepted" "0" "$rc"

# --- and the accepted exception actually holds the resource apart ----------
peer epsilon fleet sync except add settings Work claude 'settings.json' >/dev/null 2>&1
scope1=$(peer epsilon fleet sync scope 2>/dev/null)
refute "except: an accepted exception drops the resource from scope" \
       "settings|Work|claude|settings.json" "$scope1"

# --- 50. `tools apply` reports failure in its exit status ------------------
# `apply` is the batch entry point the tray and any operator script call. It
# printed `failed <tool>` and exited 0, so `agents fleet tools apply || alert`
# never alerted and a fleet drifted while its automation reported success. The
# rule is: any tool that could not reach its designated version is a non-zero
# exit; a deferral is not, because holding disruptive work back while a task
# runs is the agreed behavior succeeding.
mark "50. apply's exit status"
Z="$base/zeta-tools"; mkdir -p "$Z"
mkdir -p "$base/zeta"
peer zeta fleet init --machine zeta >/dev/null 2>&1

peer zeta fleet tools apply >/dev/null 2>&1
same "apply-rc: an empty manifest is a success" "0" "$?"

peer zeta fleet tools add goodtool --version 1.0 \
  --check "cat $Z/good.v 2>/dev/null" --install "echo 1.0 > $Z/good.v" >/dev/null
out=$(peer zeta fleet tools apply 2>&1); rc=$?
check "apply-rc: a tool that installs is reported installed" "install	goodtool" "$out"
same  "apply-rc: and a successful apply exits 0" "0" "$rc"
out=$(peer zeta fleet tools apply 2>&1); rc=$?
same  "apply-rc: a repeated apply with nothing to do exits 0" "0" "$rc"

# an installer that exits 0 without producing the version
peer zeta fleet tools add lyingtool --version 9.9 \
  --check "cat $Z/lying.v 2>/dev/null" --install "echo 1.0 > $Z/lying.v" >/dev/null
out=$(peer zeta fleet tools apply 2>&1); rc=$?
check "apply-rc: the lying installer is still named in the output" "failed	lyingtool" "$out"
denied "apply-rc: and the batch exits non-zero" "$out" "$rc"
check "apply-rc: the healthy tool is still reported ok alongside it" "ok	goodtool" "$out"
peer zeta fleet tools rm lyingtool >/dev/null

# an installer that exits non-zero
peer zeta fleet tools add brokentool --version 1.0 \
  --check "cat $Z/broken.v 2>/dev/null" --install "exit 7" >/dev/null
out=$(peer zeta fleet tools apply 2>&1); rc=$?
denied "apply-rc: a non-zero installer makes the batch non-zero" "$out" "$rc"
peer zeta fleet tools rm brokentool >/dev/null
out=$(peer zeta fleet tools apply 2>&1); rc=$?
same "apply-rc: withdrawing the broken tool restores a zero exit" "0" "$rc"

# a manifest record that can never apply
printf 'ghost|||true|\n' >> "$base/zeta/.n2-agents/fleet/tools/manifest"
out=$(peer zeta fleet tools apply 2>&1); rc=$?
check "apply-rc: an uncheckable record is refused loudly" "invalid	ghost" "$out"
denied "apply-rc: and a record that can never apply is a non-zero batch" "$out" "$rc"
peer zeta fleet tools rm ghost >/dev/null
out=$(peer zeta fleet tools apply 2>&1); rc=$?
same "apply-rc: removing it restores a zero exit" "0" "$rc"

# a deferral is success, not failure
mkdir -p "$base/zeta/.n2-agents/fleet/tasks/active"
: > "$base/zeta/.n2-agents/fleet/tasks/active/t50"
peer zeta fleet tools add bigtool --version 1.0 --disruptive \
  --check "cat $Z/big.v 2>/dev/null" --install "echo 1.0 > $Z/big.v" >/dev/null
out=$(peer zeta fleet tools apply 2>&1); rc=$?
check "apply-rc: the disruptive update is deferred while a task runs" "deferred	bigtool" "$out"
same  "apply-rc: a deferral is NOT a failure" "0" "$rc"
if [ -e "$Z/big.v" ]; then bad "apply-rc: the deferred installer did not run" "it ran"
else ok "apply-rc: the deferred installer did not run"; fi
rm -f "$base/zeta/.n2-agents/fleet/tasks/active/t50"
out=$(peer zeta fleet tools apply 2>&1); rc=$?
check "apply-rc: it applies once the task ends" "install	bigtool" "$out"
same  "apply-rc: and that apply exits 0" "0" "$rc"

# a failing installer must not turn a delivered manifest into a protocol error
peer zeta fleet tools add lyingtool --version 9.9 \
  --check "cat $Z/lying2.v 2>/dev/null" --install "echo 1.0 > $Z/lying2.v" >/dev/null
out=$(peer zeta fleet status 2>&1); rc=$?
same "apply-rc: an unrelated fleet command is unaffected by a failing tool" "0" "$rc"
out=$(peer zeta fleet tools status 2>&1); rc=$?
same "apply-rc: tools status still reports without failing" "0" "$rc"
check "apply-rc: and it names the tool that cannot reach its version" "lyingtool" "$out"

# --- 51. an option may not swallow the next flag as its value ---------------
# `tools add x --check c --install --disruptive` stored an installer literally
# named "--disruptive", printed `managed`, exited 0 — and dropped the flag that
# holds a disruptive update back while a task is running. The operator ends up
# with a tool that can never install and has lost its only safety marker. A
# missing value at the end of the line died with a raw shell diagnostic rather
# than a usage message. A value is required and may not itself be an option.
mark "51. tool option values"
mkdir -p "$base/eta"
peer eta fleet init --machine eta >/dev/null 2>&1

peer eta fleet tools add swallow --check 'true' --install --disruptive >/dev/null 2>&1
denied "optval: --install cannot take the following flag as its value" "--install --disruptive" "$?"
out=$(peer eta fleet tools list 2>&1)
refute "optval: and no half-formed record is stored" "swallow" "$out"

out=$(peer eta fleet tools add swallow --check 'true' --install --disruptive 2>&1)
check "optval: the refusal names the option and the value it got" "--install needs a value" "$out"
refute "optval: and it is not a raw shell diagnostic" "unbound variable" "$out"

peer eta fleet tools add novalue --check 'true' --install >/dev/null 2>&1
denied "optval: a missing value at the end of the line is refused" "--install" "$?"
out=$(peer eta fleet tools add novalue --check 'true' --install 2>&1)
refute "optval: a missing trailing value is a usage error, not a crash" "unbound variable" "$out"
check "optval: and it says which option is short" "--install needs a value" "$out"

peer eta fleet tools add nover --version >/dev/null 2>&1
denied "optval: --version with nothing after it is refused" "--version" "$?"
out=$(peer eta fleet tools add nocheck --check 2>&1)
check "optval: --check reports itself, not another option" "--check needs a value" "$out"

# The gate must not be over-broad: the honest form still works, and the
# disruptive flag survives into the record where the deferral logic reads it.
peer eta fleet tools add real --version 1.0 \
  --check "echo 1.0" --install "true" --disruptive >/dev/null 2>&1
same "optval: the honest form is still accepted" "0" "$?"
out=$(peer eta fleet tools list 2>&1)
check "optval: and the disruptive flag reaches field five" "real|1.0|echo 1.0|true|disruptive" "$out"

# An empty version is a legitimate "any version", not a missing value.
peer eta fleet tools add anyver --version '' --check 'echo x' --install 'true' >/dev/null 2>&1
same "optval: an explicitly empty version is not a missing value" "0" "$?"
out=$(peer eta fleet tools add anyver2 --version '' --check 'echo x' --install 'true' 2>&1)
check "optval: and it reports as any" "anyver2	any" "$out"

# A value that merely contains a dash, or is a command with flags inside a
# quoted string, is ordinary and must pass.
peer eta fleet tools add dashy --version 2.0-rc1 \
  --check 'printf %s 2.0-rc1' --install 'sh -c "true --flag"' >/dev/null 2>&1
same "optval: a dashed version and a flag inside a quoted command are fine" "0" "$?"

# An unknown option is still an unknown option, not a value.
out=$(peer eta fleet tools add bogus --check 'true' --install 'true' --nope 2>&1)
check "optval: an unknown option is still refused by name" "unknown option: --nope" "$out"


# --- 52. a sync option may not swallow the next flag as its value ---------
mark "52. sync option values"
# Same defect family as section 51, on the other half of the command surface.
# `cmd_fleet_sync` read every option value as a bare $2: a missing trailing
# value died with a raw `$2: unbound variable`, and an option written without
# its value ate the NEXT option. Worst of the set: `tick --interval abc`
# exited 0, because sync_tick quietly substituted the default for a value it
# could not parse -- so a wrapper or timer asking for a cadence was told the
# cadence was in force when it was not. `auto` and `service install` both
# rejected the same input, which is what marks the tick path as an oversight.
mkdir -p "$base/theta"
peer theta fleet init --machine theta >/dev/null 2>&1

# The false success: a garbage interval is no longer silently defaulted.
peer theta fleet sync tick --interval abc >/dev/null 2>&1
denied "syncopt: a non-numeric interval is refused, not defaulted" "tick --interval abc" "$?"
out=$(peer theta fleet sync tick --interval abc 2>&1)
check "syncopt: and the refusal shows the value it rejected" "not: abc" "$out"
# A unit suffix is the realistic typo, and it used to pass.
peer theta fleet sync tick --interval 300s >/dev/null 2>&1
denied "syncopt: a unit suffix is refused too" "tick --interval 300s" "$?"

# An option must not swallow the option that follows it.
out=$(peer theta fleet sync now --peer --dry-run 2>&1)
check "syncopt: --peer does not swallow --dry-run" "--peer needs a value, but got the option --dry-run" "$out"
peer theta fleet sync now --peer --dry-run >/dev/null 2>&1
denied "syncopt: and that form is refused" "now --peer --dry-run" "$?"
# This one used to blame the bare '1', an argument the operator wrote correctly.
out=$(peer theta fleet sync auto --interval --rounds 1 2>&1)
check "syncopt: --interval does not swallow --rounds" "--interval needs a value, but got the option --rounds" "$out"
refute "syncopt: and it no longer blames the innocent argument" "unknown option: 1" "$out"

# A missing trailing value reports the option instead of a shell diagnostic.
out=$(peer theta fleet sync tick --interval 2>&1)
check "syncopt: a missing tick interval names the option" "--interval needs a value" "$out"
refute "syncopt: and leaks no unbound-variable diagnostic" "unbound variable" "$out"
out=$(peer theta fleet sync now --dry-run --peer 2>&1)
check "syncopt: a missing peer names the option" "--peer needs a value" "$out"
refute "syncopt: and leaks no unbound-variable diagnostic either" "unbound variable" "$out"
out=$(peer theta fleet sync service install --interval 2>&1)
check "syncopt: a missing service interval names the option" "--interval needs a value" "$out"

# Over-broadness guards: every legitimate form still works.
peer theta fleet sync tick --interval 300 >/dev/null 2>&1
same "syncopt: an honest interval is still accepted" "0" "$?"
peer theta fleet sync now --dry-run >/dev/null 2>&1
same "syncopt: a bare --dry-run still needs no value" "0" "$?"
peer theta fleet sync auto --interval 30 --rounds 1 >/dev/null 2>&1
same "syncopt: interval and rounds together still run" "0" "$?"
out=$(peer theta fleet sync now --nope 2>&1)
check "syncopt: an unknown option is still refused by name" "unknown option: --nope" "$out"

# --- 53. a credential is a credential wherever it is written ---------------
mark "53. header-style credentials obey the auth opt-in"
# A remote MCP server authenticates with an HTTP header, not an environment
# variable. `{"headers":{"Authorization":"Bearer <token>"}}` carries none of the
# vendor key names the detector knew, so the file replicated byte-for-byte with
# auth sharing explicitly OFF on both machines: the operator refused to share
# credentials and shared one anyway. Every credential in this section is a
# synthetic string invented here.
mkdir -p "$base/iota" "$base/kappa"
I=$(peer iota  fleet init --machine iota  | awk '{print $2}')
K=$(peer kappa fleet init --machine kappa | awk '{print $2}')
peer kappa fleet pair --home "$base/iota" \
  --code "$(peer iota fleet invite --peer "$K" 2>/dev/null)" >/dev/null 2>&1
peer iota   new Work >/dev/null 2>&1
idir=$(slot iota Work claude); kdir=$(slot kappa Work claude)

put x "$idir/.mcp.json" '{"mcpServers":{"r":{"url":"https://e/x","headers":{"Authorization":"Bearer SYNTHETIC-HDR-001"}}}}'
out=$(peer iota fleet sync now --peer "$K" 2>&1)
refute "hdr: an Authorization header is not offered while auth sharing is off" "mcp|Work|claude" "$out"
if [ -f "$kdir/.mcp.json" ]; then
  bad "hdr: the bearer token must not reach the peer" "file present at $kdir/.mcp.json"
else
  ok "hdr: the bearer token must not reach the peer"
fi
out=$(peer iota fleet sync status 2>&1)
refute "hdr: and the withheld token is not named in status either" "SYNTHETIC-HDR-001" "$out"

# Withholding is the opt-in, not a blanket ban: the same file shares once the
# operator opts the vendor in on both sides.
peer iota  fleet sync auth enable claude >/dev/null 2>&1
peer kappa fleet sync auth enable claude >/dev/null 2>&1
peer iota fleet sync now --peer "$K" >/dev/null 2>&1
if [ -f "$kdir/.mcp.json" ] && grep -q 'SYNTHETIC-HDR-001' "$kdir/.mcp.json" 2>/dev/null; then
  ok "hdr: opting the vendor in does share it"
else
  bad "hdr: opting the vendor in does share it" "not replicated after opt-in"
fi
peer iota  fleet sync auth disable claude >/dev/null 2>&1
peer kappa fleet sync auth disable claude >/dev/null 2>&1

# Over-broadness: the gate must catch credentials, not paralyse ordinary config.
mkdir -p "$base/lambda" "$base/mu"
L=$(peer lambda fleet init --machine lambda | awk '{print $2}')
M=$(peer mu     fleet init --machine mu     | awk '{print $2}')
peer mu fleet pair --home "$base/lambda" \
  --code "$(peer lambda fleet invite --peer "$M" 2>/dev/null)" >/dev/null 2>&1
peer lambda new Work >/dev/null 2>&1
ldir=$(slot lambda Work claude); mdir=$(slot mu Work claude)
# The `mcp` class needs the vendor opt-in before anything in it moves, so opt
# both sides in here: what is under test is the credential scanner's
# over-broadness, not the class gate that section 1 already covers.
peer lambda fleet sync auth enable claude >/dev/null 2>&1
peer mu     fleet sync auth enable claude >/dev/null 2>&1
put x "$ldir/.mcp.json" '{"mcpServers":{"local":{"command":"node","args":["s.js"]}}}'
# Lookalikes chosen because they contain the key names as substrings: the match
# is anchored on the assignment, so neither is a credential.
put x "$ldir/settings.json" '{"authorizationRequired":true,"env":{"CLAUDE_CODE_MAX_OUTPUT_TOKENS":"8192"}}'
peer lambda fleet sync now --peer "$M" >/dev/null 2>&1
if [ -f "$mdir/.mcp.json" ]; then ok "hdr: a credential-free mcp config still replicates"
else bad "hdr: a credential-free mcp config still replicates" "withheld"; fi
if [ -f "$mdir/settings.json" ]; then ok "hdr: authorizationRequired is not an Authorization header"
else bad "hdr: authorizationRequired is not an Authorization header" "withheld"; fi

# Opt back out, and the header spellings are each refused again -- once by the
# class gate, and (section 53's first block) by the scanner when opted in.
peer lambda fleet sync auth disable claude >/dev/null 2>&1
peer mu     fleet sync auth disable claude >/dev/null 2>&1

# The other header spellings, each against a fresh file on the same pair.
for hk in 'X-Api-Key' 'authorization' 'X-Auth-Token'; do
  put x "$ldir/.mcp.json" "{\"mcpServers\":{\"r\":{\"url\":\"https://e/x\",\"headers\":{\"$hk\":\"SYNTHETIC-HDR-002\"}}}}"
  peer lambda fleet sync now --peer "$M" >/dev/null 2>&1
  if grep -q 'SYNTHETIC-HDR-002' "$mdir/.mcp.json" 2>/dev/null; then
    bad "hdr: $hk is credential material too" "replicated with auth sharing off"
  else
    ok "hdr: $hk is credential material too"
  fi
done

# --- 54. a profile is a thing in its own right -----------------------------
# The manifest used to speak only about files, so a profile had no existence
# record: an empty one replicated nothing, and deleting one read as "no files
# changed" and left the directory on every receiver.
mark "54. profile lifecycle replicates"
# Section-local peers: removed first so the section is re-enterable against a
# fixture an earlier bounded run left behind, the way the preamble is. Without
# this a second run reads the already-converged state as "noop" instead of
# "pushed" and inherits the exception this section sets on Keeper.
rm -rf "$base/nu" "$base/xi"
mkdir -p "$base/nu" "$base/xi"
N=$(peer nu fleet init --machine nu | awk '{print $2}')
X=$(peer xi fleet init --machine xi | awk '{print $2}')
peer xi fleet pair --home "$base/nu" \
  --code "$(peer nu fleet invite --peer "$X" 2>/dev/null)" >/dev/null 2>&1

# This machine's own fleet state lives under the profile root and turns up in
# all_profiles. Advertising it would hand one machine's identity and roster to
# every peer, and its tombstone would delete the receiver's fleet state.
sc=$(peer nu fleet sync scope)
refute "profile: fleet state is not a profile" "profile|fleet" "$sc"
refute "profile: Default is never addressed"   "profile|Default" "$sc"

mkdir -p "$base/nu/.n2-agents/Empty"
sc=$(peer nu fleet sync scope)
check "profile: an empty profile is addressable" "profile|Empty|-|.n2-profile" "$sc"
out=$(peer nu fleet sync now --peer "$X" 2>&1)
check "profile: the empty profile is pushed" "pushed	profile|Empty|-|.n2-profile" "$out"
if [ -d "$base/xi/.n2-agents/Empty" ]; then ok "profile: the receiver has the directory"
else bad "profile: the receiver has the directory" "absent on xi"; fi
check "profile: the receiver lists it" "Empty" "$(peer xi profiles 2>&1)"

# A populated profile: deleting it takes the vendor slots with it, not just the
# marker, or the directory stays behind and the profile is still listed.
put x "$(slot nu Team claude)/skills/t/SKILL.md" 'team skill'
peer nu fleet sync now --peer "$X" >/dev/null 2>&1
same "profile: the populated profile replicated" "team skill" \
     "$(cat "$(slot xi Team claude)/skills/t/SKILL.md" 2>/dev/null)"
rm -rf "$base/nu/.n2-agents/Team"
out=$(peer nu fleet sync now --peer "$X" 2>&1)
check "profile: the deletion is pushed" "pushed	profile|Team|-|.n2-profile" "$out"
if [ -e "$base/xi/.n2-agents/Team" ]; then
  bad "profile: the receiver removed the whole profile" "$base/xi/.n2-agents/Team still exists"
else ok "profile: the receiver removed the whole profile"; fi
refute "profile: and no longer lists it" "Team" "$(peer xi profiles 2>&1)"

# A profile that is live for a vendor here is not torn out from under a running
# agent: the local CLI refuses the same deletion, and sync reports the failure
# rather than converging on a lie.
mkdir -p "$base/xi/.n2-agents/Live/claude" "$base/nu/.n2-agents/Live/claude"
ln -sfn "$base/xi/.n2-agents/Live/claude" "$base/xi/.claude"
peer nu fleet sync now --peer "$X" >/dev/null 2>&1
rm -rf "$base/nu/.n2-agents/Live"
out=$(peer nu fleet sync now --peer "$X" 2>&1)
if [ -d "$base/xi/.n2-agents/Live" ]; then ok "profile: an active profile is not deleted under the agent"
else bad "profile: an active profile is not deleted under the agent" "removed while active"; fi
refute "profile: and the refusal is not reported as convergence" "converged	profile|Live" "$out"
rm -f "$base/xi/.claude"

# An adopted profile is a symlink to storage outside the fleet's root. The link
# is this machine's local decision about where the contents live, so a deletion
# removes the link and leaves the adopted target alone.
mkdir -p "$base/xi/adopted/Kept/claude"
printf 'adopted bytes' > "$base/xi/adopted/Kept/claude/settings.json"
mkdir -p "$base/nu/.n2-agents/Kept/claude"
peer nu fleet sync now --peer "$X" >/dev/null 2>&1
rm -rf "$base/xi/.n2-agents/Kept"
ln -sfn "$base/xi/adopted/Kept" "$base/xi/.n2-agents/Kept"
rm -rf "$base/nu/.n2-agents/Kept"
peer nu fleet sync now --peer "$X" >/dev/null 2>&1
if [ -L "$base/xi/.n2-agents/Kept" ] || [ -d "$base/xi/.n2-agents/Kept" ]; then
  bad "profile: an adopted profile's link is removed" "link still present"
else ok "profile: an adopted profile's link is removed"; fi
same "profile: the adopted target survives" "adopted bytes" \
     "$(cat "$base/xi/adopted/Kept/claude/settings.json" 2>/dev/null)"

# Negative control with a hostile sender. The existence record is a delete
# primitive, so the receiver may not take the sender's word for what counts as
# a profile. `fleet send` puts a real signed sync-put on the wire, so these are
# genuine offers from an approved peer -- exactly the case where the receiver's
# own gate is the only thing standing between a peer and the fleet state.
xifleet="$base/xi/.n2-agents/fleet"
if [ -d "$xifleet" ]; then ok "profile: the receiver's fleet state exists to begin with"
else bad "profile: the receiver's fleet state exists to begin with" "no $xifleet"; fi
mkdir -p "$base/nu/.n2-agents/Keeper/claude"
peer nu fleet sync now --peer "$X" >/dev/null 2>&1
for badp in fleet Default .. 'x/..' '.n2-agents'; do
  printf 'addr=profile|%s|-|.n2-profile\ndigest=-\nbase=\n--\n' "$badp" > "$base/put.msg"
  o=$(peer nu fleet send "$X" --verb sync-put --payload-file "$base/put.msg" 2>&1); rc=$?
  if [ "$rc" = 0 ] && [ "${o#*ERR}" = "$o" ]; then
    bad "profile: a tombstone for '$badp' is refused by the receiver" "accepted: $o"
  else ok "profile: a tombstone for '$badp' is refused by the receiver"; fi
done
if [ -d "$xifleet" ]; then ok "profile: the receiver's fleet state survives the offers"
else bad "profile: the receiver's fleet state survives the offers" "$xifleet destroyed"; fi
if [ -d "$base/xi/.n2-agents" ]; then ok "profile: the receiver's profile root survives"
else bad "profile: the receiver's profile root survives" "root destroyed"; fi
# The gate is a gate, not a wall: the same verb, same peer, same shape, with a
# real profile name is accepted -- so the refusals above are about the name.
if [ -d "$base/xi/.n2-agents/Keeper" ]; then ok "profile: a real profile name did arrive over the same path"
else bad "profile: a real profile name did arrive over the same path" "Keeper absent on xi"; fi
printf 'addr=profile|Keeper|-|.n2-profile\ndigest=-\nbase=\n--\n' > "$base/put.msg"
peer nu fleet send "$X" --verb sync-put --payload-file "$base/put.msg" >/dev/null 2>&1
if [ -e "$base/xi/.n2-agents/Keeper" ]; then
  bad "profile: and a tombstone for it is honoured" "Keeper still on xi"
else ok "profile: and a tombstone for it is honoured"; fi

# --- 55. help answers before the identity check --------------------------
mark "55. tools help answers before the identity check"
# An operator reads the help of a verb *because* the machine is not set up yet.
# `fleet tools` used to run sync_need first, so every invocation on a machine
# without an identity -- including --help and a typo -- died with "no fleet
# identity yet" instead of its usage. `fleet sync` never had this bug.
mkdir -p "$base/omicron"
if HOME="$base/omicron" "$repo/agents" fleet tools --help 2>&1 | grep -q 'agents fleet tools <verb>'; then
  ok "toolshelp: --help prints usage without an identity"
else bad "toolshelp: --help prints usage without an identity" "no usage"; fi
HOME="$base/omicron" "$repo/agents" fleet tools --help >/dev/null 2>&1
if [ $? -eq 0 ]; then ok "toolshelp: and exits 0"
else bad "toolshelp: and exits 0" "nonzero"; fi
out=$(HOME="$base/omicron" "$repo/agents" fleet tools bogus 2>&1); rc=$?
case "$out" in *'agents fleet tools <verb>'*)
  ok "toolshelp: a mistyped verb still shows the verb list" ;;
  *) bad "toolshelp: a mistyped verb still shows the verb list" "$out" ;; esac
if [ "$rc" -ne 0 ]; then ok "toolshelp: and a mistyped verb is an error"
else bad "toolshelp: and a mistyped verb is an error" "exit 0"; fi
# The identity check is moved, not removed: a real verb still refuses.
out=$(HOME="$base/omicron" "$repo/agents" fleet tools list 2>&1); rc=$?
case "$out" in *'no fleet identity'*) ok "toolshelp: a real verb still requires an identity" ;;
  *) bad "toolshelp: a real verb still requires an identity" "$out" ;; esac
[ "$rc" -ne 0 ] && ok "toolshelp: and says so with a nonzero exit" ||
  bad "toolshelp: and says so with a nonzero exit" "exit 0"


# --- 56. an auth opt-in names a vendor that exists ------------------------
mark "56. an auth opt-in for a vendor that does not exist"
# sync_auth_support answers `unverified` for anything it has not inspected, and
# a typo is indistinguishable from an uninspected provider. So `auth enable
# clade` used to exit 0, append `clade` to the opt-in file and print
# `auth-optin clade unverified`. `auth list` iterates $N2_VENDORS, so the line
# never showed up again: the operator read "enabled" for a provider whose auth
# was in fact still not shared. The revoking direction is the dangerous one --
# `auth disable clade` reported `auth-optout clade` while claude stayed opted
# in and kept replicating credential material.
mkdir -p "$base/pi"
peer pi fleet init --machine pi >/dev/null 2>&1
optin="$base/pi/.n2-agents/fleet/sync/auth-optin"
out=$(peer pi fleet sync auth enable clade 2>&1); rc=$?
denied "authname: enabling a misspelt vendor is refused" "$out" "$rc"
# the vendor list is read out of the CLI, not hardcoded here, so this stays
# true if a vendor is added
vlist=$(peer pi fleet sync auth list | cut -f1 | tr '\n' ' ')
for v in $vlist; do
  case "$out" in *"$v"*) ;; *) bad "authname: the message lists $v" "$out"; vmiss=1 ;; esac
done
[ -z "${vmiss:-}" ] && ok "authname: and the message lists every real vendor" || vmiss=
if [ -s "$optin" ]; then bad "authname: nothing was written to the opt-in file" "$(cat "$optin")"
else ok "authname: nothing was written to the opt-in file"; fi
# The gate is a gate, not a wall: a real, partially-portable vendor still opts in.
out=$(peer pi fleet sync auth enable codex 2>&1)
check "authname: a real vendor still opts in" "auth-optin	codex	partial" "$out"
same  "authname: and auth list shows it opted in" "opted-in" \
      "$(peer pi fleet sync auth list | awk -F'	' '$1=="codex"{print $3}')"
# The revoking direction must not report success it did not perform.
out=$(peer pi fleet sync auth disable codxe 2>&1); rc=$?
denied "authname: disabling a misspelt vendor is refused" "$out" "$rc"
same  "authname: and the real vendor is still opted in" "opted-in" \
      "$(peer pi fleet sync auth list | awk -F'	' '$1=="codex"{print $3}')"
out=$(peer pi fleet sync auth disable codex 2>&1)
check "authname: the correctly spelt vendor does opt out" "auth-optout	codex" "$out"
same  "authname: and auth list agrees" "off" \
      "$(peer pi fleet sync auth list | awk -F'	' '$1=="codex"{print $3}')"
# An unsupported provider is still refused for its own reason, not this one.
out=$(peer pi fleet sync auth enable opencode 2>&1); rc=$?
denied "authname: an unsupported vendor is still refused" "$out" "$rc"
check  "authname: and for its own documented reason" "cannot be replicated" "$out"

# --- 57. a grant that could not be stored is not a grant ------------------
mark "57. a grant that could not be stored is not reported as a grant"
# `tools add` is how the operator grants install authority. The dedupe rewrite
# and the append were both unchecked, so a manifest that could not be written
# printed `managed <tool>` and exited 0 with nothing on disk -- a tool the
# operator believes is fleet-managed that no later pass will ever install.
peer rho fleet init --machine rho >/dev/null 2>&1
rman="$base/rho/.n2-agents/fleet/tools/manifest"
out=$(peer rho fleet tools add good --version 1 --check 'echo 1' --install 'true' 2>&1)
check "toolstore: a normal grant is stored" "managed	good	1" "$out"
chmod a-w "$(dirname "$rman")" "$rman" 2>/dev/null
out=$(peer rho fleet tools add bad --version 2 --check 'echo 2' --install 'true' 2>&1); rc=$?
denied "toolstore: a grant that cannot be written is refused" "$out" "$rc"
check  "toolstore: and says the tool is not managed" "is not managed" "$out"
chmod -R u+w "$base/rho" 2>/dev/null
refute "toolstore: the unstored tool is absent from the manifest" "bad" \
       "$(peer rho fleet tools list)"
refute "toolstore: and absent from status, so no pass will install it" "bad" \
       "$(peer rho fleet tools status)"
same   "toolstore: the earlier real grant survived the failure" "ok" \
       "$(peer rho fleet tools status | awk -F'	' '$1=="good"{print $2}')"
# The guard is a guard, not a wall: once writable, the same grant lands.
out=$(peer rho fleet tools add bad --version 2 --check 'echo 2' --install 'true' 2>&1)
check "toolstore: the same grant lands once the manifest is writable" "managed	bad	2" "$out"
# and replacing an existing record still replaces rather than duplicates
peer rho fleet tools add good --version 9 --check 'echo 9' --install 'true' >/dev/null 2>&1
same "toolstore: re-adding replaces the record rather than duplicating it" "1" \
     "$(peer rho fleet tools list | awk -F'|' '$1=="good"' | grep -c .)"
same "toolstore: with the new version" "9" \
     "$(peer rho fleet tools list | awk -F'|' '$1=="good"{print $2}')"
# and withdrawal still works on a record added through the guarded path
out=$(peer rho fleet tools rm bad 2>&1)
check  "toolstore: withdrawal still works" "unmanaged	bad" "$out"
refute "toolstore: and the withdrawn tool is gone" "bad" "$(peer rho fleet tools list)"

# --- 58. a conflict that could not be cleared is not resolved -------------
mark "58. a conflict that could not be cleared is not reported as resolved"
# Resolution ended with an unchecked `rm -rf` on the pin directory. Two things
# went wrong when that rm could not unlink the directory: the command still
# printed `resolved` and exited 0 having already written the peer's bytes and
# advanced the base, and the rm deleted the *contents* it could reach -- so the
# pin survived without its meta, no longer carrying an address, and no later
# `resolve` could ever settle it. Sync for that address was then stuck forever.
peer sig fleet init --machine sig >/dev/null 2>&1
sigc="$base/sig/.n2-agents/fleet/sync/conflicts"
mkdir -p "$sigc/abcdef012345"
printf 'addr=profile|work|claude|settings.json\n' > "$sigc/abcdef012345/meta"
same "resolveclear: the pin is listed before the attempt" "abcdef012345" \
     "$(peer sig fleet sync conflicts | awk -F'	' '{print $1}')"
chmod a-w "$sigc" 2>/dev/null
out=$(peer sig fleet sync resolve abcdef012345 --local 2>&1); rc=$?
denied "resolveclear: a resolution that cannot clear the pin is refused" "$out" "$rc"
check  "resolveclear: and says the conflict is not resolved" "is not resolved" "$out"
refute "resolveclear: it does not claim the conflict was resolved" "resolved	abcdef012345	local" "$out"
chmod -R u+w "$base/sig" 2>/dev/null
# The refusal must leave the pin whole -- this is the part the old partial rm
# destroyed. An address-less pin is unresolvable by any later command.
same "resolveclear: the pin survives the refusal" "abcdef012345" \
     "$(peer sig fleet sync conflicts | awk -F'	' '{print $1}')"
same "resolveclear: and still carries its address, so it stays resolvable" \
     "profile|work|claude|settings.json" \
     "$(peer sig fleet sync conflicts | awk -F'	' '{print $2}')"
# A guard, not a wall: the same resolution lands once the directory is writable.
out=$(peer sig fleet sync resolve abcdef012345 --local 2>&1)
check "resolveclear: the same resolution lands once writable" "resolved	abcdef012345" "$out"
same  "resolveclear: and the pin is gone" "" "$(peer sig fleet sync conflicts)"
# Staging is dot-prefixed so it is invisible to the conflicts view; it must not
# be left behind either.
same "resolveclear: no staging residue is left in the conflicts directory" "" \
     "$(ls -A "$sigc" 2>/dev/null)"

# --- 59. an interrupted resolution leaves the pin, not a hidden orphan ----
mark "59. an interrupted resolution leaves the pin, not a hidden orphan"
# Staging renames the pin to `.resolving-<id>.<pid>` before the caller commits.
# Kill the process in that window and the pin is neither resolved nor listed:
# both read paths skip dot-prefixed names, so the operator's open conflict
# silently stops being asked about and the bytes become unnameable litter.
# Section 58 built the `sig` peer and named its conflict store; re-derive both
# here so a resumed run that starts at this section is not missing them.
[ -d "$base/sig/.n2-agents/fleet" ] || peer sig fleet init --machine sig >/dev/null 2>&1
sigc="$base/sig/.n2-agents/fleet/sync/conflicts"
# A dead pid, taken from a subshell that has already exited.
deadpid=$(sh -c 'echo $$')
if ps -p "$deadpid" >/dev/null 2>&1; then
  bad "recover: could not obtain a dead pid for the test" "pid $deadpid still alive"
else
  # (a) owner gone, id free -> the pin comes back exactly as it was.
  rm -rf "$sigc"; mkdir -p "$sigc/.resolving-abcdef012345.$deadpid"
  printf 'addr=profile|work|claude|settings.json\npeer=ghost\n' \
    > "$sigc/.resolving-abcdef012345.$deadpid/meta"
  same "recover: the interrupted pin is listed again" "abcdef012345" \
       "$(peer sig fleet sync conflicts | awk -F'\t' '{print $1}')"
  same "recover: and still carries its address, so it stays resolvable" \
       "profile|work|claude|settings.json" \
       "$(peer sig fleet sync conflicts | awk -F'\t' '{print $2}')"
  same "recover: no orphan is left behind" "" \
       "$(ls -A "$sigc" 2>/dev/null | grep '^\.resolving-' || true)"
  # It is a real pin again, not just a listing: it can be resolved.
  out=$(peer sig fleet sync resolve abcdef012345 --local 2>&1)
  check "recover: the recovered pin can actually be resolved" "resolved	abcdef012345" "$out"
  same  "recover: and the conflict store is empty afterwards" "" "$(ls -A "$sigc" 2>/dev/null)"

  # (b) owner gone, but a later pass already re-pinned the same id. Two
  # directories cannot both be the pin; the live one wins and the orphan goes.
  rm -rf "$sigc"; mkdir -p "$sigc/abcdef012345" "$sigc/.resolving-abcdef012345.$deadpid"
  printf 'addr=profile|work|claude|settings.json\npeer=live\n' > "$sigc/abcdef012345/meta"
  printf 'addr=profile|work|claude|settings.json\npeer=ghost\n' \
    > "$sigc/.resolving-abcdef012345.$deadpid/meta"
  same "recover: the re-detected pin is the one that survives" "live" \
       "$(peer sig fleet sync conflicts | awk -F'\t' '{print $3}')"
  same "recover: the superseded orphan is discarded" "" \
       "$(ls -A "$sigc" 2>/dev/null | grep '^\.resolving-' || true)"
  same "recover: exactly one pin remains" "1" \
       "$(peer sig fleet sync conflicts | grep -c .)"

  # (c) owner still running -- a resolution in progress on another process is
  # wreckage to nobody. Recovery must not race it by stealing the directory.
  rm -rf "$sigc"; mkdir -p "$sigc/.resolving-abcdef012345.$$"
  printf 'addr=profile|work|claude|settings.json\npeer=busy\n' \
    > "$sigc/.resolving-abcdef012345.$$/meta"
  same "recover: a live resolution is left strictly alone" "" \
       "$(peer sig fleet sync conflicts)"
  same "recover: its staged directory is untouched" "1" \
       "$(ls -A "$sigc" 2>/dev/null | grep -c "^\.resolving-abcdef012345\.$$\$")"

  # (d) a dot-prefixed name that is not a staged pin is not a path to act on.
  rm -rf "$sigc"; mkdir -p "$sigc/.resolving-..%2f..%2fetc.$deadpid" "$sigc/.resolving-nothex.$deadpid"
  peer sig fleet sync conflicts >/dev/null 2>&1
  same "recover: a non-id staging name is never restored" "2" \
       "$(ls -A "$sigc" 2>/dev/null | grep -c '^\.resolving-')"
  rm -rf "$sigc"
fi

# --- 60. a task record whose owner died never applies again ---------------
mark "60. an abandoned task record stops deferring forever"
# `--disruptive` updates are held back while `tasks/active` is non-empty. A
# worker killed mid-task leaves its record behind, so every disruptive update
# defers forever while the operator keeps reading "retried on the next apply".
# Reaping is deliberately one-sided: only a record that names a *dead* owner is
# reaped; a record that names nobody is still active work.
tad="$base/alpha/.n2-agents/fleet/tasks/active"
tdeadpid=$(sh -c 'echo $$')
if ps -p "$tdeadpid" >/dev/null 2>&1; then
  bad "stale-task: could not obtain a dead pid for the test" "pid $tdeadpid alive"
else
  rm -rf "$tad"; mkdir -p "$tad"
  rm -f "$T/staletool.version"
  peer alpha fleet tools add staletool --version 1.0 --disruptive \
    --check "cat $T/staletool.version 2>/dev/null" \
    --install "sh $T/install.sh $T/staletool 1.0" >/dev/null

  # (a) a live owner still defers: reaping must not become a licence to
  #     interrupt real work.
  printf 'pid %s\n' "$$" > "$tad/live-task"
  out=$(peer alpha fleet tools apply)
  check "stale-task: a live owner still defers the disruptive update" \
        "deferred	staletool" "$out"
  if [ -e "$T/staletool.version" ]; then
    bad "stale-task: live work was not interrupted" "installed against a live task"
  else ok "stale-task: live work was not interrupted"; fi
  same "stale-task: the live record is left in place" "1" \
       "$(ls -1 "$tad" 2>/dev/null | grep -c '^live-task$')"

  # (b) a record that declares no owner is still active: liveness we cannot
  #     prove is never permission to interrupt.
  rm -f "$tad/live-task"; : > "$tad/anonymous-task"
  out=$(peer alpha fleet tools apply)
  check "stale-task: a record with no declared owner is still active" \
        "deferred	staletool" "$out"
  same "stale-task: and it is not reaped" "1" \
       "$(ls -1 "$tad" 2>/dev/null | grep -c '^anonymous-task$')"

  # (c) the real defect: owner provably gone -> the deferred update applies.
  rm -f "$tad/anonymous-task"
  printf 'pid %s\nagent claude\n' "$tdeadpid" > "$tad/abandoned-task"
  out=$(peer alpha fleet tools apply)
  check "stale-task: an abandoned record does not defer the update forever" \
        "install	staletool" "$out"
  same "stale-task: the deferred tool actually reached its version" "1.0" \
       "$(cat "$T/staletool.version" 2>/dev/null)"
  same "stale-task: nothing is left deferred" "" \
       "$(peer alpha fleet tools deferred)"
  same "stale-task: the abandoned record leaves the active count" "0" \
       "$(ls -1 "$tad" 2>/dev/null | grep -c .)"
  # the bytes survive for reconciliation rather than being deleted
  same "stale-task: the reaped record is kept, not destroyed" "1" \
       "$(ls -A "$tad" 2>/dev/null | grep -c '^\.stale-abandoned-task$')"
  check "stale-task: the reap is journalled" "task-record-stale" \
        "$(grep task-record-stale "$base/alpha/.n2-agents/fleet/events.log" 2>/dev/null | tail -1)"
  peer alpha fleet tools rm staletool >/dev/null 2>&1
  rm -rf "$tad"
fi

# --- 61. withdrawing a tool grant withdraws its pending update -----------
mark "61. withdrawing a tool grant withdraws its pending update"
# `tools install` appends to the deferred list; only `tools apply` rebuilds it.
# So on a machine whose tick is not running, `tools rm` left the record behind:
# `tools deferred` kept naming a tool that is no longer managed, and the tick
# kept printing a retry count for an update `apply` will never perform, because
# `apply` only walks the manifest. The grant and its pending update go together.
tad61="$base/alpha/.n2-agents/fleet/tasks/active"
rm -rf "$tad61"; mkdir -p "$tad61"
rm -f "$T/revtool.version"
peer alpha fleet tools add revtool --version 1.0 --disruptive \
  --check "cat $T/revtool.version 2>/dev/null" \
  --install "sh $T/install.sh $T/revtool 1.0" >/dev/null
printf 'pid %s\n' "$$" > "$tad61/live-task"

# the single-tool path is the one that appends without rebuilding
out=$(peer alpha fleet tools install revtool)
check "grant-rm: a disruptive install defers while a task runs" \
      "deferred	revtool" "$out"
check "grant-rm: the deferred list names it" "revtool" \
      "$(peer alpha fleet tools deferred)"
if [ -e "$T/revtool.version" ]; then
  bad "grant-rm: the deferral did not interrupt the task" "installed anyway"
else ok "grant-rm: the deferral did not interrupt the task"; fi

# withdraw the authorization while the task is still running, so nothing else
# gets a chance to rebuild the file
out=$(peer alpha fleet tools rm revtool)
check "grant-rm: the grant is withdrawn" "unmanaged	revtool" "$out"
same "grant-rm: the pending update is withdrawn with the grant" "" \
     "$(peer alpha fleet tools deferred)"
same "grant-rm: and the tool really is off the manifest" "0" \
     "$(peer alpha fleet tools list | grep -c '^revtool|')"

# an unrelated deferral must survive the removal: `rm` drops one record, not
# the whole list.
rm -f "$T/othertool.version"
peer alpha fleet tools add othertool --version 2.0 --disruptive \
  --check "cat $T/othertool.version 2>/dev/null" \
  --install "sh $T/install.sh $T/othertool 2.0" >/dev/null
peer alpha fleet tools install othertool >/dev/null
peer alpha fleet tools add revtool --version 1.0 --disruptive \
  --check "cat $T/revtool.version 2>/dev/null" \
  --install "sh $T/install.sh $T/revtool 1.0" >/dev/null
peer alpha fleet tools install revtool >/dev/null
peer alpha fleet tools rm revtool >/dev/null
check "grant-rm: an unrelated deferral survives the removal" "othertool" \
      "$(peer alpha fleet tools deferred)"
same "grant-rm: only the withdrawn tool left the list" "0" \
     "$(peer alpha fleet tools deferred | grep -c '^revtool	')"

# and the tick's retry count agrees with the list it claims to be counting:
# reported after the pass, so a resolved deferral is not announced as pending.
rm -f "$tad61/live-task"
out=$(peer alpha fleet sync tick 2>/dev/null)
same "grant-rm: the resolved deferral is not announced as a retry" "0" \
     "$(printf '%s' "$out" | grep -c '^tools-retry')"
same "grant-rm: the tick applied it once the task was gone" "2.0" \
     "$(cat "$T/othertool.version" 2>/dev/null)"
same "grant-rm: nothing is left deferred after the pass" "" \
     "$(peer alpha fleet tools deferred)"
peer alpha fleet tools rm othertool >/dev/null 2>&1
rm -rf "$tad61"

# --- 62. a profile deletion never destroys what was not agreed -------------
# The existence marker is a delete primitive for a whole subtree. Honouring it
# blindly destroys the receiver's divergent edits, its machine-specific
# exceptions and data the fleet never replicated at all -- so the removal is
# refused while the subtree still holds any of those, and surfaced as a
# conflict the operator resolves explicitly.
mark "62. a profile deletion is refused while the subtree holds unagreed state"
# Section-local peers: removed first so the section is re-enterable against a
# fixture an earlier bounded run left behind, the way the preamble is.
chmod -R u+w "$base/rho" "$base/tau" 2>/dev/null
rm -rf "$base/rho" "$base/tau"
mkdir -p "$base/rho" "$base/tau"
R=$(peer rho fleet init --machine rho | awk '{print $2}')
TAU=$(peer tau fleet init --machine tau | awk '{print $2}')
peer tau fleet pair --home "$base/rho" \
  --code "$(peer rho fleet invite --peer "$TAU" 2>/dev/null)" >/dev/null 2>&1

# (a) deletion versus a descendant edit made while disconnected.
put x "$(slot rho Gone claude)/skills/t/SKILL.md" 'agreed bytes'
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
same "del-edit: the skill replicated first" "agreed bytes" \
     "$(cat "$(slot tau Gone claude)/skills/t/SKILL.md" 2>/dev/null)"
put x "$(slot tau Gone claude)/skills/t/SKILL.md" 'offline edit on tau'
rm -rf "$base/rho/.n2-agents/Gone"
out=$(peer rho fleet sync now --peer "$TAU" 2>&1)
if [ -d "$base/tau/.n2-agents/Gone" ]; then ok "del-edit: the receiver still has the profile"
else bad "del-edit: the receiver still has the profile" "destroyed: $out"; fi
same "del-edit: the divergent bytes are intact" "offline edit on tau" \
     "$(cat "$(slot tau Gone claude)/skills/t/SKILL.md" 2>/dev/null)"
refute "del-edit: the pass does not claim convergence" "converged	profile|Gone" "$out"
cf=$(peer tau fleet sync conflicts 2>&1)
check "del-edit: the deletion is visible as a conflict" "profile|Gone|-|.n2-profile" "$cf"
check "del-edit: and it says the remote deleted it" "remote:deleted" "$cf"
# The escape hatch exists and is explicit: --remote completes the removal.
gid=$(printf '%s' "$cf" | grep 'profile|Gone' | head -1 | awk '{print $1}')
peer tau fleet sync resolve "$gid" --remote >/dev/null 2>&1
if [ -e "$base/tau/.n2-agents/Gone" ]; then
  bad "del-edit: an explicit --remote completes the deletion" "Gone still present"
else ok "del-edit: an explicit --remote completes the deletion"; fi

# (b) deletion versus a machine-specific exception. The exception is this
# machine's deliberate difference; a peer's deletion may not revoke it.
put x "$(slot rho Exc claude)/skills/k/SKILL.md" 'keep me'
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
peer tau fleet sync except add skills Exc claude 'skills/k/*' >/dev/null 2>&1
rm -rf "$base/rho/.n2-agents/Exc"
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
if [ -d "$base/tau/.n2-agents/Exc" ]; then ok "del-except: the excepted profile survives"
else bad "del-except: the excepted profile survives" "destroyed despite the exception"; fi
same "del-except: the excepted bytes survive" "keep me" \
     "$(cat "$(slot tau Exc claude)/skills/k/SKILL.md" 2>/dev/null)"
check "del-except: it is offered as a conflict, not silently dropped" \
      "profile|Exc|-|.n2-profile" "$(peer tau fleet sync conflicts 2>&1)"
# Repeating the pass does not quietly succeed the second time.
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
if [ -d "$base/tau/.n2-agents/Exc" ]; then ok "del-except: a repeated pass still refuses"
else bad "del-except: a repeated pass still refuses" "destroyed on the second pass"; fi

# (c) deletion versus data the fleet never replicated. An unclassifiable file
# is machine-only; it has no address, so no peer ever agreed to its removal.
mkdir -p "$(slot rho Loc claude)"
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
mkdir -p "$(slot tau Loc claude)"
printf 'machine-only data' > "$(slot tau Loc claude)/local-only.txt"
rm -rf "$base/rho/.n2-agents/Loc"
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
same "del-local: unreplicated machine-only data survives" "machine-only data" \
     "$(cat "$(slot tau Loc claude)/local-only.txt" 2>/dev/null)"

# (d) the refusal is narrow, not a wall: transient junk the fleet never syncs
# does not keep a dead profile alive, so ordinary deletion still converges.
mkdir -p "$(slot rho Junk claude)"
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
mkdir -p "$(slot tau Junk claude)/cache"
printf 'noise' > "$(slot tau Junk claude)/cache/x.bin"
printf 'noise' > "$(slot tau Junk claude)/debug.log"
rm -rf "$base/rho/.n2-agents/Junk"
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
if [ -e "$base/tau/.n2-agents/Junk" ]; then
  bad "del-junk: a profile holding only junk is still deleted" "Junk survived on tau"
else ok "del-junk: a profile holding only junk is still deleted"; fi

mark "63. a deletion does not destroy history or profile-root files"
# Regression for a real data-loss bug: the blocker scan only walked the known
# vendor slots and, inside them, skipped every path sync_excluded_relpath
# matched. Two whole categories therefore never reached the weighing --
# session transcripts (excluded from replication *on purpose*, because they
# are machine-local) and anything sitting at the profile root. A peer's
# `rm -rf` on the profile then took both with it, exit 0, no conflict.
chmod -R u+w "$base/rho" "$base/tau" 2>/dev/null

# (a) session history. The fleet deliberately does not replicate it; that is
# exactly why deleting it here is unrecoverable rather than harmless.
mkdir -p "$(slot rho Hist claude)"
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
mkdir -p "$(slot tau Hist claude)/sessions" "$(slot tau Hist claude)/todos"
printf 'synthetic conversation history' > "$(slot tau Hist claude)/sessions/a.jsonl"
printf 'synthetic todo state' > "$(slot tau Hist claude)/todos/t.json"
rm -rf "$base/rho/.n2-agents/Hist"
out=$(peer rho fleet sync now --peer "$TAU" 2>&1)
same "del-hist: the transcript survives the peer's deletion" \
     "synthetic conversation history" \
     "$(cat "$(slot tau Hist claude)/sessions/a.jsonl" 2>/dev/null)"
same "del-hist: todo state survives too" "synthetic todo state" \
     "$(cat "$(slot tau Hist claude)/todos/t.json" 2>/dev/null)"
refute "del-hist: the pass does not report the tombstone as pushed" \
       "pushed	profile|Hist" "$out"
check "del-hist: it is visible as a conflict instead" "profile|Hist|-|.n2-profile" \
      "$(peer tau fleet sync conflicts 2>&1)"

# (b) a file at the profile root, outside every vendor slot. Nothing claims
# it, nothing replicates it, and the old scan never even looked there.
mkdir -p "$(slot rho Root claude)"
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
printf 'synthetic local notes' > "$base/tau/.n2-agents/Root/notes.txt"
mkdir -p "$base/tau/.n2-agents/Root/scratch"
printf 'unclaimed directory' > "$base/tau/.n2-agents/Root/scratch/x.txt"
rm -rf "$base/rho/.n2-agents/Root"
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
same "del-root: a profile-root file survives" "synthetic local notes" \
     "$(cat "$base/tau/.n2-agents/Root/notes.txt" 2>/dev/null)"
same "del-root: a directory no vendor claims survives" "unclaimed directory" \
     "$(cat "$base/tau/.n2-agents/Root/scratch/x.txt" 2>/dev/null)"
cf=$(peer tau fleet sync conflicts 2>&1)
check "del-root: and it is offered as a conflict" "profile|Root|-|.n2-profile" "$cf"
# The explicit escape hatch still works on these, so the refusal is a pause,
# not a profile that can never be removed again.
rid=$(printf '%s' "$cf" | grep 'profile|Root' | head -1 | awk '{print $1}')
peer tau fleet sync resolve "$rid" --remote >/dev/null 2>&1
if [ -e "$base/tau/.n2-agents/Root" ]; then
  bad "del-root: an explicit --remote still completes the deletion" "Root survived"
else ok "del-root: an explicit --remote still completes the deletion"; fi

# (c) the narrowness holds at the profile root too: junk there is still junk.
mkdir -p "$(slot rho Junk2 claude)"
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
printf 'noise' > "$base/tau/.n2-agents/Junk2/run.log"
mkdir -p "$base/tau/.n2-agents/Junk2/tmp"
printf 'noise' > "$base/tau/.n2-agents/Junk2/tmp/x"
rm -rf "$base/rho/.n2-agents/Junk2"
peer rho fleet sync now --peer "$TAU" >/dev/null 2>&1
if [ -e "$base/tau/.n2-agents/Junk2" ]; then
  bad "del-junk2: root-level junk does not block the deletion" "Junk2 survived"
else ok "del-junk2: root-level junk does not block the deletion"; fi

# --- 64. an escaped JSON key is the same key ------------------------------
# `"Authorization"` and `"Authorization"` are one key to every JSON
# parser, so a detector that greps the raw bytes reads the first as an
# unremarkable string. That was a live bypass: a bearer token under the escaped
# name replicated between two peers whose auth opt-in files were both empty.
# Both sides of the gate are exercised here -- the sender must not offer it and
# the receiver must not store it -- because a fix on one side only moves the
# leak. Every credential below is a synthetic string invented here.
mark "64. a credential under an escaped JSON key is still a credential"
mkdir -p "$base/upsilon" "$base/phi"
U=$(peer upsilon fleet init --machine upsilon | awk '{print $2}')
PH=$(peer phi    fleet init --machine phi     | awk '{print $2}')
peer phi fleet pair --home "$base/upsilon" \
  --code "$(peer upsilon fleet invite --peer "$PH" 2>/dev/null)" >/dev/null 2>&1
peer upsilon new Work >/dev/null 2>&1
udir=$(slot upsilon Work claude); pdir=$(slot phi Work claude)

put x "$udir/.mcp.json" \
  '{"mcpServers":{"r":{"url":"https://e/x","headers":{"\u0041uthorization":"Bearer SYNTHETIC-ESC-001"}}}}'
out=$(peer upsilon fleet sync scope 2>&1)
refute "esc: an escaped header key drops out of scope without the opt-in" \
       "mcp|Work|claude" "$out"
out=$(peer upsilon fleet sync now --peer "$PH" 2>&1)
refute "esc: nothing is pushed for it either" "pushed	mcp|Work|claude" "$out"
if grep -qF 'SYNTHETIC-ESC-001' "$pdir/.mcp.json" 2>/dev/null; then
  bad "esc: the escaped-key token never reaches the peer" "it was replicated"
else
  ok  "esc: the escaped-key token never reaches the peer"
fi
# Mixed case and a second escape in the middle: the decode is not a special
# case for one leading letter.
put x "$udir/.mcp.json" \
  '{"mcpServers":{"r":{"url":"https://e/x","headers":{"\u0061uthoriz\u0041tion":"Bearer SYNTHETIC-ESC-002"}}}}'
peer upsilon fleet sync now --peer "$PH" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-ESC-002' "$pdir/.mcp.json" 2>/dev/null; then
  bad "esc: a partly escaped header key is caught too" "it was replicated"
else
  ok  "esc: a partly escaped header key is caught too"
fi
# The same trick against the env-variable names, in a settings-class file.
put x "$udir/settings.json" '{"env":{"\u0041NTHROPIC_API_KEY":"SYNTHETIC-ESC-003"}}'
peer upsilon fleet sync now --peer "$PH" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-ESC-003' "$pdir/settings.json" 2>/dev/null; then
  bad "esc: an escaped env key is credential material too" "it was replicated"
else
  ok  "esc: an escaped env key is credential material too"
fi

# Receiver side. The sender opts in, so it offers and pushes; phi never did,
# so the arriving payload must still be refused at the write.
out=$(peer upsilon fleet sync auth enable claude 2>&1)
check "esc: the sender opts in" "auth-optin	claude" "$out"
peer upsilon fleet sync now --peer "$PH" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-ESC-002' "$pdir/.mcp.json" 2>/dev/null; then
  bad "esc: the receiver refuses an escaped-key credential it never opted into" \
      "phi stored the token with no opt-in of its own"
else
  ok  "esc: the receiver refuses an escaped-key credential it never opted into"
fi
if grep -qF 'SYNTHETIC-ESC-003' "$pdir/settings.json" 2>/dev/null; then
  bad "esc: and refuses the escaped env key as well" "phi stored it"
else
  ok  "esc: and refuses the escaped env key as well"
fi
# Withholding is the opt-in, not a ban: with both sides opted in it replicates.
out=$(peer phi fleet sync auth enable claude 2>&1)
check "esc: the receiver opts in" "auth-optin	claude" "$out"
peer upsilon fleet sync now --peer "$PH" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-ESC-002' "$pdir/.mcp.json" 2>/dev/null; then
  ok  "esc: opted in on both sides, it does replicate"
else
  bad "esc: opted in on both sides, it does replicate" "still withheld"
fi
peer upsilon fleet sync auth disable claude >/dev/null 2>&1
peer phi     fleet sync auth disable claude >/dev/null 2>&1

# Over-broadness: an escape that does not spell a credential key must not
# paralyse ordinary config. `A plain` decodes to `A plain`, and
# `authorizationRequired` is still not an assignment of `Authorization`.
# A fresh profile, because the addresses used above still hold credential
# bytes on phi and are legitimately refused there while phi is opted out.
peer upsilon new Clean >/dev/null 2>&1
udir=$(slot upsilon Clean claude); pdir=$(slot phi Clean claude)
# Opted in on both sides so the `mcp` class gate is out of the way: the
# assertion below is about the escape decoder, not about the class.
peer upsilon fleet sync auth enable claude >/dev/null 2>&1
peer phi     fleet sync auth enable claude >/dev/null 2>&1
put x "$udir/.mcp.json" \
  '{"mcpServers":{"local":{"command":"node","args":["s.js"]}},"note":"\u0041 plain letter","authorizationRequired":true}'
put x "$udir/settings.json" '{"model":"opus","label":"caf\u00e9"}'
peer upsilon fleet sync now --peer "$PH" >/dev/null 2>&1
if grep -q 'plain letter' "$pdir/.mcp.json" 2>/dev/null; then
  ok  "esc: a harmless escape does not withhold an ordinary mcp config"
else
  bad "esc: a harmless escape does not withhold an ordinary mcp config" "withheld"
fi
if grep -q 'opus' "$pdir/settings.json" 2>/dev/null; then
  ok  "esc: a non-ASCII escape is left alone, not invented into a key"
else
  bad "esc: a non-ASCII escape is left alone, not invented into a key" "withheld"
fi

# --- 65. a newline between key and colon is still an assignment -----------
mark "65. a credential split across a newline is still a credential"
# Regression for a real bypass. The scanner used to be a line-oriented grep,
# and JSON allows whitespace -- newlines included -- between a key string and
# its colon. A `.mcp.json` written that way carried a live bearer token past
# both the sender's scope filter and the receiver's write refusal, with
# neither side opted in. The gate now folds whitespace before matching.
mkdir -p "$base/chi" "$base/psi"
CH=$(peer chi fleet init --machine chi | awk '{print $2}')
PS=$(peer psi fleet init --machine psi | awk '{print $2}')
peer psi fleet pair --home "$base/chi" \
  --code "$(peer chi fleet invite --peer "$PS" 2>/dev/null)" >/dev/null 2>&1
peer chi new Work >/dev/null 2>&1
cdir=$(slot chi Work claude); sdir=$(slot psi Work claude)

# Valid JSON, key and colon on separate lines. This is the exact shape that
# replicated byte-for-byte while both auth-optin files were empty.
put x "$cdir/.mcp.json" '{
  "mcpServers": {
    "r": {
      "url": "https://e/x",
      "headers": {
        "Authorization"
          : "Bearer SYNTHETIC-NL-001"
      }
    }
  }
}'
out=$(peer chi fleet sync scope 2>&1)
refute "nl: a newline-split header key drops out of scope without the opt-in" \
       "mcp|Work|claude" "$out"
out=$(peer chi fleet sync now --peer "$PS" 2>&1)
refute "nl: nothing is pushed for it either" "pushed	mcp|Work|claude" "$out"
if grep -qF 'SYNTHETIC-NL-001' "$sdir/.mcp.json" 2>/dev/null; then
  bad "nl: the split-key token never reaches the peer" "it was replicated"
else
  ok  "nl: the split-key token never reaches the peer"
fi

# Several newlines and indentation between key and colon, and the escape trick
# stacked on top of the split: the fold runs before the unescape comparison.
put x "$cdir/.mcp.json" '{
  "mcpServers": { "r": { "url": "https://e/x", "headers": {
        "\u0041uthorization"

              :   "Bearer SYNTHETIC-NL-002"
  } } }
}'
peer chi fleet sync now --peer "$PS" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-NL-002' "$sdir/.mcp.json" 2>/dev/null; then
  bad "nl: an escaped key split over blank lines is caught too" "it was replicated"
else
  ok  "nl: an escaped key split over blank lines is caught too"
fi

# Settings-class file, env-variable name, same split.
put x "$cdir/settings.json" '{
  "env": {
    "ANTHROPIC_API_KEY"
      : "SYNTHETIC-NL-003"
  }
}'
peer chi fleet sync now --peer "$PS" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-NL-003' "$sdir/settings.json" 2>/dev/null; then
  bad "nl: a split env key is credential material too" "it was replicated"
else
  ok  "nl: a split env key is credential material too"
fi

# Receiver side: sender opted in, receiver did not, so the write is refused.
out=$(peer chi fleet sync auth enable claude 2>&1)
check "nl: the sender opts in" "auth-optin	claude" "$out"
peer chi fleet sync now --peer "$PS" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-NL-002' "$sdir/.mcp.json" 2>/dev/null; then
  bad "nl: the receiver refuses a split-key credential it never opted into" \
      "psi stored the token with no opt-in of its own"
else
  ok  "nl: the receiver refuses a split-key credential it never opted into"
fi
if grep -qF 'SYNTHETIC-NL-003' "$sdir/settings.json" 2>/dev/null; then
  bad "nl: and refuses the split env key as well" "psi stored it"
else
  ok  "nl: and refuses the split env key as well"
fi
# Withholding is the opt-in, not a ban.
out=$(peer psi fleet sync auth enable claude 2>&1)
check "nl: the receiver opts in" "auth-optin	claude" "$out"
peer chi fleet sync now --peer "$PS" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-NL-002' "$sdir/.mcp.json" 2>/dev/null; then
  ok  "nl: opted in on both sides, it does replicate"
else
  bad "nl: opted in on both sides, it does replicate" "still withheld"
fi
peer chi fleet sync auth disable claude >/dev/null 2>&1
peer psi fleet sync auth disable claude >/dev/null 2>&1

# Over-broadness: folding whitespace must not make ordinary multi-line config
# look like a credential. A fresh profile, because the addresses above hold
# credential bytes that are legitimately refused on psi while it is opted out.
peer chi new Clean >/dev/null 2>&1
cdir=$(slot chi Clean claude); sdir=$(slot psi Clean claude)
# Opted in on both sides: what is under test is the whitespace folder, not the
# `mcp` class gate.
peer chi fleet sync auth enable claude >/dev/null 2>&1
peer psi fleet sync auth enable claude >/dev/null 2>&1
put x "$cdir/.mcp.json" '{
  "mcpServers": {
    "local": { "command": "node", "args": ["s.js"] }
  },
  "authorizationRequired"
    : true,
  "notes": [
    "access_token",
    "rotate quarterly"
  ]
}'
put x "$cdir/settings.json" '{
  "model": "opus",
  "env": { "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "8192" }
}'
peer chi fleet sync now --peer "$PS" >/dev/null 2>&1
if grep -q 'rotate quarterly' "$sdir/.mcp.json" 2>/dev/null; then
  ok  "nl: a split non-credential key does not withhold ordinary mcp config"
else
  bad "nl: a split non-credential key does not withhold ordinary mcp config" "withheld"
fi
if grep -q 'opus' "$sdir/settings.json" 2>/dev/null; then
  ok  "nl: a bare key name in a list is not an assignment"
else
  bad "nl: a bare key name in a list is not an assignment" "withheld"
fi

# --- 66. a TOML literal-string key is still a key --------------------------
mark "66. a single-quoted TOML key is still a credential"
# Regression for a real bypass found in review. The scanner accepted an
# optional *double* quote around the key name, but TOML keys may be literal
# strings (https://toml.io/en/v1.0.0#keys), so
#
#     [mcp_servers.test.env]
#     'OPENAI_API_KEY' = '...'
#
# named the same key and matched nothing. A codex config.toml written that way
# replicated byte-for-byte to a peer while both auth-optin files were empty.
mkdir -p "$base/omega" "$base/sigma"
OM=$(peer omega fleet init --machine omega | awk '{print $2}')
SG=$(peer sigma fleet init --machine sigma | awk '{print $2}')
peer sigma fleet pair --home "$base/omega" \
  --code "$(peer omega fleet invite --peer "$SG" 2>/dev/null)" >/dev/null 2>&1
peer omega new Work >/dev/null 2>&1
odir=$(slot omega Work codex); gdir=$(slot sigma Work codex)

put x "$odir/config.toml" "model = \"gpt-5\"
[mcp_servers.test.env]
'OPENAI_API_KEY' = 'SYNTHETIC-TOML-001'
"
out=$(peer omega fleet sync scope 2>&1)
refute "toml: a single-quoted credential key drops out of scope" \
       "settings|Work|codex" "$out"
out=$(peer omega fleet sync now --peer "$SG" 2>&1)
refute "toml: nothing is pushed for it either" "pushed	settings|Work|codex" "$out"
if grep -qF 'SYNTHETIC-TOML-001' "$gdir/config.toml" 2>/dev/null; then
  bad "toml: the single-quoted key never reaches the peer" "it was replicated"
else
  ok  "toml: the single-quoted key never reaches the peer"
fi

# The receiver refuses it independently of the sender: opt the sender in only,
# and the bytes must still not land.
peer omega fleet sync auth enable codex >/dev/null 2>&1
peer omega fleet sync now --peer "$SG" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-TOML-001' "$gdir/config.toml" 2>/dev/null; then
  bad "toml: sender opt-in alone does not place it" "it was replicated"
else
  ok  "toml: sender opt-in alone does not place it"
fi

# A single-quoted HTTP header name is the same story.
put x "$odir/config.toml" "model = \"gpt-5\"
[mcp_servers.test.http_headers]
'Authorization' = 'Bearer SYNTHETIC-TOML-002'
"
peer omega fleet sync now --peer "$SG" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-TOML-002' "$gdir/config.toml" 2>/dev/null; then
  bad "toml: a single-quoted header name is caught too" "it was replicated"
else
  ok  "toml: a single-quoted header name is caught too"
fi

# Opted in on both sides, the same file does replicate -- the gate is an
# opt-in, not a permanent block.
peer sigma fleet sync auth enable codex >/dev/null 2>&1
peer omega fleet sync now --peer "$SG" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-TOML-002' "$gdir/config.toml" 2>/dev/null; then
  ok  "toml: opted in on both sides, it does replicate"
else
  bad "toml: opted in on both sides, it does replicate" "still withheld"
fi

# Over-broadness guard: an apostrophe in ordinary config must not withhold it.
peer omega new Clean >/dev/null 2>&1
odir=$(slot omega Clean codex); gdir=$(slot sigma Clean codex)
put x "$odir/config.toml" "model = \"gpt-5\"
notes = \"the model's apiKey handling is documented elsewhere\"
"
peer omega fleet sync now --peer "$SG" >/dev/null 2>&1
if grep -q 'documented elsewhere' "$gdir/config.toml" 2>/dev/null; then
  ok  "toml: an apostrophe in a value does not withhold ordinary config"
else
  bad "toml: an apostrophe in a value does not withhold ordinary config" "withheld"
fi

# --- 67. a camelCase OAuth grant is still a credential ----------------------
mark "67. camelCase and bare token credential keys are caught"
# Second regression from the same family. Only the snake_case spellings were
# listed, but an OAuth grant is written camelCase far more often -- Claude
# Code's own stored grant is
#   {"claudeAiOauth":{"accessToken":...,"refreshToken":...,"expiresAt":...}}
# -- and that blob pasted into settings.json or .mcp.json, neither of which is
# classified `auth` by filename, carried a live token straight past the gate.
# `token` alone is the same story for a remote MCP server's bearer credential.
mkdir -p "$base/kappa" "$base/tau"
KA=$(peer kappa fleet init --machine kappa | awk '{print $2}')
TA=$(peer tau fleet init --machine tau | awk '{print $2}')
peer tau fleet pair --home "$base/kappa" \
  --code "$(peer kappa fleet invite --peer "$TA" 2>/dev/null)" >/dev/null 2>&1
peer kappa new Work >/dev/null 2>&1
kdir=$(slot kappa Work claude); tdir=$(slot tau Work claude)

put x "$kdir/settings.json" \
  '{"claudeAiOauth":{"accessToken":"SYNTHETIC-CAMEL-001","refreshToken":"SYNTHETIC-CAMEL-002","expiresAt":1}}'
out=$(peer kappa fleet sync scope 2>&1)
refute "camel: an accessToken grant drops out of scope" \
       "settings|Work|claude" "$out"
out=$(peer kappa fleet sync now --peer "$TA" 2>&1)
refute "camel: nothing is pushed for it either" "pushed	settings|Work|claude" "$out"
if grep -qF 'SYNTHETIC-CAMEL-001' "$tdir/settings.json" 2>/dev/null; then
  bad "camel: the grant never reaches the peer" "it was replicated"
else
  ok  "camel: the grant never reaches the peer"
fi

# The receiver refuses independently: opt the sender in only.
peer kappa fleet sync auth enable claude >/dev/null 2>&1
peer kappa fleet sync now --peer "$TA" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-CAMEL-001' "$tdir/settings.json" 2>/dev/null; then
  bad "camel: sender opt-in alone does not place it" "it was replicated"
else
  ok  "camel: sender opt-in alone does not place it"
fi

# A bare `token` key on an MCP server entry is the same story, and it is an
# .mcp.json -- a class the per-vendor auth opt-in does not otherwise gate.
put x "$kdir/.mcp.json" \
  '{"mcpServers":{"remote":{"url":"https://example.invalid","token":"SYNTHETIC-CAMEL-003"}}}'
peer kappa fleet sync now --peer "$TA" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-CAMEL-003' "$tdir/.mcp.json" 2>/dev/null; then
  bad "camel: a bare token key is caught too" "it was replicated"
else
  ok  "camel: a bare token key is caught too"
fi

# Opted in on both sides, it does replicate -- still an opt-in, not a block.
peer tau fleet sync auth enable claude >/dev/null 2>&1
peer kappa fleet sync now --peer "$TA" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-CAMEL-003' "$tdir/.mcp.json" 2>/dev/null; then
  ok  "camel: opted in on both sides, it does replicate"
else
  bad "camel: opted in on both sides, it does replicate" "still withheld"
fi

# Over-broadness guard: the near-miss names that share a prefix with the new
# keys must keep replicating, or every ordinary settings file stops syncing.
peer kappa new Clean >/dev/null 2>&1
kdir=$(slot kappa Clean claude); tdir=$(slot tau Clean claude)
put x "$kdir/settings.json" \
  '{"maxTokens":8192,"tokensUsed":3,"tokenizer":"cl100k","passwordless":true,"env":{"CLAUDE_CODE_MAX_OUTPUT_TOKENS":"8192"}}'
peer kappa fleet sync now --peer "$TA" >/dev/null 2>&1
if grep -q 'tokenizer' "$tdir/settings.json" 2>/dev/null; then
  ok  "camel: token-prefixed ordinary keys still replicate"
else
  bad "camel: token-prefixed ordinary keys still replicate" "withheld"
fi

# --- 68. a hyphen is the third spelling of the same separator ---------------
mark "68. hyphenated credential header names are caught"
# Third regression from the same family, and the one with real providers
# behind it: Azure OpenAI authenticates with a header literally named
# `api-key`, and Google's generative API with `x-goog-api-key`. Neither ends
# in a listed name -- `key` is not listed and cannot be, because `"key":` is
# an ordinary map key in half the files that sync -- so both carried a live
# credential past the gate in an .mcp.json, a class the per-vendor auth
# opt-in does not otherwise gate. `access-token` and `client-secret` were
# already caught, by their `token` / `secret` suffix.
mkdir -p "$base/rho" "$base/nu"
RA=$(peer rho fleet init --machine rho | awk '{print $2}')
NA=$(peer nu  fleet init --machine nu  | awk '{print $2}')
peer nu fleet pair --home "$base/rho" \
  --code "$(peer rho fleet invite --peer "$NA" 2>/dev/null)" >/dev/null 2>&1
peer rho new Hyph >/dev/null 2>&1
rdir=$(slot rho Hyph claude); ndir=$(slot nu Hyph claude)

put x "$rdir/.mcp.json" \
  '{"mcpServers":{"azure":{"url":"https://example.invalid","headers":{"api-key":"SYNTHETIC-HYPHEN-001"}}}}'
out=$(peer rho fleet sync scope 2>&1)
refute "hyphen: an api-key header drops out of scope" "mcp|Hyph|claude" "$out"
out=$(peer rho fleet sync now --peer "$NA" 2>&1)
refute "hyphen: nothing is pushed for it either" "pushed	mcp|Hyph|claude" "$out"
if grep -qF 'SYNTHETIC-HYPHEN-001' "$ndir/.mcp.json" 2>/dev/null; then
  bad "hyphen: the api-key header never reaches the peer" "it was replicated"
else
  ok  "hyphen: the api-key header never reaches the peer"
fi

# The receiver refuses on its own: opt the sender in only.
peer rho fleet sync auth enable claude >/dev/null 2>&1
peer rho fleet sync now --peer "$NA" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-HYPHEN-001' "$ndir/.mcp.json" 2>/dev/null; then
  bad "hyphen: sender opt-in alone does not place it" "it was replicated"
else
  ok  "hyphen: sender opt-in alone does not place it"
fi

# Google's spelling, in a settings.json rather than an .mcp.json.
put x "$rdir/settings.json" \
  '{"env":{},"headers":{"x-goog-api-key":"SYNTHETIC-HYPHEN-002"}}'
peer rho fleet sync now --peer "$NA" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-HYPHEN-002' "$ndir/settings.json" 2>/dev/null; then
  bad "hyphen: x-goog-api-key is caught too" "it was replicated"
else
  ok  "hyphen: x-goog-api-key is caught too"
fi

# Opted in on both sides it replicates -- still an opt-in, not a block.
peer nu fleet sync auth enable claude >/dev/null 2>&1
peer rho fleet sync now --peer "$NA" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-HYPHEN-001' "$ndir/.mcp.json" 2>/dev/null; then
  ok  "hyphen: opted in on both sides, it does replicate"
else
  bad "hyphen: opted in on both sides, it does replicate" "still withheld"
fi

# Over-broadness guard. `key`, `keys` and `secretName` are ordinary
# configuration; if the new names swallow them, every keybinding file and
# every secret *reference* stops syncing.
peer rho new Plain >/dev/null 2>&1
rdir=$(slot rho Plain claude); ndir=$(slot nu Plain claude)
put x "$rdir/settings.json" \
  '{"key":"cmd+k","keys":{"up":"k"},"secretName":"prod","secretRef":"vault://x"}'
peer rho fleet sync now --peer "$NA" >/dev/null 2>&1
if grep -q 'secretName' "$ndir/settings.json" 2>/dev/null; then
  ok  "hyphen: ordinary key and secretName fields still replicate"
else
  bad "hyphen: ordinary key and secretName fields still replicate" "withheld"
fi

# --- 69. a machine can except itself out of the managed-tool manifest ------
# The exceptions test at section 49 proves `except add tools - - manifest` is
# *accepted* rather than refused as inert. It never proved the consequence,
# and the consequence is the one that matters: the tools manifest is the only
# resource whose arrival runs a command. If the exception did not actually
# gate it, a machine the operator had deliberately held apart would still
# take a peer's designation and execute its installer -- the exact "blanket
# install authority" the issue rules out, reached by the sync path instead of
# by `tools install`. The installers below write into *this machine's* HOME,
# so "it ran on the designator" and "it ran on the excepted machine" are two
# separately observable facts rather than one shared file.
mark "69. a machine can except itself out of the managed-tool manifest"
mkdir -p "$base/tex1" "$base/tex2"
PA=$(peer tex1   fleet init --machine tex1   | awk '{print $2}')
OA=$(peer tex2 fleet init --machine tex2 | awk '{print $2}')
peer tex2 fleet pair --home "$base/tex1" \
  --code "$(peer tex1 fleet invite --peer "$OA" 2>/dev/null)" >/dev/null 2>&1

# tex2 opts out first, before anything is designated anywhere, so the
# exception is in force for the manifest's very first crossing.
o=$(peer tex2 fleet sync except add tools - - manifest 2>&1)
check "toolexc: the exception is accepted" "excepted	tools|-|-|manifest" "$o"
out=$(peer tex2 fleet sync scope 2>&1)
refute "toolexc: tex2 no longer advertises the manifest" "tools|-|-|manifest" "$out"

peer tex1 fleet tools add exctool --version 3.0 \
  --check 'cat "$HOME/exctool.v" 2>/dev/null' \
  --install 'printf 3.0 > "$HOME/exctool.v"' >/dev/null 2>&1
peer tex1 fleet tools apply >/dev/null 2>&1
same "toolexc: the designator installs it locally" "3.0" "$(cat "$base/tex1/exctool.v" 2>/dev/null)"

# The push is refused by the receiver's own gate, not merely omitted by a
# polite sender: sync_scope_ok runs on both ends.
out=$(peer tex1 fleet sync now --peer "$OA" 2>&1)
refute "toolexc: the manifest is not reported as pushed" "pushed	tools|-|-|manifest" "$out"
out=$(peer tex2 fleet tools list 2>&1)
refute "toolexc: the designation does not land on the excepted machine" "exctool" "$out"
if [ -f "$base/tex2/exctool.v" ]; then
  bad "toolexc: no installer ran on the excepted machine" \
      "$base/tex2/exctool.v exists, so the manifest's installer executed"
else
  ok  "toolexc: no installer ran on the excepted machine"
fi
# A tick is the automatic path, and it must respect the exception too: the
# operator's opt-out cannot hold only for the hand-run verb.
peer tex1 fleet sync tick --interval 0 >/dev/null 2>&1
if [ -f "$base/tex2/exctool.v" ]; then
  bad "toolexc: the automatic tick respects it as well" "the installer ran on the tick"
else
  ok  "toolexc: the automatic tick respects it as well"
fi
# The exception is machine-local: it says nothing about tex1, and tex1's own
# manifest is untouched by tex2 having opted out.
out=$(peer tex1 fleet tools list 2>&1)
check "toolexc: the designator keeps its own designation" "exctool|3.0" "$out"

# Withdraw the exception and the same manifest reaches tex2. Without this
# the assertions above would also pass if the tools manifest simply never
# replicated between these two peers at all.
#
# It does not arrive as a bare push, and that is the documented rule rather
# than an accident of this fixture: tex2 has had a manifest of its own since
# `fleet init` created an empty one, so once it is back in scope the two are
# independent designations and neither is a descendant of the other. Section
# 25 fixes that shape as a conflict; an exception being withdrawn must not be
# a back door around it. So the conflict is asserted, resolved the way an
# operator resolves one, and only then does the designation land.
peer tex2 fleet sync except rm 1 >/dev/null 2>&1
out=$(peer tex1 fleet sync now --peer "$OA" 2>&1)
w=$(printf '%s\n' "$out" | awk -F'\t' '$3=="tools|-|-|manifest"{print $2}' | tail -1)
case ${w:-none} in
  conflict|pinned) ok "toolexc: withdrawn, the manifest is compared, not overwritten" ;;
  *) bad "toolexc: withdrawn, the manifest is compared, not overwritten" \
       "word was '${w:-none}'; pass said: $(printf '%s' "$out" | tr '\n' ';')" ;;
esac
cid=$(peer tex1 fleet sync conflicts 2>/dev/null | awk -F'\t' '$2=="tools|-|-|manifest"{print $1}' | tail -1)
peer tex1 fleet sync resolve "$cid" --local >/dev/null 2>&1
peer tex1 fleet sync now --peer "$OA" >/dev/null 2>&1
out=$(peer tex2 fleet tools list 2>&1)
check "toolexc: withdrawn and resolved, the designation lands" "exctool|3.0" "$out"
# The designation is a fleet fact and lands, but the command inside it is not
# permission to run here: withdrawing an exception re-admits the manifest, not
# the shell command. Section 72 owns that contract; this asserts the back door
# is closed too.
same  "toolexc: re-admission alone does not run the command" "" \
      "$(cat "$base/tex2/exctool.v" 2>/dev/null)"
check "toolexc: the re-admitted command is pending approval" "exctool	pending-approval" \
      "$(peer tex2 fleet tools status 2>&1)"
peer tex2 fleet tools approve exctool >/dev/null 2>&1
peer tex2 fleet tools apply >/dev/null 2>&1
same  "toolexc: once approved, the controlled installer runs" "3.0" "$(cat "$base/tex2/exctool.v" 2>/dev/null)"

# --- 70. a missing vendor folder is not a deletion ------------------------
mark "70. a missing vendor folder is not a deletion"
put alpha "$(slot alpha Vol claude)/skills/v/SKILL.md" 'vol skill'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
same "unmounted: beta has the file first" "vol skill" \
     "$(cat "$(slot beta Vol claude)/skills/v/SKILL.md" 2>/dev/null)"
# The folder vanishes the way an unmounted volume does: gone, not emptied.
mv "$(slot alpha Vol claude)" "$base/alpha/vol-offline"
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
refute "unmounted: no tombstone is pushed" "pushed	skills|Vol|claude|skills/v/SKILL.md" "$out"
same "unmounted: beta keeps its copy" "vol skill" \
     "$(cat "$(slot beta Vol claude)/skills/v/SKILL.md" 2>/dev/null)"
mv "$base/alpha/vol-offline" "$(slot alpha Vol claude)"
# A real deletion inside a present folder still travels.
rm -f "$(slot alpha Vol claude)/skills/v/SKILL.md"
out=$(peer alpha fleet sync now --peer "$B" 2>&1)
check "unmounted: a real deletion still replicates" "pushed	skills|Vol|claude|skills/v/SKILL.md" "$out"

# --- 71. a file keeps its mode across a sync -------------------------------
mark "71. modes survive replication"
hk="$(slot alpha Work claude)/skills/modes/run.sh"
put alpha "$hk" '#!/bin/sh
echo one'
chmod 755 "$hk"
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
bk="$(slot beta Work claude)/skills/modes/run.sh"
if [ -x "$bk" ]; then ok "modes: a new script arrives executable"
else bad "modes: a new script arrives executable" "$(ls -l "$bk" 2>&1)"; fi
chmod 700 "$bk"
put alpha "$hk" '#!/bin/sh
echo two'
peer alpha fleet sync now --peer "$B" >/dev/null 2>&1
same "modes: the update landed" "echo two" "$(tail -1 "$bk" 2>/dev/null)"
same "modes: an existing file keeps its own mode" "700" \
     "$(stat -f '%Lp' "$bk" 2>/dev/null || stat -c '%a' "$bk" 2>/dev/null)"

# --- 72. an install command that arrives from a peer waits for approval ----
# A manifest is a fleet fact and replicates like any other resource, but the
# *command* inside it does not arrive with permission to run here. Designating
# a tool on one machine must not become a way to execute a shell command on
# every other one. Approval is keyed on the install and check commands
# themselves, so a version bump over commands this operator already approved
# still applies by itself.
mark "72. an arriving install command waits for local approval"
mkdir -p "$base/tapp1" "$base/tapp2"
TP1=$(peer tapp1 fleet init --machine tapp1 | awk '{print $2}')
TP2=$(peer tapp2 fleet init --machine tapp2 | awk '{print $2}')
peer tapp2 fleet pair --home "$base/tapp1" \
  --code "$(peer tapp1 fleet invite --peer "$TP2" 2>/dev/null)" >/dev/null 2>&1
# Agree on the empty manifests before making a one-sided change.
peer tapp1 fleet sync now --peer "$TP2" >/dev/null 2>&1
tm="$base/tappmark"; mkdir -p "$tm"; printf 1.0 > "$tm/src.v"
tchk="cat '$tm/apprtool.v' 2>/dev/null"
tins="cp '$tm/src.v' '$tm/apprtool.v'"
peer tapp1 fleet tools add apprtool --version 1.0 --check "$tchk" --install "$tins" >/dev/null 2>&1
peer tapp1 fleet sync now --peer "$TP2" >/dev/null 2>&1
check "appr: the designation itself replicates" "apprtool|1.0" "$(peer tapp2 fleet tools list 2>&1)"
if [ -e "$tm/apprtool.v" ]; then
  bad "appr: the arriving install command does not run" "it executed on arrival"
else ok "appr: the arriving install command does not run"; fi
check "appr: the receiver reports it pending approval" "apprtool	pending-approval" \
      "$(peer tapp2 fleet tools status 2>&1)"
out=$(peer tapp2 fleet tools apply 2>&1)
check "appr: apply names it rather than running it" "pending-approval	apprtool" "$out"
if [ -e "$tm/apprtool.v" ]; then
  bad "appr: apply does not run it either" "it executed under apply"
else ok "appr: apply does not run it either"; fi
# The local operator approves that exact command once.
check "appr: approval is recorded" "approved	apprtool" \
      "$(peer tapp2 fleet tools approve apprtool 2>&1)"
peer tapp2 fleet tools apply >/dev/null 2>&1
same "appr: once approved, the installer runs" "1.0" "$(cat "$tm/apprtool.v" 2>/dev/null)"

# A version bump that keeps the approved commands applies on its own.
printf 2.0 > "$tm/src.v"
peer tapp1 fleet tools add apprtool --version 2.0 --check "$tchk" --install "$tins" >/dev/null 2>&1
peer tapp1 fleet sync now --peer "$TP2" >/dev/null 2>&1
check "appr: the bump replicates" "apprtool|2.0" "$(peer tapp2 fleet tools list 2>&1)"
refute "appr: a bump over approved commands needs no second approval" \
       "pending-approval" "$(peer tapp2 fleet tools status 2>&1)"
peer tapp2 fleet tools apply >/dev/null 2>&1
same "appr: the bump installs without a second command" "2.0" "$(cat "$tm/apprtool.v" 2>/dev/null)"

# ...and a *changed* command is a new decision, not an inherited one.
peer tapp1 fleet tools add apprtool --version 3.0 --check "$tchk" \
  --install "$tins && printf x > '$tm/extra'" >/dev/null 2>&1
peer tapp1 fleet sync now --peer "$TP2" >/dev/null 2>&1
check "appr: a changed install command is pending again" "apprtool	pending-approval" \
      "$(peer tapp2 fleet tools status 2>&1)"
peer tapp2 fleet tools apply >/dev/null 2>&1
if [ -e "$tm/extra" ]; then
  bad "appr: the changed command does not inherit the old approval" "it ran"
else ok "appr: the changed command does not inherit the old approval"; fi
# Approval is permission to run, not permission to interrupt: an approved
# disruptive update still defers while a task is running here.
peer tapp2 fleet tools approve apprtool >/dev/null 2>&1
peer tapp1 fleet tools add apprtool --version 4.0 --disruptive --check "$tchk" \
  --install "$tins && printf x > '$tm/extra'" >/dev/null 2>&1
mkdir -p "$base/tapp2/.n2-agents/fleet/tasks/active"
: > "$base/tapp2/.n2-agents/fleet/tasks/active/task-appr"
peer tapp1 fleet sync now --peer "$TP2" >/dev/null 2>&1
check "appr: only the command matters, so --disruptive alone is not a new approval" \
      "apprtool" "$(peer tapp2 fleet tools list 2>&1)"
out=$(peer tapp2 fleet tools apply 2>&1)
check "appr: an approved disruptive update defers while work runs" "deferred	apprtool" "$out"
if [ -e "$tm/extra" ]; then
  bad "appr: the deferral held" "it ran through an active task"
else ok "appr: the deferral held"; fi
rm -f "$base/tapp2/.n2-agents/fleet/tasks/active/task-appr"
peer tapp2 fleet tools apply >/dev/null 2>&1
if [ -e "$tm/extra" ]; then ok "appr: it applies once the task ends"
else bad "appr: it applies once the task ends" "still not installed"; fi

# Checks also execute shell commands, including when status is requested.
peer tapp1 fleet tools add apprtool --version 4.0 \
  --check "printf checked > '$tm/check-ran'; $tchk" \
  --install "$tins && printf x > '$tm/extra'" >/dev/null 2>&1
peer tapp1 fleet sync now --peer "$TP2" >/dev/null 2>&1
check "appr: a changed check command requires approval" "apprtool	pending-approval" \
      "$(peer tapp2 fleet tools status 2>&1)"
peer tapp2 fleet tools list >/dev/null 2>&1
peer tapp2 fleet tools apply >/dev/null 2>&1
if [ -e "$tm/check-ran" ]; then
  bad "appr: arrival, status, list and apply never run an unapproved check" "check ran"
else ok "appr: arrival, status, list and apply never run an unapproved check"; fi
peer tapp2 fleet tools approve apprtool >/dev/null 2>&1
peer tapp2 fleet tools status >/dev/null 2>&1
if [ -e "$tm/check-ran" ]; then
  ok "appr: an explicitly approved check executes"
else bad "appr: an explicitly approved check executes" "check did not run"; fi

# --- 73. the mcp class carries secrets the key-name scan cannot see --------
# An MCP record hides credentials in places no key-name scanner covers: a bare
# `--api-key` positional in `args`, a password inside a `postgresql://` URL, a
# `Cookie` header, an arbitrarily named `env` entry. Rather than chase every
# shape, the whole class rides the per-vendor opt-in that `auth` already uses.
# Every credential below is a synthetic string invented here.
mark "73. the mcp class rides the per-vendor opt-in"
mkdir -p "$base/mcps1" "$base/mcps2"
M1=$(peer mcps1 fleet init --machine mcps1 | awk '{print $2}')
M2=$(peer mcps2 fleet init --machine mcps2 | awk '{print $2}')
peer mcps2 fleet pair --home "$base/mcps1" \
  --code "$(peer mcps1 fleet invite --peer "$M2" 2>/dev/null)" >/dev/null 2>&1
peer mcps1 new Work >/dev/null 2>&1
m1d=$(slot mcps1 Work claude); m2d=$(slot mcps2 Work claude)
for shape in \
  'arg|{"mcpServers":{"s":{"command":"x","args":["--api-key","SYNTHETIC-MCP-ARG"]}}}|SYNTHETIC-MCP-ARG' \
  'url|{"mcpServers":{"db":{"url":"postgresql://u:SYNTHETIC-MCP-URL@h/db"}}}|SYNTHETIC-MCP-URL' \
  'cookie|{"mcpServers":{"c":{"url":"https://e","headers":{"Cookie":"sid=SYNTHETIC-MCP-COOKIE"}}}}|SYNTHETIC-MCP-COOKIE' \
  'env|{"mcpServers":{"g":{"command":"x","env":{"GH_PAT":"SYNTHETIC-MCP-ENV"}}}}|SYNTHETIC-MCP-ENV' ; do
  nm=${shape%%|*}; rest=${shape#*|}; body=${rest%|*}; tok=${rest##*|}
  put x "$m1d/.mcp.json" "$body"
  out=$(peer mcps1 fleet sync now --peer "$M2" 2>&1)
  refute "mcpclass: $nm is not offered while the vendor is opted out" \
         "pushed	mcp|Work|claude" "$out"
  if grep -qF "$tok" "$m2d/.mcp.json" 2>/dev/null; then
    bad "mcpclass: $nm does not reach the peer" "it was replicated"
  else ok "mcpclass: $nm does not reach the peer"; fi
  refute "mcpclass: $nm is not named in status either" "$tok" \
         "$(peer mcps1 fleet sync status 2>&1)"
done
# The receiver decides for itself: a sender that opts in alone changes nothing.
peer mcps1 fleet sync auth enable claude >/dev/null 2>&1
peer mcps1 fleet sync now --peer "$M2" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-MCP-ENV' "$m2d/.mcp.json" 2>/dev/null; then
  bad "mcpclass: a sender-only opt-in does not place it" "it was replicated"
else ok "mcpclass: a sender-only opt-in does not place it"; fi
# Opted in on both sides it replicates: this is an opt-in, not a ban.
peer mcps2 fleet sync auth enable claude >/dev/null 2>&1
peer mcps1 fleet sync now --peer "$M2" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-MCP-ENV' "$m2d/.mcp.json" 2>/dev/null; then
  ok "mcpclass: opted in on both sides, it does replicate"
else bad "mcpclass: opted in on both sides, it does replicate" "still withheld"; fi
# And the opt-in is per vendor, not per machine: another vendor's mcp config
# under the same profile is still out of scope.
put x "$(slot mcps1 Work codex)/.mcp.json" '{"mcpServers":{"o":{"command":"x","env":{"GH_PAT":"SYNTHETIC-MCP-OTHER"}}}}'
peer mcps1 fleet sync now --peer "$M2" >/dev/null 2>&1
if grep -qF 'SYNTHETIC-MCP-OTHER' "$(slot mcps2 Work codex)/.mcp.json" 2>/dev/null; then
  bad "mcpclass: the opt-in does not spill to another vendor" "codex replicated too"
else ok "mcpclass: the opt-in does not spill to another vendor"; fi

# --- 74. a sender's declared base answers only its own conflict ------------
# A sender that declares the base it pushed from has weighed our current bytes
# against its own, so taking its version discards nothing it had not seen --
# and its own pending conflict can retire. It says nothing about a *different*
# peer's candidate. Dropping that pin here would answer a question the operator
# never answered and destroy the bytes the pin was preserving.
mark "74. a declared sender base retires only that sender's pin"
cbase_run() {  # cbase_run <sender-of-the-fast-forward>
  cb="$base/cbase-$1"; rm -rf "$cb"; mkdir -p "$cb/home" "$cb/profiles/Work/claude"
  env HOME="$cb/home" repo="$repo" cbroot="$cb/profiles" cb="$cb" ff="$1" sh -c '
    root=$cbroot
    . "$repo/fleet.sh"; . "$repo/fleet-sync.sh"
    config_dir() { echo "$root/$1/$2"; }
    a="settings|Work|claude|settings.json"
    sync_init
    printf ORIGINAL > "$root/Work/claude/settings.json"
    d=$(sync_digest_file "$root/Work/claude/settings.json")
    sync_base_set cbase2 "$a" "$d"; sync_base_set cbase3 "$a" "$d"
    # An edit here, so both peers genuinely diverge from the agreed base.
    printf LOCAL-EDIT > "$root/Work/claude/settings.json"
    l=$(sync_digest_file "$root/Work/claude/settings.json")
    # cbase2 pushes first and raises the conflict the operator must answer.
    printf CBASE2-CANDIDATE > "$cb/from2"
    w2=$(sync_absorb "$a" "$cb/from2" "$(sync_digest_file "$cb/from2")" cbase2 "")
    own=$(sync_conflict_owner "$a" 2>/dev/null)
    # ...then $ff pushes declaring our current bytes as its base.
    printf FF-CANDIDATE > "$cb/fromff"
    w3=$(sync_absorb "$a" "$cb/fromff" "$(sync_digest_file "$cb/fromff")" "$ff" "$l")
    printf "%s|%s|%s|%s|%s" "$w2" "$own" "$w3" \
      "$(cat "$root/Work/claude/settings.json")" "$(sync_conflict_count)"
  '
}
r=$(cbase_run cbase3)
same "sendbase: cbase2's push is a conflict, not an overwrite" \
     "conflict" "$(printf '%s' "$r" | cut -d'|' -f1)"
same "sendbase: the pin names the peer whose candidate is waiting" \
     "cbase2" "$(printf '%s' "$r" | cut -d'|' -f2)"
same "sendbase: a third peer's fast-forward does not land through the pin" \
     "conflict" "$(printf '%s' "$r" | cut -d'|' -f3)"
same "sendbase: the pinned local bytes are intact" \
     "LOCAL-EDIT" "$(printf '%s' "$r" | cut -d'|' -f4)"
same "sendbase: the operator still has exactly one thing to resolve" \
     "1" "$(printf '%s' "$r" | cut -d'|' -f5)"
# Positive control: the same shape from the pin's own owner still fast-forwards,
# so this is ownership, not a blanket refusal.
r=$(cbase_run cbase2)
same "sendbase: the pin's own owner may still fast-forward" \
     "pull" "$(printf '%s' "$r" | cut -d'|' -f3)"
same "sendbase: and its own conflict retires with it" \
     "0" "$(printf '%s' "$r" | cut -d'|' -f5)"

# --- 75. approval follows the executed record across manifest replacement ---
mark "75. command approval uses the executed snapshot"
race_dir="$base/approvalrace75"
mkdir -p "$race_dir"
sed 's/^sync_tool_state()/race_original_state()/' "$repo/fleet-sync.sh" > "$race_dir/sync.sh"
race_out=$(env HOME="$race_dir" repo="$repo" sh -c '
  root="$HOME/.n2-agents"
  . "$repo/fleet.sh"; . "$HOME/sync.sh"
  sync_init
  manifest=$(sync_tools_manifest)
  approved="race75|2|printf 1|printf approved|"
  incoming="race75|2|printf 1|touch $HOME/unapproved-ran|"
  sync_tool_approve race75 "$approved"
  printf "%s\n" "$incoming" > "$manifest"
  sync_tool_state() {
    printf "%s\n" "$approved" > "$manifest"
    race_original_state "$@"
  }
  sync_tools_apply_locked
' 2>&1)
check "approval race: a replacement cannot approve the captured installer"       "pending-approval	race75" "$race_out"
if [ -e "$race_dir/unapproved-ran" ]; then
  bad "approval race: the unapproved installer never executes" "installer ran"
else ok "approval race: the unapproved installer never executes"; fi

# The suite ends here. The tally must be the last thing that runs: it is both
# the report and the exit status. It used to sit after section 55, so sections
# 56-58 ran *after* the totals were printed and the script exited with the
# status of its last assertion instead of the accumulated failure count.
if [ -n "${N2_SYNC_START_AT:-}" ] && [ "$N2_SYNC_START_AT" != 1 ]; then
  tally " (sections $N2_SYNC_START_AT-$sections of $sections)"
else
  tally " (all $sections sections)"
fi
exit $?
