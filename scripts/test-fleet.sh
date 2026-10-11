#!/bin/sh
# test-fleet.sh — multi-peer fleet transport tests.
#
# Every peer is a real `agents` process with its own HOME, its own fleet
# identity key and its own roster. Peers talk over the `exec` carrier, which
# differs from tailscale/ssh only in how bytes reach `agents fleet serve`:
# signing, roster lookup, approval state, freshness and replay checks are the
# same code on both sides. Nothing here touches the user's real fleet.
set -u
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2fleet-test.XXXXXX")
pass=0; fail=0; skipped=0
# Only the main shell may tear the fixture down. A backgrounded subshell
# inherits this EXIT trap in POSIX sh, so without a guard the first `&` job to
# finish deletes $base out from under every later section -- which looks
# exactly like a product bug in whichever section runs next.
#
# `$$` CANNOT be that guard: POSIX keeps $$ pointing at the original shell
# inside every subshell, so `[ "$$" = "$main_pid" ]` is true in the subshell
# too and guards nothing. Ask the kernel instead: a freshly exec'd child's
# $PPID is the real pid of whichever process is running cleanup right now.
# The probe writes to a file rather than a $(...) capture on purpose -- a
# command substitution would fork first and report *its* pid.
#
# This matters beyond the `&` jobs. On bash 3.2 (/bin/sh on macOS) killing a
# job while a TERM trap is installed can corrupt trap_list and make the shell
# resend SIGTERM to itself mid-run; the handler then fired the destructive
# cleanup while the suite was still running. That is what removed $base
# between sections 32 and 33 and made every m1 assertion in sections 33/34
# report "no fleet identity yet".
main_pid=$$
pidprobe=$base/.pidprobe
is_main() {  # true only in the process that started this script
  probe=$(mktemp "$pidprobe.XXXXXX" 2>/dev/null) || return 0
  # NOTE: the redirection must be written inline, not wrapped in $(...).
  # `rp=$(helper)` forks first, so the helper would report the substitution
  # subshell's pid and is_main would be false even in the main shell.
  sh -c 'echo $PPID' > "$probe" 2>/dev/null
  rp=$(cat "$probe" 2>/dev/null); rm -f "$probe" 2>/dev/null
  [ -z "$rp" ] || [ "$rp" = "$main_pid" ]
}

cleanup() { is_main || return 0; [ -n "${N2_FLEET_KEEP:-}" ] || { chmod -R u+w "$base" 2>/dev/null; rm -rf "$base"; }; }
# SIGTERM is deliberately NOT trapped. A TERM handler that deletes the fixture
# is a handler that can delete it *without ending the run* -- the handler
# returns and the suite keeps going against a fixture that no longer exists.
# The bash 3.2 self-resend above delivered exactly that. EXIT covers every way
# this script finishes, INT covers the operator's Ctrl-C, and a real TERM now
# ends the shell by default (leaving the tmpdir behind, which is recoverable;
# a half-deleted fixture mid-run is not).
on_signal() { is_main || return 0; trap - EXIT INT; cleanup; exit 130; }
trap cleanup EXIT
trap on_signal INT

ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ # check <name> <expected-substring> <actual>
  case $3 in *"$2"*) ok "$1" ;; *) bad "$1" "want '$2' in '$3'" ;; esac; }
refute(){ # refute <name> <forbidden-substring> <actual>
  case $3 in *"$2"*) bad "$1" "did not want '$2' in '$3'" ;; *) ok "$1" ;; esac; }
# A skipped section is not a pass. N2_FLEET_REQUIRE_LIVE_SSH=1 turns every
# skip into a failure, so "0 failed" can be quoted as evidence that the
# live-transport checks actually ran instead of silently vanishing.
skip() { # skip <name> <reason>
  if [ -n "${N2_FLEET_REQUIRE_LIVE_SSH:-}" ]; then
    bad "$1" "required live-ssh section skipped: ${2:-}"
  else
    skipped=$((skipped+1)); printf 'SKIP %s: %s\n' "$1" "${2:-}"
  fi; }
denied(){ # denied <name> <actual-output> <rc>
  if [ "$3" = 0 ]; then bad "$1" "request succeeded but must be refused: $2"; else ok "$1"; fi; }

peer() { h=$1; shift; env HOME="$base/$h" N2_FLEET_AGENTS="$repo/agents" "$repo/agents" "$@"; }
# run raw fleet shell in a peer's context (for tests that must bypass the CLI)
raw()  { h=$1; shift; env HOME="$base/$h" N2_FLEET_AGENTS="$repo/agents" sh -c \
           "root=\$HOME/.n2-agents; self=\"$repo/agents\"; . \"$repo/fleet.sh\"; $*"; }
fpof() { peer "$1" fleet id | awk '{print $2}'; }

# Section progress with wall-clock cost. The suite is one long sequence -- a
# later section reuses fixtures an earlier one built -- so sections cannot be
# run a la carte. What an operator needs instead is to see, from the log
# alone, which section a run reached and what each one cost. `mark` prints
# both: elapsed seconds since the run started and the per-section delta.
t0=$(date +%s); tprev=$t0
mark() {
  now=$(date +%s)
  printf '# --- %s  [t+%ss, prev %ss]\n' "$1" "$((now-t0))" "$((now-tprev))"
  tprev=$now
}

for h in alpha beta gamma; do mkdir -p "$base/$h"; peer "$h" fleet init --machine "$h" >/dev/null; done
A=$(fpof alpha); B=$(fpof beta); G=$(fpof gamma)
echo "# alpha=$A"; echo "# beta=$B"; echo "# gamma=$G"

# --- 1. identity-bound pairing --------------------------------------------
mark "1. identity-bound pairing"
code=$(peer alpha fleet invite --peer "$B" 2>/dev/null)
out=$(peer beta fleet pair --home "$base/alpha" --code "$code" 2>&1)
check "pair: bound code enrolls beta on alpha" "approved" "$out"
check "pair: beta records alpha approved" "approved" "$(peer beta fleet peers --no-probe | grep -F "$A")"
check "pair: alpha records beta approved" "approved" "$(peer alpha fleet peers --no-probe | grep -F "$B")"

# --- 2. signed round trip over the carrier ---------------------------------
mark "2. signed round trip over the carrier"
check "ping: beta -> alpha" "pong alpha" "$(peer beta fleet ping "$A" 2>&1)"
check "ping: alpha -> beta" "pong beta" "$(peer alpha fleet ping "$B" 2>&1)"
check "status: alpha reports beta online" "online" "$(peer alpha fleet peers | grep -F "$B")"

# --- 3. a code minted for one peer does not enroll another -----------------
mark "3. a code minted for one peer does not enroll another"
code2=$(peer alpha fleet invite --peer "$B" 2>/dev/null)
out=$(peer gamma fleet pair --home "$base/alpha" --code "$code2" 2>&1); rc=$?
denied "enroll: wrong identity refused" "$out" "$rc"
check  "enroll: wrong identity reason" "wrong-identity" "$out"
if peer alpha fleet peers --no-probe | grep -qF "$G"; then
  bad "enroll: wrong-identity peer not in roster" "gamma present"; else
  ok  "enroll: wrong-identity peer not in roster"; fi

# --- 4. reachability is not authorization ----------------------------------
mark "4. reachability is not authorization"
# gamma joins with no code: it lands in alpha's pending list, nothing more.
out=$(peer gamma fleet join --transport exec --home "$base/alpha" 2>&1)
check "enroll: uncoded join stays pending" "pending" "$out"
check "enroll: alpha lists gamma pending" "$G" "$(peer alpha fleet pending)"
# gamma now lies locally and marks alpha-side approval itself; the server must
# still refuse, because approval lives in alpha's roster, not gamma's claim.
raw gamma "fleet_meta_set \"\$(fleet_peer_dir '$A')\" state approved" >/dev/null
out=$(peer gamma fleet ping "$A" 2>&1); rc=$?
denied "serve: unapproved peer refused" "$out" "$rc"
check  "serve: unapproved reason" "not-approved" "$out"

# --- 5. replay of a captured request is refused ----------------------------
mark "5. replay of a captured request is refused"
raw beta "fleet_envelope '$A' ping /dev/null > $base/replay.req" >/dev/null
first=$(raw beta "fleet_carry \"\$(fleet_peer_dir '$A')\" < $base/replay.req" 2>/dev/null | head -1)
again=$(raw beta "fleet_carry \"\$(fleet_peer_dir '$A')\" < $base/replay.req" 2>/dev/null | head -1)
check "replay: first delivery accepted" "OK" "$first"
check "replay: second delivery refused" "ERR replay" "$again"

# --- 5b. the same envelope delivered concurrently is accepted exactly once --
mark "5b. the same envelope delivered concurrently is accepted exactly once"
# Sequential replay only proves the nonce is remembered afterwards. The real
# adversary sends the captured envelope to many receivers at once; if the
# nonce is checked and then written, every one of them reads "absent" and
# every one of them accepts. Each fleet_carry below is its own process and its
# own receiver against the one shared alpha root, so this races the reservation
# for real rather than simulating it.
raw beta "fleet_envelope '$A' ping /dev/null > $base/conc.req" >/dev/null
mkdir -p "$base/conc"
i=0; while [ "$i" -lt 16 ]; do
  # Defence in depth: drop the inherited traps before this subshell can exit
  # with the fixture-removing EXIT handler still installed.
  ( trap - EXIT INT TERM
    raw beta "fleet_carry \"\$(fleet_peer_dir '$A')\" < $base/conc.req" ) \
    > "$base/conc/$i.out" 2>/dev/null &
  i=$((i+1))
done
wait
accepted=$(cat "$base/conc"/*.out | grep -c '^OK' || true)
refused=$(cat "$base/conc"/*.out | grep -c '^ERR replay' || true)
if [ "$accepted" = 1 ]; then ok "replay: 16 concurrent deliveries accepted exactly once"
else bad "replay: 16 concurrent deliveries accepted exactly once" "accepted=$accepted"; fi
if [ "$refused" = 15 ]; then ok "replay: every concurrent loser is told 'replay'"
else bad "replay: every concurrent loser is told 'replay'" "replay-refusals=$refused of 15"; fi

# --- 6. approval and the fleet survive without the first machine -----------
mark "6. approval and the fleet survive without the first machine"
codeG=$(peer beta fleet invite --peer "$G" 2>/dev/null)
out=$(peer gamma fleet pair --home "$base/beta" --code "$codeG" 2>&1)
check "independence: beta enrolls gamma without alpha" "approved" "$out"
mv "$base/alpha" "$base/alpha.offline"          # the originating machine goes away
check "independence: beta sees alpha offline" "offline" "$(peer beta fleet peers | grep -F "$A")"
check "independence: beta <-> gamma still works" "pong gamma" "$(peer beta fleet ping "$G" 2>&1)"
check "independence: gamma <-> beta still works" "pong beta" "$(peer gamma fleet ping "$B" 2>&1)"
mv "$base/alpha.offline" "$base/alpha"

# --- 7. revocation ends access immediately ---------------------------------
mark "7. revocation ends access immediately"
peer beta fleet revoke "$G" >/dev/null
out=$(peer gamma fleet ping "$B" 2>&1); rc=$?
denied "revoke: revoked peer refused" "$out" "$rc"
check  "revoke: revoked reason" "revoked" "$out"
if peer beta fleet peers --no-probe | grep -qF "$G"; then
  bad "revoke: peer removed from roster" "gamma still listed"; else
  ok  "revoke: peer removed from roster"; fi

# --- 8. an unbound invite pairs but does not approve ------------------------
mark "8. an unbound invite pairs but does not approve"
# The secret proves the joiner holds the code; it does not say which key the
# operator meant. `fleet invite` promises 'pending', so the server must agree.
mkdir -p "$base/delta"; peer delta fleet init --machine delta >/dev/null; D=$(fpof delta)
ucode=$(peer alpha fleet invite 2>/dev/null)
out=$(peer delta fleet join --transport exec --home "$base/alpha" --code "$ucode" 2>&1)
check "invite: unbound code does not approve" "pending" "$out"
if peer alpha fleet peers --no-probe | grep -qF "$D"; then
  bad "invite: unbound code leaves peer out of roster" "delta in roster"; else
  ok  "invite: unbound code leaves peer out of roster"; fi
out=$(peer delta fleet ping "$A" 2>&1); rc=$?
denied "invite: unbound-code peer still cannot call" "$out" "$rc"
check  "invite: alpha lists delta pending" "$D" "$(peer alpha fleet pending)"

# --- 9. a malformed code id cannot reach outside the invite directory -------
mark "9. a malformed code id cannot reach outside the invite directory"
: > "$base/alpha/.n2-agents/traversal-sentinel"
raw delta "fleet_enroll_request exec '' '' '$base/alpha' '' >/dev/null 2>&1" >/dev/null 2>&1
out=$(raw delta "etmp=\$(mktemp -d); { printf 'machine=delta\\ntransport=exec\\naddress=x\\nuser=u\\nhome=%s\\n' \"\$HOME\"; \
   printf 'key=%s\\n' \"\$(awk '{print \$1\" \"\$2}' \"\$(fleet_key).pub\")\"; \
   printf 'codeid=../traversal-sentinel\\ntag=x\\n'; } > \$etmp/p; \
   fleet_envelope any enroll \$etmp/p > \$etmp/req; \
   fleet_carry \"\$(fleet_peer_dir '$A')\" < \$etmp/req" 2>&1 | head -1)
check "traversal: malformed code id refused" "ERR malformed-code" "$out"
if [ -f "$base/alpha/.n2-agents/traversal-sentinel" ]; then
  ok  "traversal: file outside invites untouched"; else
  bad "traversal: file outside invites untouched" "sentinel deleted by enroll handler"; fi

# --- 10. re-running init must not resurrect revoked peers -------------------
mark "10. re-running init must not resurrect revoked peers"
peer alpha fleet revoke "$D" >/dev/null
peer alpha fleet init --machine alpha >/dev/null
check "init: revocation survives re-init" "revoked" "$(raw alpha "fleet_peer_state '$D'" 2>&1)"

# --- 11. packaged resources contain everything `agents` sources -------------
mark "11. packaged resources contain everything `agents` sources"
pkg=$base/pkg; mkdir -p "$pkg"
for f in $(grep -o '\.\./[A-Za-z0-9._-]*' "$repo/tray/build.sh" | sed 's|^\.\./||' | sort -u); do
  [ -f "$repo/$f" ] && cp "$repo/$f" "$pkg/"; done
if [ -f "$pkg/agents" ]; then
  out=$(env HOME="$base/alpha" sh "$pkg/agents" version 2>&1); rc=$?
  if [ "$rc" = 0 ]; then ok "packaging: agents runs from bundled resources"; else
    bad "packaging: agents runs from bundled resources" "$out"; fi
else bad "packaging: agents runs from bundled resources" "agents not copied by tray/build.sh"; fi

# --- 12. secrets stay out of the journal ------------------------------------
mark "12. secrets stay out of the journal"
if grep -rqF "$code" "$base/alpha/.n2-agents/fleet" 2>/dev/null; then
  bad "secrets: pairing code not stored in the clear" "code found under fleet state"; else
  ok  "secrets: pairing code not stored in the clear"; fi
if grep -rq "PRIVATE KEY" "$base/alpha/.n2-agents/fleet/events.log" 2>/dev/null; then
  bad "secrets: no key material in events.log" "key material present"; else
  ok  "secrets: no key material in events.log"; fi

# --- 13. hub-free trust: a member's approval is fleet-wide -----------------
mark "13. hub-free trust: a member's approval is fleet-wide"
# epsilon is the only machine both zeta and eta enrolled through. Its approval
# of eta must reach zeta with no step on zeta, and eta must learn zeta, and
# the link must keep working once epsilon is gone: no required central hub.
for h in epsilon zeta eta; do mkdir -p "$base/$h"; peer "$h" fleet init --machine "$h" >/dev/null; done
E=$(fpof epsilon); Z=$(fpof zeta); H=$(fpof eta)
peer zeta fleet pair --home "$base/epsilon" --code "$(peer epsilon fleet invite --peer "$Z" 2>/dev/null)" >/dev/null 2>&1
out=$(peer eta fleet pair --home "$base/epsilon" --code "$(peer epsilon fleet invite --peer "$H" 2>/dev/null)" 2>&1)
check "fleet-wide: zeta enrolled on epsilon" "approved" "$(peer epsilon fleet peers --no-probe | grep -F "$Z")"
check "fleet-wide: the newcomer adopts epsilon's members as it joins" "adopted	$Z" "$out"
check "fleet-wide: zeta holds eta approved with no step on zeta" "approved" "$(raw zeta "fleet_peer_state '$H'")"
check "fleet-wide: zeta records epsilon as the approver" "$E" \
  "$(raw zeta "fleet_meta \"\$(fleet_peer_dir '$H')\" added_by")"
check "fleet-wide: eta holds zeta approved" "approved" "$(raw eta "fleet_peer_state '$Z'")"
check "fleet-wide: zeta -> eta round trip on the referrer's route" "pong eta" "$(peer zeta fleet ping "$H" 2>&1)"
out=$(peer zeta fleet discover 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "fleet-wide: discover with nothing new succeeds"
else bad "fleet-wide: discover with nothing new succeeds" "rc=$rc: $out"; fi
if [ -z "$(ls "$base/zeta/.n2-agents/fleet/pending" 2>/dev/null)" ]; then
  ok "fleet-wide: discover files no pending request for a known member"
else bad "fleet-wide: discover files no pending request for a known member" "$(ls "$base/zeta/.n2-agents/fleet/pending")"; fi
# a neighbour that advertises a key not matching the id it names is dropped
raw zeta "fleet_fp \"\$(fleet_peer_dir '$H')/key.pub\"" > "$base/dkey" 2>&1
check "fleet-wide: recorded key matches the advertised peer id" "$H" "$(cat "$base/dkey")"

# --- 14. an adopted member keeps working without the introducer ------------
mark "14. an adopted member keeps working without the introducer"
mv "$base/epsilon" "$base/epsilon.offline"   # introducer is gone
out=$(peer zeta fleet ping "$H" 2>&1)
check "independent: adopted peers talk with the introducer offline" "pong" "$out"
out=$(peer zeta fleet peers 2>&1)
check "independent: epsilon shows offline, not fatal" "offline" "$out"
check "independent: eta still reachable in the same listing" "online" "$out"
mv "$base/epsilon.offline" "$base/epsilon"

# --- 15. revocation propagates one hop to approved peers --------------------
mark "15. revocation propagates one hop to approved peers"
out=$(peer epsilon fleet revoke --propagate "$H" 2>&1)
check "revoke: propagation reports the fan-out" "propagate" "$out"
check "revoke: zeta honours the propagated revocation" "revoked" "$(raw zeta "fleet_peer_state '$H'" 2>&1)"
out=$(peer zeta fleet ping "$H" 2>&1); rc=$?
denied "revoke: propagated revocation blocks calls" "$out" "$rc"
out=$(raw eta "rvpf=\$(mktemp); printf 'peer=%s\n' '$Z' > \$rvpf; fleet_call '$Z' revoke \$rvpf" 2>&1); rc=$?
denied "revoke: a revoked peer cannot revoke back" "$out" "$rc"
out=$(raw zeta "rvpf=\$(mktemp); printf 'peer=%s\n' \"\$(fleet_self_id)\" > \$rvpf; fleet_handle_revoke '$E' \$rvpf \$(mktemp -d)" 2>&1)
check "revoke: a peer cannot be made to revoke itself" "ERR refuse-self-revoke" "$out"

# --- 16. ssh host key pinning is authority, so it is bounded ---------------
mark "16. ssh host key pinning is authority, so it is bounded"
# A known_hosts line the peer supplies decides which host key this machine
# will later trust. These check that a peer cannot widen that authority, and
# that approval will not silently trust an unverified host key.
hk=$base/hostkey; ssh-keygen -q -t ed25519 -N '' -f "$hk" </dev/null
hkfp=$(ssh-keygen -lf "$hk.pub" | awk '{print $2}')
hkline="testhost.example $(awk '{print $1" "$2}' "$hk.pub")"

# `check ... ""` would pass on any output at all, so assert emptiness directly.
cao=$(printf '@cert-authority * ssh-ed25519 AAAAC3Nz\n' | raw alpha 'fleet_host_line' 2>&1)
if [ -z "$cao" ]; then ok "hostkey: a cert-authority marker is not a host line"
else bad "hostkey: a cert-authority marker is not a host line" "emitted '$cao'"; fi
check "hostkey: a plain host line survives" "$hkline" \
  "$(printf '%s\n' "$hkline" | raw alpha 'fleet_host_line' 2>&1)"
check "hostkey: only the first line of a multi-line claim is taken" \
  "1" "$(printf '%s\nother.example ssh-ed25519 AAAAB\n' "$hkline" | raw alpha 'fleet_host_line' | wc -l | tr -d ' ')"

# a stored record poisoned before this check existed must not reach known_hosts
poison="@cert-authority * $(awk '{print $1" "$2}' "$hk.pub")"
raw alpha "printf '%s\n' \"$poison\" > \$(fleet_peer_dir '$B')/host.pub" >/dev/null 2>&1
check "hostkey: the poisoned record really is on disk" "cert-authority" \
  "$(raw alpha "cat \$(fleet_peer_dir '$B')/host.pub" 2>&1)"
out=$(raw alpha 'cat "$(fleet_known_hosts)"' 2>&1)
case $out in *cert-authority*) bad "hostkey: known_hosts never carries a cert-authority marker" "$out" ;;
  *) ok "hostkey: known_hosts never carries a cert-authority marker" ;; esac

raw alpha "rm -f \$(fleet_peer_dir '$B')/host.pub; fleet_known_hosts" >/dev/null 2>&1

# approval will not pin an ssh peer that arrived without a host key
gpub=$(raw gamma 'cat "$(fleet_key).pub"' 2>/dev/null)
# alpha adopted gamma when beta approved it (section 6); start from a request.
mkpend() { raw alpha "rm -rf \$(fleet_peer_dir '$G'); pd=\$(fleet_pending_dir '$G'); rm -rf \$pd; mkdir -p \$pd; \
  printf '%s\n' \"$gpub\" > \$pd/key.pub; fleet_meta_set \$pd peer '$G'; \
  fleet_meta_set \$pd machine gamma; fleet_meta_set \$pd transport ssh; \
  fleet_meta_set \$pd address gamma.example; fleet_meta_set \$pd state pending; \
  ${1:-true}"; }
mkpend >/dev/null 2>&1
out=$(peer alpha fleet approve "$G" 2>&1); rc=$?
denied "hostkey: ssh peer without a host key is not approved" "$out" "$rc"
check "hostkey: refusal names the out-of-band remedy" "--host-fp" "$out"
check "hostkey: the refused peer stays unapproved" "pending" "$(raw alpha "fleet_peer_state '$G'" 2>&1)"

mkpend >/dev/null 2>&1
out=$(peer alpha fleet approve "$G" --no-host-key 2>&1)
check "hostkey: --no-host-key is the explicit escape hatch" "approved" "$out"
check "hostkey: an unpinned approval is recorded as such" "unpinned" \
  "$(raw alpha "fleet_meta \$(fleet_peer_dir '$G') host_fp" 2>&1)"
raw alpha "rm -rf \$(fleet_peer_dir '$G')" >/dev/null 2>&1

mkpend "printf '%s\n' \"$hkline\" > \$pd/host.pub" >/dev/null 2>&1
out=$(peer alpha fleet approve "$G" --host-fp SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1); rc=$?
denied "hostkey: a mismatched fingerprint is refused" "$out" "$rc"
check "hostkey: mismatch is not approved" "pending" "$(raw alpha "fleet_peer_state '$G'" 2>&1)"
out=$(peer alpha fleet approve "$G" --host-fp "$hkfp" 2>&1)
check "hostkey: the verified fingerprint approves" "approved" "$out"
check "hostkey: the pinned fingerprint is recorded" "$hkfp" \
  "$(raw alpha "fleet_meta \$(fleet_peer_dir '$G') host_fp" 2>&1)"
check "hostkey: the pinned key lands under a peer alias in fleet known_hosts" "n2-peer-" \
  "$(raw alpha 'cat "$(fleet_known_hosts)"' 2>&1)"

# the ssh carrier never disables host verification
sshopts=$(raw alpha 'fleet_ssh_opts' 2>&1)
check "hostkey: carrier keeps strict host checking" "StrictHostKeyChecking=yes" "$sshopts"
check "hostkey: carrier reads the fleet known_hosts" "UserKnownHostsFile=" "$sshopts"
case $sshopts in *StrictHostKeyChecking=no*|*"known_hosts=/dev/null"*)
  bad "hostkey: carrier never opts out of verification" "$sshopts" ;;
  *) ok "hostkey: carrier never opts out of verification" ;; esac
raw alpha "fleet_revoke '$G'" >/dev/null 2>&1

# --- 17. the verb table is discoverable and matches the documented surface ---
mark "17. the verb table is discoverable and matches the documented surface"
uh=$(peer alpha fleet help 2>&1)
check "help: lists the enrollment verbs" "approve <peerid>" "$uh"
check "help: lists the transport verbs" "serve" "$uh"
bogus=$(peer alpha fleet nosuchverb 2>&1); brc=$?
denied "help: an unknown verb is an error" "$bogus" "$brc"
check "help: an unknown verb still prints the verb table" "agents fleet <verb>" "$bogus"
# help must work before `fleet init`, when there is no identity to need
mkdir -p "$base/nobody"
check "help: works without a fleet identity" "agents fleet <verb>" \
  "$(env HOME="$base/nobody" N2_FLEET_AGENTS="$repo/agents" "$repo/agents" fleet help 2>&1)"
# Every verb the dispatcher answers must be documented and completable. The
# list is read out of cmd_fleet itself rather than copied here: a hard-coded
# list drifts silently the moment a verb is added (`route` did exactly that),
# which is the failure this check exists to catch.
fleet_verbs=$(awk '/^cmd_fleet\(\)/{d=1} d&&/^}/{d=0} d&&/^    [a-z][a-z|-]*\)/ {
    line=$0; sub(/^ +/,"",line); sub(/\).*/,"",line)
    n=split(line,a,"|"); for(i=1;i<=n;i++) if (a[i] !~ /^-/) print a[i] }' "$repo/fleet.sh")
[ -n "$fleet_verbs" ] || bad "help: the dispatcher verb list could be read" "awk found no case arms"
# every verb the dispatcher answers is really documented
for v in $fleet_verbs; do
  case $uh in *"
  $v"*|*"
  $v "*) ok "help: documents the '$v' verb" ;; *) bad "help: documents the '$v' verb" "$uh" ;; esac
done

# every verb is also offered by each shell's completion, so the tab-completed
# surface cannot drift away from the dispatched one
for f in shell/agents.zsh shell/agents.bash shell/agents.fish; do
  miss=
  for v in $fleet_verbs; do
    case $v in help) continue ;; esac
    grep -q "[ '\"]$v[ '\"]" "$repo/$f" || miss="$miss $v"
  done
  grep -q "fleet" "$repo/$f" || miss="$miss fleet"
  if [ -n "$miss" ]; then bad "completion: $f offers every fleet verb" "missing:$miss"
  else ok "completion: $f offers every fleet verb"; fi
done

# --- 18. a refused approval leaves the request approvable/deniable ---------
mark "18. a refused approval leaves the request approvable/deniable"
# delta asks to join epsilon with no host key; epsilon's approval must fail
# closed *and* keep the request, or the operator has no way back.
for h in delta epsilon; do mkdir -p "$base/$h"; peer "$h" fleet init --machine "$h" >/dev/null; done
D=$(fpof delta); E=$(fpof epsilon)
peer delta fleet join --transport exec --home "$base/epsilon" >/dev/null 2>&1
# Re-file the request as an ssh peer with no host key: that is the shape that
# demands an out-of-band pin. (An exec test peer still forwards this machine's
# real host key, so it has to be cleared for the missing-pin case.)
raw epsilon "pd=\$(fleet_pending_dir '$D'); fleet_meta_set \"\$pd\" transport ssh; rm -f \"\$pd/host.pub\"" >/dev/null 2>&1
out=$(peer epsilon fleet approve "$D" 2>&1); rc=$?
denied "approve: no host key refuses" "$out" "$rc"
check  "approve: refusal explains the fix" "--host-fp" "$out"
check  "approve: refused request survives" "$D" "$(peer epsilon fleet pending 2>&1)"
if peer epsilon fleet peers --no-probe 2>/dev/null | grep -qF "$D"; then
  bad "approve: refused request did not become a peer" "delta present in roster"
else ok "approve: refused request did not become a peer"; fi
out=$(peer epsilon fleet deny "$D" 2>&1); drc=$?
if [ "$drc" = 0 ]; then ok "approve: a refused request can still be denied"
else bad "approve: a refused request can still be denied" "$out"; fi

# --- 19. approval grants inbound ssh; revocation takes it back -------------
mark "19. approval grants inbound ssh; revocation takes it back"
ak=$base/authorized_keys
peer delta fleet join --transport exec --home "$base/epsilon" >/dev/null 2>&1
raw epsilon "pd=\$(fleet_pending_dir '$D'); fleet_meta_set \"\$pd\" transport ssh; rm -f \"\$pd/host.pub\"" >/dev/null 2>&1
env N2_FLEET_AUTHORIZED_KEYS="$ak" HOME="$base/epsilon" N2_FLEET_AGENTS="$repo/agents" \
  "$repo/agents" fleet approve "$D" --no-host-key >/dev/null 2>&1
check "authkeys: approval writes the peer's inbound grant" "n2-fleet:$D" "$(cat "$ak" 2>&1)"
check "authkeys: the grant is restricted to fleet serve" 'command="' "$(cat "$ak" 2>&1)"
check "authkeys: the grant carries the peer's own key" \
  "$(awk '{print $2}' "$base/delta/.n2-agents/fleet/identity/id_ed25519.pub")" \
  "$(cat "$ak" 2>&1)"
printf 'ssh-ed25519 AAAAsomeoneelse unrelated@key\n' >> "$ak"
env N2_FLEET_AUTHORIZED_KEYS="$ak" HOME="$base/epsilon" N2_FLEET_AGENTS="$repo/agents" \
  "$repo/agents" fleet revoke "$D" >/dev/null 2>&1
if grep -q "n2-fleet:$D" "$ak"; then
  bad "authkeys: revocation removes the inbound grant" "$(cat "$ak")"
else ok "authkeys: revocation removes the inbound grant"; fi
check "authkeys: revocation leaves unrelated keys alone" "unrelated@key" "$(cat "$ak" 2>&1)"
# an exec-carrier test peer is never granted ssh access
if grep -q "n2-fleet:$B" "$base/alpha/.ssh/authorized_keys" 2>/dev/null; then
  bad "authkeys: exec peers get no ssh grant" "beta granted on alpha"
else ok "authkeys: exec peers get no ssh grant"; fi

# --- 20. an ssh enrollment will not start without a pinned host key --------
mark "20. an ssh enrollment will not start without a pinned host key"
out=$(peer delta fleet pair --to 198.51.100.7 --code deadbeef --user nobody 2>&1); rc=$?
denied "bootstrap: ssh pairing without a host key refuses" "$out" "$rc"
check  "bootstrap: refusal names the fix" "--host-key" "$out"
out=$(peer delta fleet pair --to 198.51.100.7 --code deadbeef --user nobody \
        --host-key "not a host key" 2>&1); rc=$?
denied "bootstrap: a malformed host key is refused" "$out" "$rc"
peer delta fleet pair --to 198.51.100.7 --code deadbeef --user nobody \
  --host-key "$hkline" >/dev/null 2>&1
hkkey=$(awk '{print $1" "$2}' "$hk.pub")
check "bootstrap: a supplied host key is pinned for the first hop" "$hkkey" \
  "$(raw delta 'cat "$fleet_root/known_hosts"' 2>&1)"
# The first hop has no peer record yet, so its pin is filed under the
# single-use bootstrap alias — never under the address, which any later
# machine answering that address would otherwise inherit.
check "bootstrap: the pin is keyed to the single-use bootstrap alias" \
  "n2-bootstrap " "$(raw delta 'cat "$fleet_root/known_hosts"' 2>&1)"
refute "bootstrap: the pin is not keyed to the address dialled" \
  "198.51.100.7 " "$(raw delta 'cat "$fleet_root/known_hosts"' 2>&1)"
# `id --host-key` is what the operator copies; it must be a line the other
# machine's own parser accepts, or an explicit failure — never empty success.
idhk=$(peer delta fleet id --host-key 2>&1); idrc=$?
if [ "$idrc" != 0 ]; then
  check "id: --host-key fails loudly when there is no host key" "no ssh host key" "$idhk"
else
  parsed=$(printf '%s\n' "$idhk" | raw delta 'fleet_host_line')
  if [ -n "$parsed" ]; then ok "id: --host-key prints a line fleet_host_line accepts"
  else bad "id: --host-key prints a line fleet_host_line accepts" "rejected '$idhk'"; fi
fi

# --- 21. revocation reaches a peer that was offline when it happened -------
mark "21. revocation reaches a peer that was offline when it happened"
# Three fresh peers so the earlier sections' state cannot mask the result.
for h in rc1 rc2 rc3; do mkdir -p "$base/$h"; peer "$h" fleet init --machine "$h" >/dev/null; done
E=$(fpof rc1); Z=$(fpof rc2); T=$(fpof rc3)
mutual() { # mutual <host-peer> <joining-peer-id> <joining-peer>
  c=$(peer "$1" fleet invite --peer "$2" 2>/dev/null)
  peer "$3" fleet pair --home "$base/$1" --code "$c" 2>&1; }
# Discard the join transcripts: only the rc2<->rc3 one below is asserted on,
# and an uncaptured `mutual` prints the host-key line straight into the report.
# rc1's approval of rc3 is fleet-wide, so rc2 holds rc3 approved with no
# pairing of its own.
mutual rc1 "$Z" rc2 >/dev/null; mutual rc1 "$T" rc3 >/dev/null
check "reconcile: rc2 starts out knowing rc3 approved" "approved" \
  "$(peer rc2 fleet peers --no-probe | grep -F "$T")"

# rc2 goes offline (its exec endpoint stops answering), then rc1 cuts rc3 off.
mv "$base/rc2" "$base/rc2.off"
prop=$(peer rc1 fleet revoke --propagate "$T" 2>&1)
check "reconcile: propagation reports the offline peer as failed" "fail" "$prop"
# A call to an absent peer makes `agents` re-create the HOME dir, so the
# restore must not nest the saved one inside it.
rm -rf "$base/rc2"; mv "$base/rc2.off" "$base/rc2"
if peer rc2 fleet peers --no-probe | grep -qF "$T"; then
  ok "reconcile: the offline peer kept a stale approved record"
else bad "reconcile: the offline peer kept a stale approved record" "rc3 already gone — test premise broken"; fi

out=$(peer rc2 fleet reconcile 2>&1)
check "reconcile: reconnecting rc2 learns of the revocation" "$T" "$out"
if peer rc2 fleet peers --no-probe | grep -qF "$T"; then
  bad "reconcile: revoked peer removed from the roster" "rc3 still present"
else ok "reconcile: revoked peer removed from the roster"; fi
out=$(peer rc2 fleet ping "$T" 2>&1); rc=$?
denied "reconcile: the revoked peer can no longer be called" "$out" "$rc"

# A neighbour cannot revoke *us*, or itself, by putting the id in its list.
# Only the reply is stubbed: rc2 answering with rc1's own id would make it
# refuse rc1 first, and the list would never be read.
out=$(raw rc1 'fleet_call() { [ "$2" = revocations ] && printf "%s\\n" "'"$E"'" "'"$Z"'"; }; fleet_reconcile' 2>&1)
refute "reconcile: rc1 reads an approved peer's list" "no approved peers" "$out"
refute "reconcile: nothing in that list is adopted" "revoked" "$out"
if raw rc1 'fleet_revoked "'"$E"'"'; then
  bad "reconcile: a peer cannot revoke us through its own list" "rc1 revoked itself"
else ok "reconcile: a peer cannot revoke us through its own list"; fi
if raw rc1 'fleet_revoked "'"$Z"'"'; then
  bad "reconcile: a peer cannot revoke itself through its own list" "rc1 revoked rc2"
else ok "reconcile: a peer cannot revoke itself through its own list"; fi

# --- 22. host key rotation for an already-approved peer --------------------
mark "22. host key rotation for an already-approved peer"
ssh-keygen -q -t ed25519 -N '' -C rot -f "$base/rot" </dev/null
rotline="rc2-new-host $(awk '{print $1" "$2}' "$base/rot.pub")"
rotfp=$(ssh-keygen -lf "$base/rot.pub" | awk '{print $2}')
rothome=$(raw rc1 'fleet_meta "$(fleet_peer_dir "'"$Z"'")" address')
rpf=$base/rehost.payload; printf 'host=%s\n' "$rotline" > "$rpf"
out=$(peer rc2 fleet send "$E" --verb rehost --payload-file "$rpf" 2>&1)
check "rehost: an approved peer can move its own pin" "$rotfp" "$out"
check "rehost: rc1 pinned the new key" "$rotfp" \
  "$(raw rc1 'fleet_host_fp "$(fleet_peer_dir "'"$Z"'")/host.pub"')"
rotalias=$(raw rc1 'fleet_alias "$(fleet_peer_dir "'"$Z"'")"')
check "rehost: the new pin is keyed to rc2's per-peer alias" "$rotalias " \
  "$(raw rc1 'cat "$(fleet_peer_dir "'"$Z"'")/host.pub"')"
refute "rehost: the new pin is not keyed to the address rc1 dials" "$rothome " \
  "$(raw rc1 'cat "$(fleet_peer_dir "'"$Z"'")/host.pub"')"
check "rehost: known_hosts carries the rotation" "$(awk '{print $2}' "$base/rot.pub")" \
  "$(raw rc1 'cat "$(fleet_known_hosts)"')"

# A stranger cannot move anyone's pin: rc3 is revoked on rc1, so its signed
# rehost never reaches the handler at all.
out=$(peer rc3 fleet send "$E" --verb rehost --payload-file "$rpf" 2>&1); rc=$?
denied "rehost: a revoked peer cannot move a pin" "$out" "$rc"
check "rehost: rc1 still holds rc2's rotated key" "$rotfp" \
  "$(raw rc1 'fleet_host_fp "$(fleet_peer_dir "'"$Z"'")/host.pub"')"

printf 'host=%s\n' "not a host key line at all" > "$rpf"
out=$(peer rc2 fleet send "$E" --verb rehost --payload-file "$rpf" 2>&1); rc=$?
denied "rehost: a malformed key is refused" "$out" "$rc"
check "rehost: the refusal left the good pin in place" "$rotfp" \
  "$(raw rc1 'fleet_host_fp "$(fleet_peer_dir "'"$Z"'")/host.pub"')"

# Operator-side rotation, for the peer that cannot dial out either.
ssh-keygen -q -t ed25519 -N '' -C rot2 -f "$base/rot2" </dev/null
rot2fp=$(ssh-keygen -lf "$base/rot2.pub" | awk '{print $2}')
out=$(peer rc1 fleet rehost "$Z" --host-key "rc2-x $(awk '{print $1" "$2}' "$base/rot2.pub")" 2>&1)
check "rehost: operator can pin a key out of band" "$rot2fp" "$out"
out=$(peer rc1 fleet rehost "$Z" --host-key "garbage" 2>&1); rc=$?
denied "rehost: operator garbage is refused" "$out" "$rc"
check "rehost: operator refusal kept the previous pin" "$rot2fp" \
  "$(raw rc1 'fleet_host_fp "$(fleet_peer_dir "'"$Z"'")/host.pub"')"

# --- 23. live ssh carrier --------------------------------------------------
mark "23. live ssh carrier"
# Everything above rides the `exec` carrier. That proves the protocol but not
# the one thing the ssh carrier is solely responsible for: that fleet traffic
# actually reaches a real sshd, authenticated by the fleet identity key, and
# that a host key which does not match the pin stops the conversation *before*
# any fleet message is exchanged. So run a throwaway user-level sshd on
# loopback (no root, no system config touched, its own host key and its own
# authorized_keys) and dial it with the real carrier.
sshd_bin=$(command -v sshd 2>/dev/null || { [ -x /usr/sbin/sshd ] && echo /usr/sbin/sshd; })
if [ -z "${sshd_bin:-}" ]; then
  skip live-ssh "no sshd binary on this host"
else
  sd=$base/ssh; mkdir -p "$sd"; chmod 700 "$sd"
  ssh-keygen -q -t ed25519 -N '' -C fleet-test-host -f "$sd/hk" </dev/null
  ssh-keygen -q -t ed25519 -N '' -C fleet-test-other -f "$sd/other" </dev/null
  for h in sshcli sshsrv; do mkdir -p "$base/$h"; peer "$h" fleet init --machine "$h" >/dev/null; done
  SC=$(fpof sshcli); SS=$(fpof sshsrv)
  # Only sshcli's fleet identity key may log in; nothing else is authorized.
  cat "$base/sshcli/.n2-agents/fleet/identity/id_ed25519.pub" > "$sd/authorized_keys"
  chmod 600 "$sd/authorized_keys" "$sd/hk"
  sport=0
  for try in 22411 22437 22459 22483; do
    cat > "$sd/sshd_config" <<EOF
Port $try
ListenAddress 127.0.0.1
HostKey $sd/hk
PidFile $sd/sshd.pid
AuthorizedKeysFile $sd/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
LogLevel ERROR
EOF
    "$sshd_bin" -f "$sd/sshd_config" -E "$sd/sshd.log" 2>>"$sd/sshd.err" && { sport=$try; break; }
  done
  waited=0
  while [ "$sport" != 0 ] && [ ! -s "$sd/sshd.pid" ] && [ "$waited" -lt 30 ]; do
    waited=$((waited+1)); perl -e 'select undef,undef,undef,0.1' 2>/dev/null || true
  done
  if [ "$sport" = 0 ] || [ ! -s "$sd/sshd.pid" ]; then
    skip live-ssh "could not start a user-level sshd ($(tail -1 "$sd/sshd.err" 2>/dev/null))"
  else
    sshd_pid=$(cat "$sd/sshd.pid")
    # Kill the test sshd however the suite exits.
    cleanup() { is_main || return 0; kill "$sshd_pid" 2>/dev/null; [ -n "${N2_FLEET_KEEP:-}" ] || { chmod -R u+w "$base" 2>/dev/null; rm -rf "$base"; }; }
    # (EXIT/INT only -- see the trap note at the top of this file.)
    # Pair over exec so both rosters are genuinely approved, then move sshcli's
    # record of sshsrv onto the real ssh carrier. Approval state, signing and
    # freshness are untouched by the move — only the bytes' path changes.
    codeSC=$(peer sshsrv fleet invite --peer "$SC" 2>/dev/null)
    out=$(peer sshcli fleet pair --home "$base/sshsrv" --code "$codeSC" 2>&1)
    check "live-ssh: sshcli paired with sshsrv" "approved" "$out"
    raw sshcli "d=\"\$(fleet_peer_dir '$SS')\"; \
      fleet_meta_set \"\$d\" transport ssh; \
      fleet_meta_set \"\$d\" address 127.0.0.1; \
      fleet_meta_set \"\$d\" port $sport; \
      fleet_meta_set \"\$d\" user '$(id -un)'; \
      fleet_meta_set \"\$d\" command 'env HOME=$base/sshsrv N2_FLEET_AGENTS=$repo/agents $repo/agents'; \
      fleet_known_hosts >/dev/null"
    # Pin the sshd's real host key through the operator path, so the pin is
    # keyed to 127.0.0.1 — the address the carrier dials.
    hkline="fleet-test-host $(awk '{print $1" "$2}' "$sd/hk.pub")"
    out=$(peer sshcli fleet rehost "$SS" --host-key "$hkline" 2>&1)
    check "live-ssh: pinned the test sshd host key" "$(ssh-keygen -lf "$sd/hk.pub" | awk '{print $2}')" "$out"

    out=$(peer sshcli fleet ping "$SS" 2>&1)
    check "live-ssh: signed round trip over a real ssh connection" "pong sshsrv" "$out"
    out=$(peer sshcli fleet peers | grep -F "$SS")
    check "live-ssh: sshsrv reads online over ssh" "online" "$out"

    # Now the point of the pin: swap in a key the server does not hold. ssh
    # must refuse the connection, and the fleet must report it as unreachable
    # rather than falling back to an unverified hop.
    othfp=$(ssh-keygen -lf "$sd/other.pub" | awk '{print $2}')
    peer sshcli fleet rehost "$SS" --host-key "fleet-test-host $(awk '{print $1" "$2}' "$sd/other.pub")" >/dev/null 2>&1
    out=$(peer sshcli fleet ping "$SS" 2>&1); rc=$?
    denied "live-ssh: a host key that does not match the pin is refused" "$out" "$rc"
    check  "live-ssh: mismatch reports unreachable, not a silent downgrade" "unreachable" "$out"
    check  "live-ssh: the bad pin is still what sshcli holds" "$othfp" \
      "$(raw sshcli 'fleet_host_fp "$(fleet_peer_dir "'"$SS"'")/host.pub"')"
    if grep -q '127.0.0.1' "$base/sshcli/.ssh/known_hosts" 2>/dev/null; then
      bad "live-ssh: refusal did not write the user's personal known_hosts" "entry added"
    else ok "live-ssh: refusal did not write the user's personal known_hosts"; fi

    # Restoring the true pin restores service: the refusal was the pin doing
    # its job, not the carrier being broken.
    peer sshcli fleet rehost "$SS" --host-key "$hkline" >/dev/null 2>&1
    check "live-ssh: re-pinning the real key restores the connection" "pong sshsrv" \
      "$(peer sshcli fleet ping "$SS" 2>&1)"

    # An identity ssh does not authorize cannot open the transport at all,
    # even holding a correct host pin: transport auth and fleet auth are
    # separate gates and both must pass.
    : > "$sd/authorized_keys"
    out=$(peer sshcli fleet ping "$SS" 2>&1); rc=$?
    denied "live-ssh: unauthorized identity key cannot open the transport" "$out" "$rc"
    cat "$base/sshcli/.n2-agents/fleet/identity/id_ed25519.pub" > "$sd/authorized_keys"
    kill "$sshd_pid" 2>/dev/null
  fi
fi

# --- 24. a refused enrollment must be a non-zero exit ----------------------
mark "24. a refused enrollment must be a non-zero exit"
# Regression: the join/pair branch used to end on `rm -rf`, so cleanup's exit
# status replaced fleet_record_reply's. The operator saw the refusal on stderr
# and a success exit, and any script gating on `if agents fleet pair` enrolled
# nothing while believing it had.
mkdir -p "$base/zeta"; peer zeta fleet init --machine zeta >/dev/null
Z=$(fpof zeta)
exp=$(peer alpha fleet invite --peer "$Z" --ttl 1 2>/dev/null)
sleep 2
out=$(peer zeta fleet pair --home "$base/alpha" --code "$exp" 2>&1); rc=$?
denied "exit-status: an expired code exits non-zero" "$out" "$rc"
if peer zeta fleet peers --no-probe | grep -qF "$A"; then
  bad "exit-status: expired pairing recorded no peer" "alpha present"; else
  ok  "exit-status: expired pairing recorded no peer"; fi

# a *successful* pair still exits zero
good=$(peer alpha fleet invite --peer "$Z" 2>/dev/null)
out=$(peer zeta fleet pair --home "$base/alpha" --code "$good" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "exit-status: an accepted pairing exits zero"; else
  bad "exit-status: an accepted pairing exits zero" "rc=$rc: $out"; fi

# --- 25. peer-supplied routing fields cannot become ssh options ------------
mark "25. peer-supplied routing fields cannot become ssh options"
# `address`/`user`/`port` are written from a peer's own enroll reply. Expanded
# unquoted they would split on whitespace and a leading '-' would be read as
# an option, so `-oProxyCommand=...` from a peer would run a command locally.
inj="$base/inject.marker"
# a freshly approved pair, so the refusal we observe is the argv guard and not
# the earlier approval gate
mkdir -p "$base/iota"; peer iota fleet init --machine iota >/dev/null; I=$(fpof iota)
icode=$(peer alpha fleet invite --peer "$I" 2>/dev/null)
peer iota fleet pair --home "$base/alpha" --code "$icode" >/dev/null 2>&1
# A bound-code join is answered `approved` on the spot, so no `enrolled`
# callback is ever owed. Arming the one-shot marker there left a capability
# nobody would spend, valid for the life of the machine.
if [ -z "$(ls "$base/iota/.n2-agents/fleet/joined" 2>/dev/null)" ]; then
  ok "enroll: a code-paired join arms no callback marker"
else bad "enroll: a code-paired join arms no callback marker" \
  "still: $(ls "$base/iota/.n2-agents/fleet/joined")"; fi
raw iota "d=\$(fleet_peer_dir '$A'); fleet_meta_set \"\$d\" transport ssh; \
  fleet_meta_set \"\$d\" address '-oProxyCommand=touch $inj'" >/dev/null 2>&1
out=$(peer iota fleet ping "$A" 2>&1); rc=$?
denied "argv: an option-shaped address is refused" "$out" "$rc"
check  "argv: refusal names the bad field" "bad-address" "$out"
if [ -e "$inj" ]; then bad "argv: option-shaped address ran nothing" "$inj created"; else
  ok "argv: option-shaped address ran nothing"; fi
raw iota "d=\$(fleet_peer_dir '$A'); fleet_meta_set \"\$d\" address 'alpha.example'; \
  fleet_meta_set \"\$d\" port '22 -oProxyCommand=touch $inj'" >/dev/null 2>&1
out=$(peer iota fleet ping "$A" 2>&1); rc=$?
denied "argv: a non-numeric port is refused" "$out" "$rc"
check  "argv: refusal names the bad port" "bad-port" "$out"
raw iota "d=\$(fleet_peer_dir '$A'); fleet_meta_set \"\$d\" port 22; \
  fleet_meta_set \"\$d\" user '-oProxyCommand=touch $inj'" >/dev/null 2>&1
out=$(peer iota fleet ping "$A" 2>&1); rc=$?
denied "argv: an option-shaped user is refused" "$out" "$rc"
check  "argv: refusal names the bad user" "bad-user" "$out"
if [ -e "$inj" ]; then bad "argv: no injected field ever executed" "$inj created"; else
  ok "argv: no injected field ever executed"; fi

# --- 26. the enrollment hop can authenticate before it is authorized -------
mark "26. the enrollment hop can authenticate before it is authorized"
# Bootstrap deadlock regression: the fleet key is installed *by* approval, so
# pinning IdentitiesOnly to it on the enrollment hop means the first contact
# can never authenticate. That one hop uses the operator's existing ssh access
# instead -- and must still verify the host.
bopts=$(raw alpha 'fleet_ssh_run print "" "" 1' 2>&1)
nopts=$(raw alpha 'fleet_ssh_run print "" "" ""' 2>&1)
case $bopts in *IdentitiesOnly*) bad "bootstrap: enrollment hop does not pin the unissued fleet key" "$bopts" ;;
  *) ok "bootstrap: enrollment hop does not pin the unissued fleet key" ;; esac
check "bootstrap: enrollment hop still verifies the host" "StrictHostKeyChecking=yes" "$bopts"
check "bootstrap: enrollment hop still uses the fleet known_hosts" "UserKnownHostsFile=" "$bopts"
check "bootstrap: enrollment hop stays non-interactive" "BatchMode=yes" "$bopts"
check "bootstrap: every later hop pins the fleet key" "IdentitiesOnly=yes" "$nopts"
# The enrollment request itself must dial as that hop. A recording ssh sees
# the options a fresh machine's request is sent with.
mkdir -p "$base/bsbin"
cat > "$base/bsbin/ssh" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$base/bsbin/argv"
exit 255
EOF
chmod +x "$base/bsbin/ssh"
ssh-keygen -q -t ed25519 -N '' -f "$base/bshk" >/dev/null
peer bsx fleet init --machine bsx >/dev/null
raw bsx "PATH=\"$base/bsbin:\$PATH\"; fleet_enroll_request ssh 127.0.0.1 nobody /tmp code \
  '127.0.0.1 $(awk '{print $1" "$2}' "$base/bshk.pub")' 22" >/dev/null 2>&1
eargv=$(tr '\n' ' ' < "$base/bsbin/argv" 2>/dev/null)
check  "enroll: the request still verifies the host" "StrictHostKeyChecking=yes" "$eargv"
refute "enroll: the request does not pin the unissued fleet key" "IdentitiesOnly" "$eargv"

# --- 27. bound-code approval grants inbound access both ways ---------------
mark "27. bound-code approval grants inbound access both ways"
# The responder auto-approves on the bound code and authorizes us inbound; if
# the joiner does not do the same for the responder, trust is one-way and the
# approved peer can never call back over ssh.
ak="$base/zeta-authkeys"; : > "$ak"
mkdir -p "$base/eta"; peer eta fleet init --machine eta >/dev/null
T=$(fpof eta)
code3=$(peer alpha fleet invite --peer "$T" 2>/dev/null)
env N2_FLEET_AUTHORIZED_KEYS="$ak" HOME="$base/eta" N2_FLEET_AGENTS="$repo/agents" \
  "$repo/agents" fleet pair --transport ssh --to alpha.example --code "$code3" >/dev/null 2>&1
# the exec-less ssh attempt cannot reach alpha, so drive the recording path
# directly with alpha's real reply and assert the reciprocal grant.
rb="$base/reply.body"
{ printf 'peer=%s\n' "$A"
  printf 'machine=alpha\n'
  printf 'result=approved\n'
  printf 'key=%s\n' "$(awk '{print $1" "$2}' "$base/alpha/.n2-agents/fleet/identity/id_ed25519.pub")"
  printf 'rtag=%s\n' "$(raw alpha "fleet_tag '$code3' '$A' ''")"; } > "$rb"
env N2_FLEET_AUTHORIZED_KEYS="$ak" HOME="$base/eta" N2_FLEET_AGENTS="$repo/agents" sh -c \
  "root=\$HOME/.n2-agents; self=\"$repo/agents\"; . \"$repo/fleet.sh\"; \
   fleet_record_reply '$rb' ssh alpha.example '' '' '$code3'" >/dev/null 2>&1
check "reciprocal: the joiner grants the approved responder inbound ssh" "n2-fleet:$A" "$(cat "$ak")"
check "reciprocal: the grant is restricted to fleet serve" 'command="' "$(cat "$ak")"
check "reciprocal: the grant carries the responder's fleet key" \
  "$(awk '{print $2}' "$base/alpha/.n2-agents/fleet/identity/id_ed25519.pub")" "$(cat "$ak")"

# --- 28. approval-only enrollment must not deadlock ------------------------
mark "28. approval-only enrollment must not deadlock"
# The no-code path is the one the acceptance criteria call "enroll through
# Tailscale with approval": the joiner dials, lands pending, and a human runs
# `approve` on the far machine. That approval answers with an `enrolled`
# callback over ssh, carrying the approver's fleet key. Before the fix the
# joiner only opened its inbound channel for an *already* approved responder,
# so in the pending case the approver could not connect, fleet_notify_approved
# swallowed the failure, and the enrollment was permanently stuck: approved on
# one machine, pending on the other, with nothing to break the tie.
mkdir -p "$base/theta" "$base/iota"
peer theta fleet init --machine theta >/dev/null
peer iota  fleet init --machine iota  >/dev/null
TH=$(fpof theta); IO=$(fpof iota)

# iota dials theta with no pairing code at all.
out=$(peer iota fleet join --home "$base/theta" 2>&1); rc=$?
check "approval-only: a codeless join is accepted as pending" "pending" "$out"
if [ "$rc" = 0 ]; then ok "approval-only: the joiner exits 0 on an accepted pending request"
else bad "approval-only: the joiner exits 0 on an accepted pending request" "rc=$rc: $out"; fi
check "approval-only: the request is waiting on theta" "$IO" "$(peer theta fleet pending)"
check "approval-only: iota does not treat itself as approved yet" "pending" \
  "$(raw iota "fleet_peer_state '$TH'")"

# The operator approves on theta. The callback must actually reach iota.
out=$(peer theta fleet approve "$IO" --no-host-key 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "approval-only: approve succeeds"
else bad "approval-only: approve succeeds" "rc=$rc: $out"; fi
check "approval-only: approve reports the callback landed" "notified" "$out"
check "approval-only: theta now holds iota approved" "approved" "$(raw theta "fleet_peer_state '$IO'")"
# This is the regression. Without the pending-time grant iota stays pending
# forever and every assertion below fails.
check "approval-only: the callback moved iota to approved without polling" "approved" \
  "$(raw iota "fleet_peer_state '$TH'")"
check "approval-only: iota can now call theta" "pong theta" "$(peer iota fleet ping "$TH" 2>&1)"
check "approval-only: theta can call back to iota" "pong iota" "$(peer theta fleet ping "$IO" 2>&1)"
# The one-shot callback marker is consumed, so `enrolled` cannot be replayed
# by anyone later.
if [ -z "$(ls "$base/iota/.n2-agents/fleet/joined" 2>/dev/null)" ]; then
  ok "approval-only: the joined marker is consumed by the callback"
else bad "approval-only: the joined marker is consumed by the callback" "still: $(ls "$base/iota/.n2-agents/fleet/joined")"; fi

# --- 29. the pending grant is a callback channel, not trust ----------------
mark "29. the pending grant is a callback channel, not trust"
# Opening inbound ssh at pending time is only safe because the fleet layer
# still refuses everything but the callback. Prove both halves: the grant
# exists and is restricted, and a pending peer holding it gets nothing.
ak2="$base/kappa-authkeys"; : > "$ak2"
mkdir -p "$base/kappa"; peer kappa fleet init --machine kappa >/dev/null
K=$(fpof kappa)
rb2="$base/reply.pending"
{ printf 'peer=%s\n' "$A"
  printf 'machine=alpha\n'
  printf 'result=pending\n'
  printf 'key=%s\n' "$(awk '{print $1" "$2}' "$base/alpha/.n2-agents/fleet/identity/id_ed25519.pub")"; } > "$rb2"
env N2_FLEET_AUTHORIZED_KEYS="$ak2" HOME="$base/kappa" N2_FLEET_AGENTS="$repo/agents" sh -c \
  "root=\$HOME/.n2-agents; self=\"$repo/agents\"; . \"$repo/fleet.sh\"; \
   fleet_record_reply '$rb2' ssh alpha.example '' '' ''" >/dev/null 2>&1
check "pending-grant: a pending responder is authorized inbound" "n2-fleet:$A" "$(cat "$ak2")"
check "pending-grant: the grant is restricted to fleet serve" 'command="' "$(cat "$ak2")"
if grep -q 'restrict' "$ak2"; then ok "pending-grant: the grant carries restrict"
else bad "pending-grant: the grant carries restrict" "$(cat "$ak2")"; fi
check "pending-grant: the peer is still recorded pending, not approved" "pending" \
  "$(raw kappa "fleet_peer_state '$A'")"
# alpha holds inbound ssh to kappa, yet every ordinary verb is refused because
# fleet_verify gates on approval, not on reachability.
for v in ping roster status revoke; do
  pf="$base/pg.$v"; : > "$pf"
  out=$(raw alpha "fleet_envelope '$K' $v '$pf'" 2>/dev/null | raw kappa "fleet_serve" 2>&1); rc=$?
  denied "pending-grant: a pending peer's '$v' is refused" "$out" "$rc"
  check  "pending-grant: '$v' names the approval gate" "not-approved" "$out"
done

# --- 30. re-enrolling with an approved peer is a usable recovery path ------
mark "30. re-enrolling with an approved peer is a usable recovery path"
# If the callback is lost (approver offline at `approve` time), the operator's
# only lever is to re-run `join` on the joiner. That used to answer with a bare
# "already approved" line carrying no identity, so fleet_record_reply could not
# tell who replied and the rejoin failed with no diagnosis.
out=$(peer iota fleet join --home "$base/theta" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "rejoin: re-enrolling an approved peer exits 0"
else bad "rejoin: re-enrolling an approved peer exits 0" "rc=$rc: $out"; fi
check "rejoin: the reply names the responder" "$TH" "$out"
check "rejoin: the reply is labelled already-approved" "already-approved" "$out"
# The rejoin re-arms the callback marker, which is what makes a second
# `approve` able to complete an enrollment whose first callback was lost.
if [ -n "$(ls "$base/iota/.n2-agents/fleet/joined" 2>/dev/null)" ]; then
  ok "rejoin: the callback marker is re-armed"
else bad "rejoin: the callback marker is re-armed" "no marker written"; fi
# An already-approved reply proves nothing (no rtag), so it must not be able to
# talk a joiner that had *not* approved it into doing so.
mkdir -p "$base/lambda"; peer lambda fleet init --machine lambda >/dev/null
L=$(fpof lambda)
rb3="$base/reply.claim"
{ printf 'peer=%s\n' "$A"
  printf 'machine=alpha\n'
  printf 'result=already-approved\n'
  printf 'key=%s\n' "$(awk '{print $1" "$2}' "$base/alpha/.n2-agents/fleet/identity/id_ed25519.pub")"; } > "$rb3"
raw lambda "fleet_record_reply '$rb3' exec alpha '' '$base/alpha' ''" >/dev/null 2>&1
check "rejoin: an unproven already-approved claim stays pending" "pending" \
  "$(raw lambda "fleet_peer_state '$A'")"


# --- 31. fresh ssh enrollment through a real sshd ---------------------------
mark "31. fresh ssh enrollment through a real sshd"
# Section 23 moves an already-paired peer onto the ssh carrier, so it never
# exercises the one hop that has no fleet authorization yet. Here the server's
# authorized_keys starts with ONLY an operator bootstrap key: the joiner's
# fleet key is nowhere on the far side. Enrollment must ride the operator's
# existing access, approval must install the fleet key, and only then may the
# ordinary IdentitiesOnly hops work.
sshd_bin=$(command -v sshd 2>/dev/null || { [ -x /usr/sbin/sshd ] && echo /usr/sbin/sshd; })
if [ -z "${sshd_bin:-}" ]; then
  skip fresh-ssh "no sshd binary on this host"
else
  fd=$base/fresh; mkdir -p "$fd"; chmod 700 "$fd"
  ssh-keygen -q -t ed25519 -N '' -C fresh-host -f "$fd/hk" </dev/null
  for h in frcli frsrv; do mkdir -p "$base/$h"; peer "$h" fleet init --machine "$h" >/dev/null; done
  FC=$(fpof frcli); FS=$(fpof frsrv)
  # The operator's pre-existing access to the machine, and nothing else.
  mkdir -p "$base/frcli/.ssh" "$base/frsrv/.ssh"; chmod 700 "$base/frcli/.ssh" "$base/frsrv/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C operator-bootstrap -f "$base/frcli/.ssh/id_ed25519" </dev/null
  cat "$base/frcli/.ssh/id_ed25519.pub" > "$base/frsrv/.ssh/authorized_keys"
  chmod 600 "$base/frsrv/.ssh/authorized_keys" "$fd/hk"
  # What the forced command must become for the server half to run in its own
  # HOME. The server inherits N2_FLEET_REMOTE_CMD from here, so the line it
  # writes into authorized_keys at approval time points back at this wrapper.
  cat > "$fd/srv.sh" <<EOF
#!/bin/sh
export HOME=$base/frsrv N2_FLEET_AGENTS=$repo/agents N2_FLEET_REMOTE_CMD=$fd/srv.sh
exec $repo/agents "\$@"
EOF
  chmod 755 "$fd/srv.sh"
  fport=0
  for try in 22507 22531 22567 22573; do
    cat > "$fd/sshd_config" <<EOF
Port $try
ListenAddress 127.0.0.1
HostKey $fd/hk
PidFile $fd/sshd.pid
AuthorizedKeysFile $base/frsrv/.ssh/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
LogLevel ERROR
EOF
    "$sshd_bin" -f "$fd/sshd_config" -E "$fd/sshd.log" 2>>"$fd/sshd.err" && { fport=$try; break; }
  done
  waited=0
  while [ "$fport" != 0 ] && [ ! -s "$fd/sshd.pid" ] && [ "$waited" -lt 30 ]; do
    waited=$((waited+1)); perl -e 'select undef,undef,undef,0.1' 2>/dev/null || true
  done
  if [ "$fport" = 0 ] || [ ! -s "$fd/sshd.pid" ]; then
    skip fresh-ssh "could not start a user-level sshd ($(tail -1 "$fd/sshd.err" 2>/dev/null))"
  else
    fsshd_pid=$(cat "$fd/sshd.pid")
    cleanup() { [ "$$" = "$main_pid" ] || return 0
                kill "$fsshd_pid" 2>/dev/null; kill "${sshd_pid:-0}" 2>/dev/null
                [ -n "${N2_FLEET_KEEP:-}" ] || { chmod -R u+w "$base" 2>/dev/null; rm -rf "$base"; }; }
    fhk="fresh-host $(awk '{print $1" "$2}' "$fd/hk.pub")"
    # Baseline: the fleet key really is not installed over there yet.
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
        -o IdentitiesOnly=yes -i "$base/frcli/.n2-agents/fleet/identity/id_ed25519" \
        -p "$fport" "$(id -un)@127.0.0.1" true >/dev/null 2>&1
    denied "fresh-ssh: the joiner's fleet key is not preinstalled on the server" "unexpected login" $?

    out=$(export N2_FLEET_REMOTE_CMD="$fd/srv.sh"
          peer frcli fleet pair --to 127.0.0.1 --port "$fport" \
            --user "$(id -un)" --host-key "$fhk" \
            --ssh-identity "$base/frcli/.ssh/id_ed25519" --code bogus-code-value 2>&1); rc=$?
    denied "fresh-ssh: an unbound code over real ssh is refused" "$out" "$rc"

    out=$(export N2_FLEET_REMOTE_CMD="$fd/srv.sh" N2_FLEET_SELF_PORT="$fport"
          peer frcli fleet join --to 127.0.0.1 --port "$fport" --user "$(id -un)" \
            --ssh-identity "$base/frcli/.ssh/id_ed25519" --host-key "$fhk" 2>&1)
    check "fresh-ssh: bootstrap hop enrolls over the operator's own access" "pending" "$out"
    check "fresh-ssh: the server filed it pending, not approved" "$FC" "$(peer frsrv fleet pending)"
    check "fresh-ssh: --port survived onto the durable peer record" "$fport" \
      "$(raw frcli 'fleet_meta "$(fleet_peer_dir "'"$FS"'")" port')"
    if grep -qF "n2-fleet:$FC" "$base/frsrv/.ssh/authorized_keys"; then
      bad "fresh-ssh: pending peer is not yet granted inbound ssh" "grant present"
    else ok "fresh-ssh: pending peer is not yet granted inbound ssh"; fi

    # Approval is what installs the key — and the callback it fires is the
    # first message to ride the fleet identity rather than the bootstrap one.
    out=$(export N2_FLEET_REMOTE_CMD="$fd/srv.sh"
          peer frsrv fleet approve "$FC" 2>&1)
    check "fresh-ssh: approval on the server side" "approved" "$out"
    check "fresh-ssh: approval installed the joiner's fleet key" "n2-fleet:$FC" \
      "$(cat "$base/frsrv/.ssh/authorized_keys")"
    check "fresh-ssh: the grant is restricted to fleet serve" 'restrict,command="'"$fd/srv.sh"' fleet serve"' \
      "$(cat "$base/frsrv/.ssh/authorized_keys")"
    # frcli runs no sshd, so `approve`'s callback has nowhere to land. That is
    # the documented best-effort case and the operator must be told: the
    # approval stands on the server, the joiner still believes it is pending,
    # and the fix is to re-run join (section 27) or re-approve once reachable.
    check "fresh-ssh: an undeliverable callback is reported, not swallowed" "unreachable" "$out"
    check "fresh-ssh: the joiner without a callback channel stays pending" "pending" \
      "$(raw frcli "fleet_peer_state '$FS'")"

    # The other enrollment door, over the same live sshd: a code bound to one
    # fingerprint. The responder approves on the spot and proves it holds the
    # secret (rtag), so the joiner records `approved` in the same hop with no
    # callback at all -- this is the "paired direct SSH" path end to end.
    mkdir -p "$base/frcl2"; peer frcl2 fleet init --machine frcl2 >/dev/null
    F2=$(fpof frcl2)
    fcode=$(peer frsrv fleet invite --peer "$F2" 2>/dev/null)
    out=$(export N2_FLEET_REMOTE_CMD="$fd/srv.sh" N2_FLEET_SELF_PORT="$fport"
          peer frcl2 fleet pair --to 127.0.0.1 --port "$fport" --user "$(id -un)" \
            --ssh-identity "$base/frcli/.ssh/id_ed25519" --host-key "$fhk" \
            --code "$fcode" 2>&1); rc=$?
    if [ "$rc" = 0 ]; then ok "fresh-ssh: a bound code pairs over real ssh"
    else bad "fresh-ssh: a bound code pairs over real ssh" "rc=$rc: $out"; fi
    check "fresh-ssh: the paired joiner holds the server approved" "approved" \
      "$(raw frcl2 "fleet_peer_state '$FS'")"
    check "fresh-ssh: the server holds the paired joiner approved" "approved" \
      "$(raw frsrv "fleet_peer_state '$F2'")"
    check "fresh-ssh: pairing installed the paired joiner's fleet key" "n2-fleet:$F2" \
      "$(cat "$base/frsrv/.ssh/authorized_keys")"
    # frcl2 names no address, so the server dials it back where it came from,
    # not at its machine name.
    check "fresh-ssh: the server records the joiner at the address it connected from" "127.0.0.1" \
      "$(raw frsrv 'fleet_meta "$(fleet_peer_dir "'"$F2"'")" address')"
    check "fresh-ssh: --port survived the pairing hop too" "$fport" \
      "$(raw frcl2 'fleet_meta "$(fleet_peer_dir "'"$FS"'")" port')"
    # The one-time code really is one-time: replaying it is refused.
    out=$(export N2_FLEET_REMOTE_CMD="$fd/srv.sh"
          peer frcli fleet pair --to 127.0.0.1 --port "$fport" --user "$(id -un)" \
            --ssh-identity "$base/frcli/.ssh/id_ed25519" --host-key "$fhk" \
            --code "$fcode" 2>&1); rc=$?
    denied "fresh-ssh: the spent pairing code cannot be replayed" "$out" "$rc"

    # Wrong identity over the live transport. Sections 3 and 4 prove this at
    # the fleet layer with the exec carrier; the open question was whether a
    # real ssh hop could smuggle an impersonation past it. frcl3 holds the
    # operator bootstrap key, so the ssh door genuinely opens for it -- and the
    # code it replays is bound to frcl2's fingerprint, not its own.
    mkdir -p "$base/frcl3"; peer frcl3 fleet init --machine frcl3 >/dev/null
    F3=$(fpof frcl3)
    fcode2=$(peer frsrv fleet invite --peer "$F2" 2>/dev/null)
    out=$(export N2_FLEET_REMOTE_CMD="$fd/srv.sh" N2_FLEET_SELF_PORT="$fport"
          peer frcl3 fleet pair --to 127.0.0.1 --port "$fport" --user "$(id -un)" \
            --ssh-identity "$base/frcli/.ssh/id_ed25519" --host-key "$fhk" \
            --code "$fcode2" 2>&1); rc=$?
    denied "fresh-ssh: a code bound to another peer is refused over real ssh" "$out" "$rc"
    check  "fresh-ssh: the live refusal names wrong-identity" "wrong-identity" "$out"
    if peer frsrv fleet peers --no-probe | grep -qF "$F3"; then
      bad "fresh-ssh: the impersonator is not in the server roster" "roster lists $F3"
    else ok "fresh-ssh: the impersonator is not in the server roster"; fi
    if grep -qF "n2-fleet:$F3" "$base/frsrv/.ssh/authorized_keys"; then
      bad "fresh-ssh: a refused impersonator gets no inbound grant" "grant present"
    else ok "fresh-ssh: a refused impersonator gets no inbound grant"; fi
    # The failed enrolment left it no transport either: the ssh door that the
    # borrowed operator key opened is not a fleet channel.
    out=$(peer frcl3 fleet ping "$FS" 2>&1); rc=$?
    denied "fresh-ssh: the impersonator has no working transport afterwards" "$out" "$rc"
    # And the peer the code was actually minted for is untouched by the attempt.
    check "fresh-ssh: the real invitee is unaffected by the replay" "approved" \
      "$(raw frsrv "fleet_peer_state '$F2'")"

    # Drop the operator bootstrap key: from here on only the fleet identity
    # can open the transport, which is what these next hops prove.
    grep -F 'n2-fleet:' "$base/frsrv/.ssh/authorized_keys" > "$fd/ak" && \
      cat "$fd/ak" > "$base/frsrv/.ssh/authorized_keys"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
        -o IdentitiesOnly=yes -i "$base/frcli/.ssh/id_ed25519" \
        -p "$fport" "$(id -un)@127.0.0.1" true >/dev/null 2>&1
    denied "fresh-ssh: the operator bootstrap key is gone from the server" "unexpected login" $?
    out=$(peer frcl2 fleet ping "$FS" 2>&1)
    check "fresh-ssh: signed round trip on the fleet key alone" "pong frsrv" "$out"

    # Revocation takes the inbound grant back out of the real authorized_keys.
    peer frsrv fleet revoke "$F2" >/dev/null 2>&1
    if grep -qF "n2-fleet:$F2" "$base/frsrv/.ssh/authorized_keys"; then
      bad "fresh-ssh: revocation removed the inbound ssh grant" "grant still present"
    else ok "fresh-ssh: revocation removed the inbound ssh grant"; fi
    out=$(peer frcl2 fleet ping "$FS" 2>&1); rc=$?
    denied "fresh-ssh: a revoked peer can no longer open the transport" "$out" "$rc"
    kill "$fsshd_pid" 2>/dev/null
  fi
fi


# --- 32. no required hub: the fleet grows after the originator is destroyed --
mark "32. no required hub: the fleet grows after the originator is destroyed"
# Sections 6/13/14 take the originator *offline*. This one deletes it. Three
# isolated peers enroll through `orig`; orig's home, keys and roster are then
# removed for good, and the survivors must still manage the fleet: call each
# other, enroll a fourth machine, discover it hub-free, and revoke it.
for h in orig m1 m2 m3; do mkdir -p "$base/$h"; peer "$h" fleet init --machine "$h" >/dev/null; done
O=$(fpof orig); M1=$(fpof m1); M2=$(fpof m2); M3=$(fpof m3)
peer m1 fleet pair --home "$base/orig" --code "$(peer orig fleet invite --peer "$M1" 2>/dev/null)" >/dev/null 2>&1
peer m2 fleet pair --home "$base/orig" --code "$(peer orig fleet invite --peer "$M2" 2>/dev/null)" >/dev/null 2>&1
# orig's approval is fleet-wide, so the survivors already hold each other
# approved, on orig's route. That route is orig's view of the network and may
# not be dialable from here; `fleet route` is the supported repair, and using
# it keeps this test on the CLI surface instead of hand-editing peer meta.
check "nohub: orig's approval reached m1 with no step on m1" "approved" "$(raw m1 "fleet_peer_state '$M2'")"
out=$(peer m1 fleet route "$M2" --transport exec --home "$base/m2" 2>&1)
check "nohub: route re-points an adopted peer through the CLI" "routed" "$out"
check "nohub: route reports the carrier it installed" "exec" "$out"
peer m2 fleet route "$M1" --transport exec --home "$base/m1" >/dev/null 2>&1

# The routing fields reach ssh's argv, so `route` applies the carrier's own
# validators rather than trusting the operator.
out=$(peer m1 fleet route "$M2" --port 99999 2>&1); rc=$?
denied "nohub: route rejects a port that is not a port" "$out" "$rc"
out=$(peer m1 fleet route "$M2" --address '-oProxyCommand=touch /tmp/n2pwn' 2>&1); rc=$?
denied "nohub: route rejects an address ssh would read as an option" "$out" "$rc"
# m1 adopted m2 with orig's pin; drop it, as for a member approved --no-host-key.
raw m1 "rm -f \"\$(fleet_peer_dir '$M2')/host.pub\"" >/dev/null 2>&1
out=$(peer m1 fleet route "$M2" --transport ssh --address 198.51.100.7 2>&1); rc=$?
denied "nohub: route refuses an ssh route with no pinned host key" "$out" "$rc"
check "nohub: route says how to pin the missing host key" "--host-key" "$out"
out=$(peer m1 fleet route deadbeef --transport exec --home "$base/m2" 2>&1); rc=$?
denied "nohub: route refuses an unknown peer" "$out" "$rc"
out=$(peer m1 fleet route "$M1" --transport exec --home "$base/m1" 2>&1); rc=$?
denied "nohub: route refuses to re-point this machine at itself" "$out" "$rc"
out=$(peer m1 fleet route "$M2" 2>&1); rc=$?
denied "nohub: route with no fields changes nothing" "$out" "$rc"
# A rejected field must leave the working route intact, not half-applied.
check "nohub: a rejected route leaves the working one in place" "pong m2" \
  "$(peer m1 fleet ping "$M2" 2>&1)"

chmod -R u+w "$base/orig"; rm -rf "$base/orig"      # the originator is destroyed
if [ -e "$base/orig" ]; then bad "nohub: originator is really gone" "home still present"
else ok "nohub: originator is really gone"; fi

# 1. management traffic between survivors
check "nohub: survivor <-> survivor round trip" "pong m2" "$(peer m1 fleet ping "$M2" 2>&1)"
out=$(peer m1 fleet roster "$M2" 2>&1)
check "nohub: a survivor can read another survivor's roster" "$M1" "$out"
out=$(peer m1 fleet status 2>&1)
check "nohub: status still reports self" "self	m1" "$out"
check "nohub: the destroyed originator shows offline, not fatal" "offline" \
  "$(printf '%s\n' "$out" | grep -F "$O")"
check "nohub: the surviving peer still shows online" "online" \
  "$(printf '%s\n' "$out" | grep -F "$M2")"

# 2. enrollment of a *new* machine with no originator in existence
codeM3=$(peer m1 fleet invite --peer "$M3" 2>/dev/null)
out=$(peer m3 fleet pair --home "$base/m1" --code "$codeM3" 2>&1)
check "nohub: a survivor enrolls a fourth machine" "approved" "$out"
check "nohub: the new machine is in the enroller's roster" "approved" \
  "$(peer m1 fleet peers --no-probe | grep -F "$M3")"
check "nohub: the new machine can call its enroller" "pong m1" "$(peer m3 fleet ping "$M1" 2>&1)"

# 3. the other survivor accepts the newcomer on m1's word, with no step of its own
check "nohub: the second survivor holds the newcomer approved" "approved" "$(raw m2 "fleet_peer_state '$M3'")"
check "nohub: the second survivor records m1 as the approver" "$M1" \
  "$(raw m2 "fleet_meta \"\$(fleet_peer_dir '$M3')\" added_by")"

# 4. and the fleet can shrink again without the originator
out=$(peer m1 fleet revoke --propagate "$M3" 2>&1)
check "nohub: revocation fans out from a survivor" "propagate" "$out"
out=$(peer m3 fleet ping "$M1" 2>&1); rc=$?
denied "nohub: the revoked newcomer is refused" "$out" "$rc"
# Fixture guard: sections 33/34 drive m1, which section 32 created. If m1's
# identity has gone missing by the time we get here, every assertion below
# reports "no fleet identity yet" and looks like a product bug. Say so here
# instead, so the failure names its real cause.
if [ -d "$base/m1/.n2-agents/fleet" ]; then ok "fixture: m1 still has its fleet identity entering section 33"
else bad "fixture: m1 still has its fleet identity entering section 33" \
  "m1 home now holds: $(ls -A "$base/m1" 2>&1 | tr '\n' ' ')"; fi

# --- 33. an approval whose ssh grant cannot be installed fails loudly -------
mark "33. an approval whose ssh grant cannot be installed fails loudly"
# Reporting "approved" while the authorized_keys write failed hands the
# operator a peer that can never reach this machine. Point the grant file at a
# path that cannot be written (a directory) and require the failure to surface.
mkdir -p "$base/m4"; peer m4 fleet init --machine m4 >/dev/null
M4=$(fpof m4)
peer m4 fleet join --transport exec --home "$base/m1" >/dev/null 2>&1
# An exec peer needs no inbound ssh grant, so re-tag the request as the ssh
# peer this test is about before approving it.
raw m1 "fleet_meta_set \"\$(fleet_pending_dir '$M4')\" transport ssh" >/dev/null
if peer m1 fleet pending 2>/dev/null | grep -qF "$M4"; then
  ok "grant-failure: an uninvited join lands pending"
else bad "grant-failure: an uninvited join lands pending" "$(peer m1 fleet pending 2>&1)"; fi
mkdir -p "$base/m1/blocked/authorized_keys"
out=$(env HOME="$base/m1" N2_FLEET_AGENTS="$repo/agents" \
      N2_FLEET_AUTHORIZED_KEYS="$base/m1/blocked/authorized_keys" \
      "$repo/agents" fleet approve "$M4" --no-host-key 2>&1); rc=$?
denied "grant-failure: approval with an unwritable grant file does not report success" "$out" "$rc"
check  "grant-failure: the operator is told the inbound grant is missing" "inbound ssh grant" "$out"
if grep -q "authorize-failed" "$base/m1/.n2-agents/fleet/events.log" 2>/dev/null; then
  ok "grant-failure: the failure is recorded in the event log"
else bad "grant-failure: the failure is recorded in the event log" \
  "$(tail -3 "$base/m1/.n2-agents/fleet/events.log" 2>&1)"; fi
# And with a writable grant file the same approval succeeds, so the refusal
# above is the write failing, not approval being broken.
out=$(peer m1 fleet approve "$M4" --no-host-key 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "grant-failure: the same approval succeeds once the grant can be written"
else bad "grant-failure: the same approval succeeds once the grant can be written" "$out"; fi
if grep -qF "n2-fleet:$M4" "$base/m1/.ssh/authorized_keys" 2>/dev/null; then
  ok "grant-failure: the retried approval installs the grant"
else bad "grant-failure: the retried approval installs the grant" "no grant line"; fi


# --- 34. a revocation whose ssh grant cannot be removed fails loudly --------
mark "34. a revocation whose ssh grant cannot be removed fails loudly"
# The mirror of section 20, and the more dangerous direction: reporting
# "revoked" while the peer's key is still in authorized_keys tells the
# operator inbound ssh is closed when it is still wide open. m4 is approved
# above and has a real grant line; make both the grant file and the directory
# it lives in unwritable so neither the staged rewrite nor the in-place
# rewrite can succeed.
akf="$base/m1/.ssh/authorized_keys"
chmod 444 "$akf"; chmod 500 "$base/m1/.ssh"
out=$(peer m1 fleet revoke "$M4" 2>&1); rc=$?
chmod 700 "$base/m1/.ssh"; chmod 600 "$akf"
denied "revoke-failure: revocation does not report success when the grant survives" "$out" "$rc"
check  "revoke-failure: the operator is told the peer can still reach this machine" "inbound ssh grant" "$out"
check  "revoke-failure: the operator is told which line to remove" "n2-fleet:$M4" "$out"
# An unwritable directory has no lock to wait for; the failure names it at once
# instead of waiting out the lock ceiling and blaming another grant change.
check  "revoke-failure: the unwritable directory is named, not waited on" "cannot write $base/m1/.ssh" "$out"
if grep -qF "n2-fleet:$M4" "$akf" 2>/dev/null; then
  ok "revoke-failure: the grant really did survive (the failure was real)"
else bad "revoke-failure: the grant really did survive (the failure was real)" "grant already gone"; fi
if grep -q "deauthorize-failed" "$base/m1/.n2-agents/fleet/events.log" 2>/dev/null; then
  ok "revoke-failure: the failure is recorded in the event log"
else bad "revoke-failure: the failure is recorded in the event log" \
  "$(tail -3 "$base/m1/.n2-agents/fleet/events.log" 2>&1)"; fi
# The application-level revocation is durable regardless -- the loud status is
# about the ssh door, not about the peer still being trusted.
if peer m1 fleet peers --no-probe 2>/dev/null | grep -qF "$M4"; then
  bad "revoke-failure: the peer is still removed from the roster" "m4 still enrolled"
else ok "revoke-failure: the peer is still removed from the roster"; fi
check "revoke-failure: the peer is on the revoked list" "$M4" \
  "$(cat "$base/m1/.n2-agents/fleet/revoked" 2>&1)"
# And once the file can be written the same revocation succeeds, so the
# refusal above was the write failing rather than revocation being broken.
out=$(peer m1 fleet revoke "$M4" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "revoke-failure: the retry succeeds once the grant file is writable"
else bad "revoke-failure: the retry succeeds once the grant file is writable" "$out"; fi
if grep -qF "n2-fleet:$M4" "$akf" 2>/dev/null; then
  bad "revoke-failure: the retry removes the grant" "grant still present"
else ok "revoke-failure: the retry removes the grant"; fi

# --- 35. a propagated revocation whose grant cannot be removed fails loudly -
mark "35. a propagated revocation whose grant cannot be removed fails loudly"
# Section 21 covers the local CLI path. This is the remote handler: a peer
# receives a signed `revoke` over the carrier, removes the roster entry, but
# cannot rewrite its own authorized_keys. Answering OK there would tell the
# revoking operator the fleet is closed while the cut-off peer still holds a
# working inbound ssh grant on this machine.
for h in rr1 rr2 rr3; do mkdir -p "$base/$h"; peer "$h" fleet init --machine "$h" >/dev/null; done
R1=$(fpof rr1); R2=$(fpof rr2); R3=$(fpof rr3)
mutual rr1 "$R2" rr2 >/dev/null; mutual rr1 "$R3" rr3 >/dev/null
check "remote-revoke: rr2 holds rr3 through rr1's approval" "approved" "$(raw rr2 "fleet_peer_state '$R3'")"
# The carrier here is `exec`, which needs no ssh grant; move rr2's record of
# rr3 onto ssh and install the real grant so the revocation has an actual
# inbound door to close (the same call `approve` makes for an ssh peer).
raw rr2 'd=$(fleet_peer_dir "'"$R3"'"); fleet_meta_set "$d" transport ssh; fleet_authorize "'"$R3"'" "$d"' >/dev/null 2>&1
rrak="$base/rr2/.ssh/authorized_keys"
if grep -qF "n2-fleet:$R3" "$rrak" 2>/dev/null; then
  ok "remote-revoke: rr2 holds a real inbound grant for rr3"
else bad "remote-revoke: rr2 holds a real inbound grant for rr3" "$(cat "$rrak" 2>&1)"; fi

chmod 444 "$rrak"; chmod 500 "$base/rr2/.ssh"
prop=$(peer rr1 fleet revoke --propagate "$R3" 2>&1); rc=$?
chmod 700 "$base/rr2/.ssh"; chmod 600 "$rrak"
hop=$(printf '%s\n' "$prop" | grep -F "$R2")
check "remote-revoke: the propagated hop to rr2 is reported as failed" "fail" "$hop"
check "remote-revoke: the reply names the stuck grant" "revoked-grant-not-removed" "$hop"
check "remote-revoke: the reply names the machine that needs a hand" "rr2" "$hop"
if grep -qF "n2-fleet:$R3" "$rrak" 2>/dev/null; then
  ok "remote-revoke: the grant really did survive (the failure was real)"
else bad "remote-revoke: the grant really did survive (the failure was real)" "grant already gone"; fi
if grep -q "deauthorize-failed" "$base/rr2/.n2-agents/fleet/events.log" 2>/dev/null; then
  ok "remote-revoke: rr2 records the failure in its event log"
else bad "remote-revoke: rr2 records the failure in its event log" \
  "$(tail -3 "$base/rr2/.n2-agents/fleet/events.log" 2>&1)"; fi
# Application-level revocation is still durable on the receiving side.
if peer rr2 fleet peers --no-probe 2>/dev/null | grep -qF "$R3"; then
  bad "remote-revoke: rr2 still dropped rr3 from its roster" "rr3 still enrolled"
else ok "remote-revoke: rr2 still dropped rr3 from its roster"; fi

# Retry once the file is writable: the same signed verb now succeeds and the
# door actually closes, so the refusal above was the write and not the verb.
prop=$(peer rr1 fleet revoke --propagate "$R3" 2>&1)
hop=$(printf '%s\n' "$prop" | grep -F "$R2")
check "remote-revoke: the retry reports the hop ok" "ok" "$hop"
check "remote-revoke: the retry reply confirms the revocation" "revoked" "$hop"
if grep -qF "n2-fleet:$R3" "$rrak" 2>/dev/null; then
  bad "remote-revoke: the retry removes the grant" "grant still present"
else ok "remote-revoke: the retry removes the grant"; fi
out=$(peer rr3 fleet ping "$R2" 2>&1); rc=$?
denied "remote-revoke: rr3 can no longer call rr2" "$out" "$rc"

# --- 36. unfinished revocation cleanup is retried on the pull path ---------
mark "36. unfinished revocation cleanup is retried on the pull path"
# Sections 21 and 22 cover the push paths (local CLI, propagated verb). The
# pull path is where the hole was: `fleet reconcile` learns of a revocation
# from a neighbour, fails to remove the grant, and then *never tries again* --
# the id is on the revoked list, so every later pass short-circuits before it
# reaches authorized_keys. The peer is refused at the fleet layer but keeps a
# working inbound ssh door forever. So: the failure must be non-zero, the
# unfinished half must be remembered, and the next reconcile must finish it.
for h in rp1 rp2 rp3; do mkdir -p "$base/$h"; peer "$h" fleet init --machine "$h" >/dev/null; done
P1=$(fpof rp1); P2=$(fpof rp2); P3=$(fpof rp3)
mutual rp1 "$P2" rp2 >/dev/null; mutual rp1 "$P3" rp3 >/dev/null
check "reconcile-cleanup: rp2 holds rp3 through rp1's approval" "approved" "$(raw rp2 "fleet_peer_state '$P3'")"
raw rp2 'd=$(fleet_peer_dir "'"$P3"'"); fleet_meta_set "$d" transport ssh; fleet_authorize "'"$P3"'" "$d"' >/dev/null 2>&1
rpak="$base/rp2/.ssh/authorized_keys"
if grep -qF "n2-fleet:$P3" "$rpak" 2>/dev/null; then
  ok "reconcile-cleanup: rp2 holds a real inbound grant for rp3"
else bad "reconcile-cleanup: rp2 holds a real inbound grant for rp3" "$(cat "$rpak" 2>&1)"; fi

# rp1 cuts rp3 off without propagating, so rp2 only learns by pulling.
peer rp1 fleet revoke "$P3" >/dev/null 2>&1
chmod 444 "$rpak"; chmod 500 "$base/rp2/.ssh"
out=$(peer rp2 fleet reconcile 2>&1); rc=$?
chmod 700 "$base/rp2/.ssh"; chmod 600 "$rpak"
check "reconcile-cleanup: the pull adopts the revocation" "$P3" "$out"
check "reconcile-cleanup: the stuck grant is named" "revoked-grant-not-removed" "$out"
denied "reconcile-cleanup: incomplete cleanup is a non-zero exit" "$out" "$rc"
check "reconcile-cleanup: the operator is told to rerun once the file is writable" "rerun" "$out"
if grep -qF "n2-fleet:$P3" "$rpak" 2>/dev/null; then
  ok "reconcile-cleanup: the grant really did survive (the failure was real)"
else bad "reconcile-cleanup: the grant really did survive (the failure was real)" "grant already gone"; fi
check "reconcile-cleanup: the unfinished half is written down" "$P3" \
  "$(cat "$base/rp2/.n2-agents/fleet/revoke-pending" 2>&1)"
if peer rp2 fleet peers --no-probe 2>/dev/null | grep -qF "$P3"; then
  bad "reconcile-cleanup: rp2 still dropped rp3 from its roster" "rp3 still enrolled"
else ok "reconcile-cleanup: rp2 still dropped rp3 from its roster"; fi

# The next reconcile must finish the job even though rp3 is already revoked
# here -- that short-circuit is exactly what used to strand the grant.
out=$(peer rp2 fleet reconcile 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "reconcile-cleanup: the retry exits zero once the grant is gone"
else bad "reconcile-cleanup: the retry exits zero once the grant is gone" "$out"; fi
check "reconcile-cleanup: the retry reports the grant removed" "revoked-grant-removed" "$out"
if grep -qF "n2-fleet:$P3" "$rpak" 2>/dev/null; then
  bad "reconcile-cleanup: the retry removes the grant" "grant still present"
else ok "reconcile-cleanup: the retry removes the grant"; fi
if [ -s "$base/rp2/.n2-agents/fleet/revoke-pending" ]; then
  bad "reconcile-cleanup: the pending ledger is cleared" \
    "$(cat "$base/rp2/.n2-agents/fleet/revoke-pending")"
else ok "reconcile-cleanup: the pending ledger is cleared"; fi
if grep -q "revoke-cleanup" "$base/rp2/.n2-agents/fleet/events.log" 2>/dev/null; then
  ok "reconcile-cleanup: the late cleanup is recorded in the event log"
else bad "reconcile-cleanup: the late cleanup is recorded in the event log" \
  "$(tail -3 "$base/rp2/.n2-agents/fleet/events.log" 2>&1)"; fi
out=$(peer rp3 fleet ping "$P2" 2>&1); rc=$?
denied "reconcile-cleanup: rp3 can no longer call rp2" "$out" "$rc"
# A third pass is a no-op: nothing left to retry, nothing new to adopt.
out=$(peer rp2 fleet reconcile 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "reconcile-cleanup: a settled reconcile stays quiet and zero"
else bad "reconcile-cleanup: a settled reconcile stays quiet and zero" "$out"; fi

# --- 37. an unreadable grant file is not an absent grant -------------------
mark "37. an unreadable grant file is not an absent grant"
# Sections 20-23 make the grant file *unwritable*. This is the other read
# failure and the one that used to pass silently: `grep -q` exits non-zero
# both when the grant is absent (1) and when the file cannot be read at all
# (2), so a chmod 000 authorized_keys made revocation report success while the
# peer's inbound ssh door stayed wide open -- and because it "succeeded",
# nothing was written to revoke-pending, so no later reconcile ever retried.
# The directory stays writable here, so only the read can fail.
for h in ru1 ru2 ru3; do mkdir -p "$base/$h"; peer "$h" fleet init --machine "$h" >/dev/null; done
U1=$(fpof ru1); U2=$(fpof ru2); U3=$(fpof ru3)
mutual ru1 "$U2" ru2 >/dev/null; mutual ru1 "$U3" ru3 >/dev/null
# ru2 becomes the ssh peer under revocation; ru3 stays on the exec carrier (so
# reconcile has a reachable neighbour) but is given a real grant line too, so
# the rewrite has a bystander to damage if it mishandles a read error.
raw ru1 'd=$(fleet_peer_dir "'"$U2"'"); fleet_meta_set "$d" transport ssh; fleet_authorize "'"$U2"'" "$d"' >/dev/null 2>&1
# fleet_authorize only writes a grant for an ssh/tailscale peer, so ru3 is
# flipped to ssh just long enough to install the line and then put back on
# exec -- the grant is the bystander, the carrier stays reachable.
raw ru1 'd=$(fleet_peer_dir "'"$U3"'"); fleet_meta_set "$d" transport ssh; fleet_authorize "'"$U3"'" "$d"; fleet_meta_set "$d" transport exec' >/dev/null 2>&1
uak="$base/ru1/.ssh/authorized_keys"
if grep -qF "n2-fleet:$U2" "$uak" 2>/dev/null && grep -qF "n2-fleet:$U3" "$uak" 2>/dev/null; then
  ok "unreadable-grant: ru1 holds real inbound grants for both peers"
else bad "unreadable-grant: ru1 holds real inbound grants for both peers" "$(cat "$uak" 2>&1)"; fi

chmod 000 "$uak"
out=$(peer ru1 fleet revoke "$U2" 2>&1); rc=$?
chmod 600 "$uak"
denied "unreadable-grant: revocation does not report success when the file cannot be read" "$out" "$rc"
check  "unreadable-grant: the operator is told the inbound grant is still there" "inbound ssh grant" "$out"
check  "unreadable-grant: the reason names the unreadable file" "cannot read" "$out"
check  "unreadable-grant: the operator is told which line to remove" "n2-fleet:$U2" "$out"
if grep -qF "n2-fleet:$U2" "$uak" 2>/dev/null; then
  ok "unreadable-grant: the grant really did survive (the failure was real)"
else bad "unreadable-grant: the grant really did survive (the failure was real)" "grant already gone"; fi
# The bystander must be untouched: treating the failed read as an empty result
# would have rewritten authorized_keys to nothing and cut off every peer.
if grep -qF "n2-fleet:$U3" "$uak" 2>/dev/null; then
  ok "unreadable-grant: the failed rewrite did not truncate the other peer's grant"
else bad "unreadable-grant: the failed rewrite did not truncate the other peer's grant" "$(cat "$uak" 2>&1)"; fi
check "unreadable-grant: the unfinished half is written down" "$U2" \
  "$(cat "$base/ru1/.n2-agents/fleet/revoke-pending" 2>&1)"
if grep -q "deauthorize-failed" "$base/ru1/.n2-agents/fleet/events.log" 2>/dev/null; then
  ok "unreadable-grant: the failure is recorded in the event log"
else bad "unreadable-grant: the failure is recorded in the event log" \
  "$(tail -3 "$base/ru1/.n2-agents/fleet/events.log" 2>&1)"; fi
if peer ru1 fleet peers --no-probe 2>/dev/null | grep -qF "$U2"; then
  bad "unreadable-grant: the peer is still removed from the roster" "ru2 still enrolled"
else ok "unreadable-grant: the peer is still removed from the roster"; fi

# Now the file can be read again: the retry must finish the job, and only it.
out=$(peer ru1 fleet reconcile 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "unreadable-grant: the retry exits zero once the file is readable"
else bad "unreadable-grant: the retry exits zero once the file is readable" "$out"; fi
check "unreadable-grant: the retry reports the grant removed" "revoked-grant-removed" "$out"
if grep -qF "n2-fleet:$U2" "$uak" 2>/dev/null; then
  bad "unreadable-grant: the retry removes the revoked grant" "grant still present"
else ok "unreadable-grant: the retry removes the revoked grant"; fi
if grep -qF "n2-fleet:$U3" "$uak" 2>/dev/null; then
  ok "unreadable-grant: the retry leaves the other peer's grant intact"
else bad "unreadable-grant: the retry leaves the other peer's grant intact" "$(cat "$uak" 2>&1)"; fi
if [ -s "$base/ru1/.n2-agents/fleet/revoke-pending" ]; then
  bad "unreadable-grant: the pending ledger is cleared" \
    "$(cat "$base/ru1/.n2-agents/fleet/revoke-pending")"
else ok "unreadable-grant: the pending ledger is cleared"; fi
out=$(peer ru2 fleet ping "$U1" 2>&1); rc=$?
denied "unreadable-grant: ru2 can no longer call ru1" "$out" "$rc"

# --- 38. the fleet pin is the only source of host trust --------------------
mark "38. the fleet pin is the only source of host trust"
# UserKnownHostsFile pins the key the fleet approved, but ssh also consults
# GlobalKnownHostsFile (/etc/ssh/ssh_known_hosts*) by default. A key trusted
# there -- installed machine-wide, never approved by the fleet -- would
# satisfy verification for a host whose fleet pin says something else. The
# carrier disables that second source; this reads the effective configuration
# out of ssh itself rather than trusting the flag string.
mkdir -p "$base/hk1"; peer hk1 fleet init --machine hk1 >/dev/null 2>&1
geff=$(env HOME="$base/hk1" N2_FLEET_AGENTS="$repo/agents" sh -c \
  "root=\$HOME/.n2-agents; . \"$repo/fleet.sh\"; set -- \$(fleet_ssh_opts hkalias); \
   ssh -G \"\$@\" host.invalid 2>&1" | grep -i '^globalknownhostsfile')
check "hostkey: ssh resolves no global known_hosts for the carrier" \
  "globalknownhostsfile /dev/null" "$geff"
ueff=$(env HOME="$base/hk1" N2_FLEET_AGENTS="$repo/agents" sh -c \
  "root=\$HOME/.n2-agents; . \"$repo/fleet.sh\"; set -- \$(fleet_ssh_opts hkalias); \
   ssh -G \"\$@\" host.invalid 2>&1" | grep -i '^userknownhostsfile')
check "hostkey: ssh resolves the fleet file as the only user known_hosts" \
  "/fleet/known_hosts" "$ueff"
case $ueff in *known_hosts\ *|*known_hosts2*)
  bad "hostkey: no second user known_hosts is consulted" "$ueff" ;;
  *) ok "hostkey: no second user known_hosts is consulted" ;; esac
# And the disable wins over a later attempt to re-add one: ssh keeps the first
# value it is given, so a global file appended after the carrier's flags
# cannot resurrect the trust source.
geff2=$(env HOME="$base/hk1" N2_FLEET_AGENTS="$repo/agents" sh -c \
  "root=\$HOME/.n2-agents; . \"$repo/fleet.sh\"; set -- \$(fleet_ssh_opts hkalias); \
   ssh -G \"\$@\" -o GlobalKnownHostsFile=$base/hk1/rogue_known_hosts host.invalid 2>&1" \
  | grep -i '^globalknownhostsfile')
check "hostkey: a later global known_hosts cannot override the carrier" \
  "globalknownhostsfile /dev/null" "$geff2"

# --- 39. concurrent grant changes do not resurrect a revoked peer ----------
mark "39. concurrent grant changes do not resurrect a revoked peer"
# Both grant mutations are read-modify-write over the whole authorized_keys
# file. Unserialized, two revocations racing each other each filter their own
# snapshot and write it back, so the later writer restores the line the
# earlier one removed: a revoked peer whose ssh door is open again, with both
# calls reporting success. Measured before the lock: the surviving grant
# appeared in every one of 30 trials.
ccak=$base/concurrent_authorized_keys
ccfail=0; ccclob=0; cctrials=12; cci=0
while [ "$cci" -lt "$cctrials" ]; do
  cci=$((cci+1))
  { echo 'restrict,command="x" ssh-ed25519 AAAAC3Nz1 n2-fleet:SHA256:concA'
    echo 'restrict,command="x" ssh-ed25519 AAAAC3Nz2 n2-fleet:SHA256:concB'
    echo 'ssh-ed25519 AAAAC3Nz3 unrelated@elsewhere'; } > "$ccak"
  for ccp in concA concB; do
    env HOME="$base/alpha" N2_FLEET_AGENTS="$repo/agents" N2_FLEET_AUTHORIZED_KEYS="$ccak" \
      sh -c "root=\$HOME/.n2-agents; . \"$repo/fleet.sh\"; fleet_deauthorize SHA256:$ccp" \
      >/dev/null 2>&1 &
  done
  wait
  grep -q 'n2-fleet:' "$ccak" 2>/dev/null && ccfail=$((ccfail+1))
  grep -q 'unrelated@elsewhere' "$ccak" 2>/dev/null || ccclob=$((ccclob+1))
  cci=$cci
done
if [ "$ccfail" = 0 ]; then ok "concurrency: $cctrials concurrent revocation pairs leave no grant behind"
else bad "concurrency: $cctrials concurrent revocation pairs leave no grant behind" \
  "$ccfail trial(s) still had a n2-fleet grant"; fi
if [ "$ccclob" = 0 ]; then ok "concurrency: concurrent revocations preserve unrelated grants"
else bad "concurrency: concurrent revocations preserve unrelated grants" "$ccclob trial(s) lost it"; fi
# A revoke racing a re-approval must also not drop the surviving grant.
ccfail=0; cci=0
while [ "$cci" -lt 8 ]; do
  cci=$((cci+1))
  { echo 'restrict,command="x" ssh-ed25519 AAAAC3Nz1 n2-fleet:SHA256:concA'
    echo 'restrict,command="x" ssh-ed25519 AAAAC3Nz2 n2-fleet:SHA256:concB'; } > "$ccak"
  env HOME="$base/alpha" N2_FLEET_AGENTS="$repo/agents" N2_FLEET_AUTHORIZED_KEYS="$ccak" \
    sh -c "root=\$HOME/.n2-agents; . \"$repo/fleet.sh\"; fleet_deauthorize SHA256:concA" \
    >/dev/null 2>&1 &
  env HOME="$base/alpha" N2_FLEET_AGENTS="$repo/agents" N2_FLEET_AUTHORIZED_KEYS="$ccak" \
    sh -c "root=\$HOME/.n2-agents; . \"$repo/fleet.sh\"; fleet_deauthorize SHA256:missing" \
    >/dev/null 2>&1 &
  wait
  grep -q 'n2-fleet:SHA256:concA' "$ccak" 2>/dev/null && ccfail=$((ccfail+1))
  grep -q 'n2-fleet:SHA256:concB' "$ccak" 2>/dev/null || ccfail=$((ccfail+1))
done
if [ "$ccfail" = 0 ]; then ok "concurrency: a no-op revocation racing a real one changes nothing else"
else bad "concurrency: a no-op revocation racing a real one changes nothing else" "$ccfail deviation(s)"; fi
# The lock must not survive its holder: a stale directory left by a killed
# process is adopted, not waited on forever.
mkdir -p "$ccak.n2lock"; echo 999999 > "$ccak.n2lock/pid"
{ echo 'restrict,command="x" ssh-ed25519 AAAAC3Nz1 n2-fleet:SHA256:concA'; } > "$ccak"
out=$(env HOME="$base/alpha" N2_FLEET_AGENTS="$repo/agents" N2_FLEET_AUTHORIZED_KEYS="$ccak" \
  sh -c "root=\$HOME/.n2-agents; . \"$repo/fleet.sh\"; fleet_deauthorize SHA256:concA" 2>&1); rc=$?
if [ "$rc" = 0 ] && ! grep -q 'n2-fleet:' "$ccak" 2>/dev/null; then
  ok "concurrency: a lock left by a dead process is adopted"
else bad "concurrency: a lock left by a dead process is adopted" "rc=$rc out=$out"; fi
if [ -d "$ccak.n2lock" ]; then bad "concurrency: the lock is released afterwards" "still held"
else ok "concurrency: the lock is released afterwards"; fi

# A lock directory with no pid file must not wedge the queue. Freeing a lock
# with `rm -rf` is not atomic -- it unlinks the entries and then rmdir's the
# directory -- so a waiter that creates a recovery marker inside it during
# that window makes the rmdir fail with ENOTEMPTY and strands the directory
# with no pid. Measured on this machine: the directory survived 19 of 200
# such races. Before the atomic-rename free, that stranded directory read as
# "a live acquire that has not written its pid yet" to every later waiter,
# which then waited out the full 15s ceiling and failed a lock nobody held.
ccnp=$base/nopid; rm -rf "$ccnp"; mkdir -p "$ccnp"; ccnpf=$ccnp/authorized_keys
: > "$ccnpf"; mkdir -p "$ccnpf.n2lock"
ccnps=$(date +%s)
env HOME="$base/alpha" N2_FLEET_AGENTS="$repo/agents" N2_FLEET_AUTHORIZED_KEYS="$ccnpf" \
  sh -c "root=\$HOME/.n2-agents; . \"$repo/fleet.sh\"; fleet_ak_lock || exit 3; fleet_ak_unlock" \
  >/dev/null 2>&1; rc=$?
ccnpe=$(( $(date +%s) - ccnps ))
if [ "$rc" = 0 ] && [ "$ccnpe" -lt 10 ] && [ ! -d "$ccnpf.n2lock" ]; then
  ok "concurrency: a lock stranded without a pid file is adopted"
else bad "concurrency: a lock stranded without a pid file is adopted" \
  "rc=$rc elapsed=${ccnpe}s leftover=$([ -d "$ccnpf.n2lock" ] && echo yes || echo no)"; fi

# Recovering a stale lock must itself be exclusive. A waiter that deletes the
# lock the moment it sees a dead pid hands the same permission to every other
# waiter that read that pid: each deletes, re-creates and enters, so the
# recovery path reintroduces the double entry the lock exists to prevent.
# Four real processes (distinct pids) are released together onto one lock left
# by a dead holder; each records itself as live for 0.05s and counts how many
# live markers exist. Measured before the steal marker, with this harness:
# 3 of 30 trials had two holders inside at once; after it, 0 of 30.
ccl=$base/locksteal; rm -rf "$ccl"; mkdir -p "$ccl"
ccover=0; ccto=0; ccacq=0; cci=0
while [ "$cci" -lt 25 ]; do
  cci=$((cci+1))
  ccd=$ccl/t$cci; mkdir -p "$ccd/live"; ccf=$ccd/authorized_keys; : > "$ccf"
  : > "$ccd/seen"
  # a pid that is certainly dead, so every waiter takes the recovery path
  sh -c 'exit 0' & ccdead=$!; wait "$ccdead" 2>/dev/null
  mkdir -p "$ccf.n2lock"; printf '%s\n' "$ccdead" > "$ccf.n2lock/pid"
  ccpids=; ccn=0
  while [ "$ccn" -lt 4 ]; do
    ccn=$((ccn+1))
    env HOME="$base/alpha" N2_FLEET_AUTHORIZED_KEYS="$ccf" ccd="$ccd" \
      sh -c "root=\$HOME/.n2-agents; . \"$repo/fleet.sh\"
             while [ ! -f \"\$ccd/go\" ]; do :; done
             fleet_ak_lock || exit 3
             : > \"\$ccd/live/\$\$\"
             sleep 0.05
             ls \"\$ccd/live\" | wc -l >> \"\$ccd/seen\"
             rm -f \"\$ccd/live/\$\$\"
             fleet_ak_unlock" >/dev/null 2>&1 &
    ccpids="$ccpids $!"
  done
  : > "$ccd/go"
  for ccp in $ccpids; do
    if wait "$ccp"; then ccacq=$((ccacq+1)); else ccto=$((ccto+1)); fi
  done
  awk '$1+0>1{f=1} END{exit !f}' "$ccd/seen" 2>/dev/null && ccover=$((ccover+1))
done
if [ "$ccover" = 0 ]; then ok "concurrency: concurrent stale-lock recovery admits one holder"
else bad "concurrency: concurrent stale-lock recovery admits one holder" \
  "$ccover of 25 trials had overlapping holders"; fi
if [ "$ccacq" = 100 ]; then ok "concurrency: every waiter on a stale lock still acquires it"
else bad "concurrency: every waiter on a stale lock still acquires it" \
  "$ccacq of 100 acquired, $ccto failed"; fi

# The pid-less variant of the same exclusivity requirement, and the one that
# catches a grace counter that is never reset. A waiter classifies an empty
# pid file as stale only after a 2s grace; once that grace expires the waiter
# either recovers the lock or loses the race to re-take it. If the counter
# survives that round, the loser walks into the next holder's
# mkdir-to-printf window -- an empty pid belonging to a genuinely live
# acquire -- and steals a lock that is held. Four real processes are released
# onto one stranded pid-less lock and then hand the lock around between
# themselves, so every handoff re-opens that window.
ccnx=$base/nopidsteal; rm -rf "$ccnx"; mkdir -p "$ccnx"
ccnxover=0; ccnxacq=0; ccnxto=0; cci=0
while [ "$cci" -lt 8 ]; do
  cci=$((cci+1))
  ccd=$ccnx/t$cci; mkdir -p "$ccd/live"; ccf=$ccd/authorized_keys; : > "$ccf"
  : > "$ccd/seen"
  mkdir -p "$ccf.n2lock"            # stranded: directory with no pid file
  ccpids=; ccn=0
  while [ "$ccn" -lt 4 ]; do
    ccn=$((ccn+1))
    env HOME="$base/alpha" N2_FLEET_AUTHORIZED_KEYS="$ccf" ccd="$ccd" \
      sh -c "root=\$HOME/.n2-agents; . \"$repo/fleet.sh\"
             while [ ! -f \"\$ccd/go\" ]; do :; done
             ccr=0
             while [ \"\$ccr\" -lt 3 ]; do
               ccr=\$((ccr+1))
               fleet_ak_lock || exit 3
               : > \"\$ccd/live/\$\$\"
               sleep 0.1
               ls \"\$ccd/live\" | wc -l >> \"\$ccd/seen\"
               rm -f \"\$ccd/live/\$\$\"
               fleet_ak_unlock
             done" >/dev/null 2>&1 &
    ccpids="$ccpids $!"
  done
  : > "$ccd/go"
  for ccp in $ccpids; do
    if wait "$ccp"; then ccnxacq=$((ccnxacq+1)); else ccnxto=$((ccnxto+1)); fi
  done
  awk '$1+0>1{f=1} END{exit !f}' "$ccd/seen" 2>/dev/null && ccnxover=$((ccnxover+1))
done
if [ "$ccnxover" = 0 ]; then
  ok "concurrency: a recovered pid-less lock is not stolen from its next holder"
else bad "concurrency: a recovered pid-less lock is not stolen from its next holder" \
  "$ccnxover of 8 trials had overlapping holders"; fi
if [ "$ccnxacq" = 32 ]; then ok "concurrency: every waiter on a stranded pid-less lock completes"
else bad "concurrency: every waiter on a stranded pid-less lock completes" \
  "$ccnxacq of 32 completed, $ccnxto failed"; fi

# --- 40. approval is fleet-wide --------------------------------------------
mark "40. approval is fleet-wide"
# fa and fb are approved with each other. fc joins fa with no code and fa's
# operator approves it. Nothing is run on fb or fc after that.
for h in fa fb fc fd; do mkdir -p "$base/$h"; peer "$h" fleet init --machine "$h" >/dev/null; done
FA=$(fpof fa); FB=$(fpof fb); FC=$(fpof fc); FD=$(fpof fd)
peer fb fleet pair --home "$base/fa" --code "$(peer fa fleet invite --peer "$FB" 2>/dev/null)" >/dev/null 2>&1
peer fc fleet join --home "$base/fa" >/dev/null 2>&1
out=$(peer fa fleet approve "$FC" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "fleet-wide: approve succeeds"; else bad "fleet-wide: approve succeeds" "rc=$rc: $out"; fi
check "fleet-wide: approve tells the other members" "told	$FB	ok" "$out"
check "fleet-wide: fb lists fc approved" "approved" "$(peer fb fleet peers --no-probe | grep -F "$FC")"
check "fleet-wide: fc lists fb approved" "approved" "$(peer fc fleet peers --no-probe | grep -F "$FB")"
check "fleet-wide: fb -> fc signed round trip" "pong fc" "$(peer fb fleet ping "$FC" 2>&1)"
check "fleet-wide: fc -> fb signed round trip" "pong fb" "$(peer fc fleet ping "$FB" 2>&1)"

# Regression (the M4 and the mini): the joiner holds a peer record with a
# pinned host key, and a stale request without one sits beside it, as the old
# `discover` filed. The approval callback must use the pinned record.
mkdir -p "$base/fm4" "$base/fmini"
peer fm4 fleet init --machine fm4 >/dev/null; peer fmini fleet init --machine fmini >/dev/null
FM4=$(fpof fm4); FMINI=$(fpof fmini)
peer fm4 fleet join --home "$base/fmini" >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -f "$base/fmini-host" </dev/null
raw fm4 "pd=\$(fleet_peer_dir '$FMINI'); printf 'x %s\\n' \"\$(awk '{print \$1\" \"\$2}' '$base/fmini-host.pub')\" | fleet_pin_host \"\$pd\"; \
  sd=\$(fleet_pending_dir '$FMINI'); mkdir -p \"\$sd\"; cp \"\$pd/key.pub\" \"\$sd/\"; \
  fleet_meta_set \"\$sd\" peer '$FMINI'; fleet_meta_set \"\$sd\" transport ssh; fleet_meta_set \"\$sd\" state pending" >/dev/null 2>&1
if [ -s "$base/fm4/.n2-agents/fleet/peers/$(raw fm4 "fleet_slug '$FMINI'")/host.pub" ] &&
   [ -d "$base/fm4/.n2-agents/fleet/pending/$(raw fm4 "fleet_slug '$FMINI'")" ]; then
  ok "regression: fixture has a pinned record and a stale host-key-less request"
else bad "regression: fixture has a pinned record and a stale host-key-less request" "fixture not built"; fi
out=$(peer fmini fleet approve "$FM4" 2>&1)
check "regression: the approval callback lands" "notified" "$out"
check "regression: the joiner approves its sponsor" "approved" "$(raw fm4 "fleet_peer_state '$FMINI'")"
if [ -z "$(ls "$base/fm4/.n2-agents/fleet/pending" 2>/dev/null)" ]; then
  ok "regression: the stale request is cleared by the approval"
else bad "regression: the stale request is cleared by the approval" "$(ls "$base/fm4/.n2-agents/fleet/pending")"; fi
refute "regression: no missing-host-key rejection" "missing-host-key" "$(cat "$base/fm4/.n2-agents/fleet/events.log")"
# discover no longer files host-key-less requests: fa holds an ssh member
# approved with no pinned host key, and fb must refuse it, not file it.
ssh-keygen -q -t ed25519 -N '' -f "$base/fx-id" </dev/null
FX=$(ssh-keygen -lf "$base/fx-id.pub" | awk '{print $2}')
raw fa "xd=\$(fleet_peer_dir '$FX'); mkdir -p \"\$xd\"; cp '$base/fx-id.pub' \"\$xd/key.pub\"; \
  fleet_meta_set \"\$xd\" peer '$FX'; fleet_meta_set \"\$xd\" machine fx; fleet_meta_set \"\$xd\" transport ssh; \
  fleet_meta_set \"\$xd\" address 198.51.100.9; fleet_meta_set \"\$xd\" state approved" >/dev/null 2>&1
out=$(peer fb fleet discover 2>&1); rc=$?
denied "discover: a member without a pinned host key is refused" "$out" "$rc"
check "discover: the refusal names the missing host key" "missing-host-key" "$out"
if [ -z "$(ls "$base/fb/.n2-agents/fleet/pending" 2>/dev/null)" ]; then
  ok "discover: no pending request is filed"
else bad "discover: no pending request is filed" "$(ls "$base/fb/.n2-agents/fleet/pending")"; fi
check "discover: the refused member stays unknown" "unknown" "$(raw fb "fleet_peer_state '$FX'")"
raw fa "rm -rf \"\$(fleet_peer_dir '$FX')\"" >/dev/null 2>&1   # no undialable member for later fan-outs

# Negatives. A roster line for a fresh identity, as an approved referrer sends it.
ssh-keygen -q -t ed25519 -N '' -f "$base/fy-id" </dev/null
FY=$(ssh-keygen -lf "$base/fy-id.pub" | awk '{print $2}')
fykey=$(awk '{print $1"_"$2}' "$base/fy-id.pub")
printf '%s\tfy\texec\tapproved\t-\t%s\t-\t-\t-\t%s\n' "$FY" "$fykey" "$base/fy" > "$base/fy.line"
# fd is pending on fb, so its word adopts nothing.
peer fd fleet join --home "$base/fb" >/dev/null 2>&1
out=$(raw fd "fleet_envelope '$FB' admit '$base/fy.line'" 2>/dev/null | raw fb "fleet_serve" 2>&1); rc=$?
denied "negative: a pending referrer's admit is refused" "$out" "$rc"
check "negative: the refusal names the approval gate" "not-approved" "$out"
out=$(raw fb "fleet_adopt '$FD' < '$base/fy.line'" 2>&1); rc=$?
denied "negative: fleet_adopt refuses a non-approved referrer" "$out" "$rc"
check "negative: nothing is adopted from a non-approved referrer" "unknown" "$(raw fb "fleet_peer_state '$FY'")"
# Only entries the referrer itself holds approved.
sed 's/	approved	/	pending	/' "$base/fy.line" > "$base/fy.pending"
peer fa fleet send "$FB" --verb admit --payload-file "$base/fy.pending" >/dev/null 2>&1
check "negative: an entry the referrer holds pending is not adopted" "unknown" "$(raw fb "fleet_peer_state '$FY'")"
# A known id paired with another key is a conflict: refused, journaled, pin kept.
fckey=$(cat "$base/fb/.n2-agents/fleet/peers/$(raw fb "fleet_slug '$FC'")/key.pub")
printf '%s\tfc\texec\tapproved\t-\t%s\t-\t-\t-\t%s\n' "$FC" "$fykey" "$base/fy" > "$base/fc.conflict"
out=$(peer fa fleet send "$FB" --verb admit --payload-file "$base/fc.conflict" 2>&1); rc=$?
denied "negative: a conflicting key for an approved member is refused" "$out" "$rc"
check "negative: the conflict reason is named" "key-mismatch" "$out"
check "negative: the conflict is journaled" "adopt key-mismatch peer=$FC" "$(cat "$base/fb/.n2-agents/fleet/events.log")"
check "negative: the approved record keeps its key" "$fckey" \
  "$(cat "$base/fb/.n2-agents/fleet/peers/$(raw fb "fleet_slug '$FC'")/key.pub")"
# A revoked id is never re-adopted, by admit or by discover.
peer fb fleet revoke "$FC" >/dev/null 2>&1
out=$(peer fa fleet approve "$FC" 2>&1)
check "negative: re-approving elsewhere reports the member that refused" "told	$FB	fail" "$out"
check "negative: the refusal names the revocation" "revoked" "$out"
peer fb fleet discover >/dev/null 2>&1
check "negative: a revoked id is not re-adopted" "revoked" "$(raw fb "fleet_peer_state '$FC'")"

# --- 41. a Claude token is shared with the same account ---------------------
mark "41. a Claude token is shared with the same account"
# ca saves a long-lived token for Work. cb holds Work and Default with the
# same sign-in (email in another case), cc another member of the organization.
# The token rides the private carrier, so every hop is a real ssh login.
# Seam: organization() is the only network call. Python loads sitecustomize
# from PYTHONPATH at startup, so this section's peers run with one that
# answers count_tokens from a hash->org table and refuses any other URL. No
# product code reads it; anyone who can set PYTHONPATH can already run code.
sshd_bin=$(command -v sshd 2>/dev/null || { [ -x /usr/sbin/sshd ] && echo /usr/sbin/sshd; })
if [ -z "${sshd_bin:-}" ]; then
  skip claude-token "no sshd binary on this host"
else
  ctd=$base/ctssh ctbin=$base/ctbin ctapi=$base/ctapi cttmp=$base/cttmp
  mkdir -p "$ctd" "$ctbin" "$ctapi" "$cttmp"; chmod 700 "$ctd"
  ctorg=11111111-1111-4111-8111-111111111111
  ctpath=$ctbin:/usr/bin:/bin:/usr/sbin:/sbin
  ctpeer() { h=$1; shift; env HOME="$base/$h" PATH="$ctpath" PYTHONPATH="$ctapi" TMPDIR="$cttmp" \
    N2_FLEET_AGENTS="$repo/agents" "$repo/agents" "$@"; }
  ctread() { /usr/bin/python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["env"]["CLAUDE_CODE_OAUTH_TOKEN"])
except (OSError, KeyError): print("none")' "$base/$1/.n2-agents/${2:-Work}/claude/settings.json"; }
  # A bounded read: `tr </dev/urandom | head` never ends where SIGPIPE is ignored.
  cttoken() { printf 'sk-ant-oat01-%sAA' "$(od -An -N64 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-93)"; }
  ctknown() { printf '%s %s\n' "$(printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1)" "$ctorg" >> "$ctapi/orgs"; }
  cat > "$ctapi/sitecustomize.py" <<'PY'
import hashlib, json, os, sys, urllib.error, urllib.request
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, 'argv.log'), 'a') as log:
    log.write(json.dumps(sys.argv) + '\n')
class Reply:
    def __init__(self, org): self.headers = {'anthropic-organization-id': org}
    def __enter__(self): return self
    def __exit__(self, *exc): return False
def urlopen(request, *args, **kwargs):
    url = getattr(request, 'full_url', request)
    if url != 'https://api.anthropic.com/v1/messages/count_tokens':
        raise OSError('offline test: ' + url)
    digest = hashlib.sha256(request.get_header('Authorization').split()[1].encode()).hexdigest()
    for line in open(os.path.join(here, 'orgs')):
        if line.split()[0] == digest:
            return Reply(line.split()[1])
    raise urllib.error.HTTPError(url, 401, 'unknown token', {}, None)
urllib.request.urlopen = urlopen
PY
  : > "$ctapi/orgs"
  printf '#!/bin/sh\nprintf "%%s\\n" "ssh $*" >> "%s/argv.log"\nexec /usr/bin/ssh "$@"\n' "$ctapi" > "$ctbin/ssh"
  printf '#!/bin/sh\nexit 44\n' > "$ctbin/security"
  cat > "$ctbin/claude" <<EOF
#!/bin/sh
echo "\${HOME##*/} \$*" >> "$base/ct-claude-calls"
[ "\$1 \${2:-}" = "auth login" ] &&
  printf '{"oauthAccount": {"emailAddress": "%s", "organizationUuid": "$ctorg"}}' "\$FAKE_EMAIL" > "\$CLAUDE_CONFIG_DIR/.claude.json"
exit 0
EOF
  chmod +x "$ctbin/ssh" "$ctbin/security" "$ctbin/claude"; : > "$base/ct-claude-calls"

  for h in ca cb cc; do mkdir -p "$base/$h"; peer "$h" fleet init --machine "$h" >/dev/null; done
  CA=$(fpof ca); CB=$(fpof cb); CC=$(fpof cc)
  peer cb fleet pair --home "$base/ca" --code "$(peer ca fleet invite --peer "$CB" 2>/dev/null)" >/dev/null 2>&1
  peer cc fleet pair --home "$base/ca" --code "$(peer ca fleet invite --peer "$CC" 2>/dev/null)" >/dev/null 2>&1
  ctpid=$(/usr/bin/python3 -c 'import uuid; print(uuid.uuid4())')
  for pair in ca:seth@example.com cb:Seth@Example.com cc:other@example.com; do
    s=$base/${pair%%:*}/.n2-agents/Work; mkdir -p "$s/claude"
    printf '{"profileId":"%s","schemaVersion":1}\n' "$ctpid" > "$s/.n2-profile"
    printf '{"oauthAccount": {"emailAddress": "%s", "organizationUuid": "%s"}}' "${pair#*:}" "$ctorg" > "$s/claude/.claude.json"
  done
  # Default has no profile id; the account alone decides.
  mkdir -p "$base/cb/.n2-agents/Default/claude"; cp "$base/cb/.n2-agents/Work/claude/.claude.json" "$base/cb/.n2-agents/Default/claude/"
  cat "$base"/ca/.n2-agents/fleet/identity/id_ed25519.pub "$base"/cb/.n2-agents/fleet/identity/id_ed25519.pub \
    "$base"/cc/.n2-agents/fleet/identity/id_ed25519.pub > "$ctd/authorized_keys"
  ssh-keygen -q -t ed25519 -N '' -C ct-host -f "$ctd/hk" </dev/null
  chmod 600 "$ctd/authorized_keys" "$ctd/hk"
  ctport=0
  for try in 22511 22537 22559 22583; do
    cat > "$ctd/sshd_config" <<EOF
Port $try
ListenAddress 127.0.0.1
HostKey $ctd/hk
PidFile $ctd/sshd.pid
AuthorizedKeysFile $ctd/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
LogLevel ERROR
EOF
    "$sshd_bin" -f "$ctd/sshd_config" -E "$ctd/sshd.log" 2>>"$ctd/sshd.err" && { ctport=$try; break; }
  done
  waited=0
  while [ "$ctport" != 0 ] && [ ! -s "$ctd/sshd.pid" ] && [ "$waited" -lt 30 ]; do
    waited=$((waited+1)); perl -e 'select undef,undef,undef,0.1' 2>/dev/null || true
  done
  if [ "$ctport" = 0 ] || [ ! -s "$ctd/sshd.pid" ]; then
    skip claude-token "could not start a user-level sshd ($(tail -1 "$ctd/sshd.err" 2>/dev/null))"
  else
    ctsshd=$(cat "$ctd/sshd.pid")
    cleanup() { is_main || return 0; kill "$ctsshd" 2>/dev/null; [ -n "${N2_FLEET_KEEP:-}" ] || { chmod -R u+w "$base" 2>/dev/null; rm -rf "$base"; }; }
    ctroute() {  # ctroute <from> <to-id> <to-home>
      raw "$1" "d=\"\$(fleet_peer_dir '$2')\"; fleet_meta_set \"\$d\" transport ssh
        fleet_meta_set \"\$d\" address 127.0.0.1; fleet_meta_set \"\$d\" port $ctport
        fleet_meta_set \"\$d\" user '$(id -un)'
        fleet_meta_set \"\$d\" command 'env HOME=$base/$3 PATH=$ctpath PYTHONPATH=$ctapi TMPDIR=$cttmp N2_FLEET_AGENTS=$repo/agents $repo/agents'"
      peer "$1" fleet rehost "$2" --host-key "ct-host $(awk '{print $1" "$2}' "$ctd/hk.pub")" >/dev/null
    }
    ctroute ca "$CB" cb; ctroute ca "$CC" cc; ctroute cb "$CA" ca; ctroute cc "$CA" ca

    T=$(cttoken); ctknown "$T"
    printf '{"model": "opus", "env": {"CLAUDE_CODE_OAUTH_TOKEN": "%s"}}\n' "$T" > "$base/ca/.n2-agents/Work/claude/settings.json"
    out=$(ctpeer ca fleet claude-token push Work 2>&1)
    check "claude-token: the same account pulls the token" "told	$CB	ok	saved" "$out"
    check "claude-token: another member of the organization is skipped" "told	$CC	ok	skipped other-account" "$out"
    if [ "$(ctread cb)" = "$T" ]; then ok "claude-token: cb holds the identical token"
    else bad "claude-token: cb holds the identical token" "cb has $(ctread cb | cut -c1-16)…"; fi
    if [ "$(ctread cb Default)" = "$T" ]; then ok "claude-token: cb's Default, same account, holds it too"
    else bad "claude-token: cb's Default, same account, holds it too" "cb Default has $(ctread cb Default | cut -c1-16)…"; fi
    check "claude-token: cc holds no token" "none" "$(ctread cc)"
    out=$(ctpeer cc fleet claude-token pull Work 2>&1); rc=$?
    denied "claude-token: another member cannot pull it" "$out" "$rc"
    check "claude-token: cc still holds no token" "none" "$(ctread cc)"

    # Sign-in asks the fleet before setup-token.
    /usr/bin/python3 "$repo/claude-token.py" clear "$base/cb/.n2-agents/Work/claude"
    out=$(FAKE_EMAIL=seth@example.com N2_CLAUDE_LONG_TOKEN=1 ctpeer cb login Work --vendor claude 2>&1 </dev/null); rc=$?
    if [ "$rc" = 0 ]; then ok "claude-token: sign-in succeeds"; else bad "claude-token: sign-in succeeds" "rc=$rc: $out"; fi
    check "claude-token: sign-in names the Mac the token came from" "uses the long-lived token from ca" "$out"
    if [ "$(ctread cb)" = "$T" ]; then ok "claude-token: sign-in saved the fleet's token"
    else bad "claude-token: sign-in saved the fleet's token" "cb has $(ctread cb | cut -c1-16)…"; fi
    refute "claude-token: cb never ran setup-token" "cb setup-token" "$(cat "$base/ct-claude-calls")"
    # Control: with no same-account token in the fleet, setup-token still runs.
    out=$(FAKE_EMAIL=other@example.com N2_CLAUDE_LONG_TOKEN=1 ctpeer cc login Work --vendor claude 2>&1 </dev/null); rc=$?
    denied "claude-token: a sign-in nobody shares with falls back to setup-token" "$out" "$rc"
    check "claude-token: cc ran setup-token" "cc setup-token" "$(cat "$base/ct-claude-calls")"

    # A pending or revoked peer gets nothing, by notice or by pull.
    T2=$(cttoken); ctknown "$T2"
    printf '{"env": {"CLAUDE_CODE_OAUTH_TOKEN": "%s"}}\n' "$T2" > "$base/ca/.n2-agents/Work/claude/settings.json"
    raw ca "fleet_meta_set \"\$(fleet_peer_dir '$CB')\" state pending"
    out=$(ctpeer ca fleet claude-token push Work 2>&1)
    refute "claude-token: a pending peer is not told" "$CB" "$out"
    out=$(ctpeer cb fleet claude-token pull Work 2>&1); rc=$?
    denied "claude-token: a pending peer cannot pull" "$out" "$rc"
    raw ca "fleet_meta_set \"\$(fleet_peer_dir '$CB')\" state approved"
    peer ca fleet revoke "$CB" >/dev/null 2>&1
    out=$(ctpeer cb fleet claude-token pull Work 2>&1); rc=$?
    denied "claude-token: a revoked peer cannot pull" "$out" "$rc"
    check "claude-token: cb kept the token it had" "$T" "$(ctread cb)"

    # A member that cannot be reached is named, not hidden.
    kill "$ctsshd" 2>/dev/null
    out=$(ctpeer ca fleet claude-token push Work 2>&1)
    check "claude-token: an unreachable member is reported" "could not share the 'Work' Claude token with $CC" "$out"

    # The token lives only in the two settings files: never in fleet state,
    # events, journals, temp files, logs or any process's arguments.
    for t in "$T" "$T2"; do
      found=$(grep -rlF "$t" "$base/ca" "$base/cb" "$base/cc" "$cttmp" "$ctapi" "$base/ct-claude-calls" 2>/dev/null |
        grep -vx "$base/ca/.n2-agents/Work/claude/settings.json" | grep -vx "$base/cb/.n2-agents/Work/claude/settings.json" |
        grep -vx "$base/cb/.n2-agents/Default/claude/settings.json")
      if [ -z "$found" ]; then ok "claude-token: a token is stored only in the slots holding it"
      else bad "claude-token: a token is stored only in the slots holding it" "$found"; fi
    done
    check "claude-token: argv was recorded" "claude-token.py" "$(cat "$ctapi/argv.log")"
  fi
fi

# --- framing and decoding --------------------------------------------------
# The declared payload length is signed, so a body that disagrees with it is
# not the body that was signed. Before this check existed, a ping declaring
# len=999999 with an empty payload reached the handler and answered OK: the
# decoder discarded base64's exit status and nobody compared the sizes.
mkdir -p "$base/fr1" "$base/fr2"
for h in fr1 fr2; do peer "$h" fleet init --machine "$h" >/dev/null; done
FR1=$(fpof fr1); FR2=$(fpof fr2)
peer fr2 fleet pair --home "$base/fr1" --code "$(peer fr1 fleet invite --peer "$FR1" 2>/dev/null)" >/dev/null 2>&1
peer fr1 fleet pair --home "$base/fr2" --code "$(peer fr2 fleet invite --peer "$FR1" 2>/dev/null)" >/dev/null 2>&1

# Sign a well-formed envelope from fr2 to fr1 with caller-chosen len/body.
forge() { # forge <verb> <len> <base64-body-file>
  env HOME="$base/fr2" N2_FLEET_AGENTS="$repo/agents" sh -c \
    "root=\$HOME/.n2-agents; self=\"$repo/agents\"; . \"$repo/fleet.sh\"
     d=\$(mktemp -d)
     { echo \"\$FLEET_PROTO\"; echo from=\$(fleet_self_id); echo to=$FR1
       echo verb=$1; echo nonce=\$(fleet_nonce); echo ts=\$(fleet_now)
       echo len=$2; echo --; cat '$3'; } > \$d/signed
     ssh-keygen -Y sign -q -f \"\$(fleet_key)\" -n \"\$FLEET_NS\" \$d/signed >/dev/null 2>&1
     cat \$d/signed; echo '--sig--'; cat \$d/signed.sig; rm -rf \$d"; }

# control: the same construction with honest framing must still be accepted,
# so a rejection below is about the framing and not about the forging path.
: > "$base/empty.b64"
out=$(forge ping 0 "$base/empty.b64" | peer fr1 fleet serve 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "framing: honestly framed hand-signed envelope is accepted"
else bad "framing: honestly framed hand-signed envelope is accepted" "rc=$rc out=$out"; fi

out=$(forge ping 999999 "$base/empty.b64" | peer fr1 fleet serve 2>&1); rc=$?
denied "framing: declared length with no payload is refused" "$out" "$rc"
check "framing: over-declared length names bad-framing" "bad-framing" "$out"

printf 'hello' | base64 > "$base/hello.b64"
out=$(forge ping 1 "$base/hello.b64" | peer fr1 fleet serve 2>&1); rc=$?
denied "framing: under-declared length is refused" "$out" "$rc"

printf 'not valid base64 !!!\n' > "$base/junk.b64"
out=$(forge ping 5 "$base/junk.b64" | peer fr1 fleet serve 2>&1); rc=$?
denied "framing: undecodable payload is refused" "$out" "$rc"

printf 'aGVsbG8=\n' > "$base/ok.b64"
out=$(forge ping notanumber "$base/ok.b64" | peer fr1 fleet serve 2>&1); rc=$?
denied "framing: non-numeric declared length is refused" "$out" "$rc"

# The refusal must land before any handler runs: no request event is journaled
# for a message that never passed framing.
reqs=$(grep -c 'verb=ping' "$base/fr1/.n2-agents/fleet/events.log" 2>/dev/null || echo 0)
out=$(forge ping 4242 "$base/empty.b64" | peer fr1 fleet serve 2>&1)
reqs2=$(grep -c 'verb=ping' "$base/fr1/.n2-agents/fleet/events.log" 2>/dev/null || echo 0)
if [ "$reqs" = "$reqs2" ]; then ok "framing: bad framing is refused before any handler runs"
else bad "framing: bad framing is refused before any handler runs" "handler ran ($reqs -> $reqs2)"; fi

# A reply the client cannot decode must not be reported as a successful call.
out=$(raw fr2 "fleet_carry() { printf 'OK\n!!not base64!!\n'; }; fleet_call '$FR1' ping; echo rc=\$?" 2>&1)
check "framing: an undecodable reply body is refused" "ERR malformed-reply" "$out"
check "framing: an undecodable reply is a failed call" "rc=1" "$out"

# --- ssh option isolation --------------------------------------------------
# The host pin is only exclusive if nothing else can answer for the host key
# and the hop cannot ride a session opened under different trust.
opts=$(raw fr1 'fleet_ssh_opts peer.example 2222')
check "ssh-isolation: strict host key checking stays on"      "StrictHostKeyChecking=yes" "$opts"
check "ssh-isolation: global known_hosts is removed"          "GlobalKnownHostsFile=/dev/null" "$opts"
check "ssh-isolation: KnownHostsCommand cannot supply keys"   "KnownHostsCommand=none" "$opts"
check "ssh-isolation: connection multiplexing is disabled"    "ControlMaster=no" "$opts"
check "ssh-isolation: no control socket is reused"            "ControlPath=none" "$opts"
check "ssh-isolation: no persistent master is left behind"    "ControlPersist=no" "$opts"
case $opts in *StrictHostKeyChecking=no*|*"UserKnownHostsFile=/dev/null"*)
    bad "ssh-isolation: host verification is never disabled" "$opts" ;;
  *) ok "ssh-isolation: host verification is never disabled" ;; esac
# The bootstrap hop is the one place that uses operator credentials; it must
# carry the same isolation as every later hop.
bopts=$(raw fr1 'fleet_ssh_run print peer.example 2222 1')
check "ssh-isolation: bootstrap hop keeps multiplexing off"   "ControlPath=none" "$bopts"
check "ssh-isolation: bootstrap hop keeps the pin exclusive"  "KnownHostsCommand=none" "$bopts"

# --- the replication and execution suites -------------------------------------------------
# scripts/test-fleet.sh is the declared fleet verification command, so the
# replication/conflict/managed-tool suite runs from here rather than sitting in
# a file nothing calls. It is a separate process with its own fixture and its
# own tally; only its verdict folds into this one.
# N2_FLEET_SUITES=transport runs the transport sections alone.
case "${N2_FLEET_SUITES:-all}" in
  transport)
    printf '\nnote: scripts/test-sync.sh, scripts/test-exec.sh, scripts/test-native-ui.sh skipped (N2_FLEET_SUITES=transport)\n' ;;
  *)
    printf '\n=== scripts/test-sync.sh ===\n'
    if sh "$repo/scripts/test-sync.sh"; then
      printf '=== scripts/test-sync.sh: passed ===\n'
    else
      printf '=== scripts/test-sync.sh: FAILED ===\n'
      fail=$((fail+1))
    fi
    printf '\n=== scripts/test-exec.sh ===\n'
    if sh "$repo/scripts/test-exec.sh"; then
      printf '=== scripts/test-exec.sh: passed ===\n'
    else
      printf '=== scripts/test-exec.sh: FAILED ===\n'
      fail=$((fail+1))
    fi
    # The native panel parses this CLI's output, so its parser contract is a
    # fleet test too: it re-captures live CLI bytes and fails on either drift.
    printf '\n=== scripts/test-native-ui.sh ===\n'
    if sh "$repo/scripts/test-native-ui.sh"; then
      printf '=== scripts/test-native-ui.sh: passed ===\n'
    else
      printf '=== scripts/test-native-ui.sh: FAILED ===\n'
      fail=$((fail+1))
    fi ;;
esac

printf '\n%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
if [ "$skipped" -gt 0 ]; then
  printf 'note: %s section(s) were skipped; re-run with N2_FLEET_REQUIRE_LIVE_SSH=1 to require them\n' "$skipped"
fi
[ "$fail" -eq 0 ]
