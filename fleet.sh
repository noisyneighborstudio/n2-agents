# fleet.sh — fleet identity, enrollment, roster and signed peer transport.
# Sourced by `agents`; see docs/fleet-design.md for the contract. POSIX sh.
#
# Nothing here trusts a hostname, an IP or tailnet membership. A peer is
# authorized by the fingerprint of its fleet identity key and by its roster
# state, checked before any request body is interpreted.

: "${root:=$HOME/.n2-agents}"
fleet_root="$root/fleet"
FLEET_NS="n2-agents-fleet"
FLEET_PROTO="N2FLEET/1"
FLEET_SKEW=${N2_FLEET_SKEW:-300}      # seconds a request may be off by

fleet_die() { echo "agents: $*" >&2; exit 1; }

fleet_now() { date +%s; }

# --- identity --------------------------------------------------------------

fleet_key() { echo "$fleet_root/identity/id_ed25519"; }

# SHA256:… fingerprint of a public key file. This is the peer id.
fleet_fp() { ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'; }

fleet_self_id() {
  [ -f "$(fleet_key).pub" ] || return 1
  fleet_fp "$(fleet_key).pub"
}

fleet_self_machine() {
  if [ -f "$fleet_root/identity/machine" ]; then cat "$fleet_root/identity/machine"
  else hostname -s 2>/dev/null || echo unknown; fi
}

fleet_have_identity() { [ -f "$(fleet_key)" ] && [ -f "$(fleet_key).pub" ]; }

# Create this machine's identity. Idempotent: an existing key is never
# replaced, because replacing it would silently orphan every approval.
fleet_identity_create() {
  machine=${1:-$(hostname -s 2>/dev/null || echo unknown)}
  mkdir -p "$fleet_root/identity" "$fleet_root/peers" "$fleet_root/pending" "$fleet_root/seen"
  chmod 700 "$fleet_root" "$fleet_root/identity" 2>/dev/null || true
  if ! fleet_have_identity; then
    ssh-keygen -q -t ed25519 -N '' -C "n2-agents-fleet $machine" -f "$(fleet_key)" </dev/null >/dev/null 2>&1 ||
      fleet_die "could not create fleet identity key"
    chmod 600 "$(fleet_key)"
  fi
  echo "$machine" > "$fleet_root/identity/machine"
  # Never truncate: re-running `fleet init` must not resurrect revoked peers,
  # and must not forget an ssh grant a past revocation could not remove.
  [ -f "$fleet_root/revoked" ] || : > "$fleet_root/revoked"
  [ -f "$fleet_root/revoke-pending" ] || : > "$fleet_root/revoke-pending"
}

# --- roster ----------------------------------------------------------------

fleet_peer_dir() { echo "$fleet_root/peers/$(fleet_slug "$1")"; }
fleet_pending_dir() { echo "$fleet_root/pending/$(fleet_slug "$1")"; }

# A fingerprint contains '/' and '+', so it cannot be a directory name as-is.
fleet_slug() { printf '%s' "$1" | tr '/+:' '___'; }

fleet_meta() {  # fleet_meta <dir> <key>
  [ -f "$1/meta" ] || return 1
  awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/,""); print; found=1} END{exit !found}' "$1/meta"
}

fleet_meta_set() {  # fleet_meta_set <dir> <key> <value>
  mkdir -p "$1"
  mstmp=$1/.meta.$$
  if [ -f "$1/meta" ]; then awk -F= -v k="$2" '$1!=k' "$1/meta" > "$mstmp"; else : > "$mstmp"; fi
  printf '%s=%s\n' "$2" "$3" >> "$mstmp"
  mv "$mstmp" "$1/meta"
}

fleet_peer_ids() {
  [ -d "$fleet_root/peers" ] || return 0
  for d in "$fleet_root/peers"/*; do
    [ -d "$d" ] || continue
    fleet_meta "$d" peer 2>/dev/null || true
  done
}

fleet_revoked() {  # is this peer id revoked?
  [ -f "$fleet_root/revoked" ] || return 1
  grep -q "^$1 " "$fleet_root/revoked" 2>/dev/null
}

fleet_peer_state() {
  d=$(fleet_peer_dir "$1")
  fleet_revoked "$1" && { echo revoked; return 0; }
  [ -d "$d" ] || { [ -d "$(fleet_pending_dir "$1")" ] && { echo pending; return 0; }; echo unknown; return 0; }
  fleet_meta "$d" state 2>/dev/null || echo unknown
}

fleet_approved() { [ "$(fleet_peer_state "$1")" = approved ]; }

# allowed_signers is regenerated from the roster on every use, so a revoked or
# denied peer stops verifying immediately — there is no stale cached authority.
fleet_allowed_signers() {
  asout=$fleet_root/allowed_signers
  astmp=$asout.$$
  : > "$astmp"
  for asd in "$fleet_root/peers"/*; do
    [ -d "$asd" ] || continue
    aspid=$(fleet_meta "$asd" peer 2>/dev/null) || continue
    [ -f "$asd/key.pub" ] || continue
    fleet_revoked "$aspid" && continue
    # Bind principal→key: the principal is the fingerprint of that very key, so
    # a forged `from=` cannot verify against someone else's signature.
    [ "$(fleet_fp "$asd/key.pub")" = "$aspid" ] || continue
    printf '%s %s\n' "$aspid" "$(awk '{print $1" "$2}' "$asd/key.pub")" >> "$astmp"
  done
  mv "$astmp" "$asout"
  chmod 600 "$asout" 2>/dev/null || true
  echo "$asout"
}

# Signature check set used only to name a refusal precisely: roster peers plus
# peers that merely asked to join. Verifying against it grants nothing — the
# state check below still requires `approved` — but it lets an unapproved peer
# be told "not-approved" instead of the misleading "bad-signature".
fleet_candidate_signers() {
  csout=$fleet_root/candidate_signers
  cstmp=$csout.$$
  : > "$cstmp"
  for csd in "$fleet_root/peers"/* "$fleet_root/pending"/*; do
    [ -d "$csd" ] || continue
    cspid=$(fleet_meta "$csd" peer 2>/dev/null) || continue
    [ -f "$csd/key.pub" ] || continue
    fleet_revoked "$cspid" && continue
    [ "$(fleet_fp "$csd/key.pub")" = "$cspid" ] || continue
    printf '%s %s\n' "$cspid" "$(awk '{print $1" "$2}' "$csd/key.pub")" >> "$cstmp"
  done
  mv "$cstmp" "$csout"
  chmod 600 "$csout" 2>/dev/null || true
  echo "$csout"
}

# A peer-supplied known_hosts line is authority over host verification, so it
# is parsed strictly rather than copied through. Exactly one line survives,
# and only as `<host> <keytype> <base64>`. This is what rejects a marker line
# such as `@cert-authority *` — an enrolling peer that smuggled one into its
# `host=` field would otherwise become a certificate authority for every host
# this machine later ssh'd to, fleet member or not.
fleet_host_line() {  # stdin: candidate lines -> stdout: at most one safe line
  awk 'NF==3 && !seen \
       && $1 ~ /^[A-Za-z0-9._:\[\]-]+$/ \
       && $2 ~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)$/ \
       && $3 ~ /^[A-Za-z0-9+\/=]+$/ { print $1, $2, $3; seen=1 }'
}

# The fingerprint an operator can compare out of band before approving.
fleet_host_fp() { [ -s "$1" ] && ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'; }

# Pin one host key line for a peer, re-keyed to that peer's own alias. The
# remote reports its own `hostname`, which routinely differs from the tailnet
# name or IP in the peer record; a line keyed to the wrong name is a pin ssh
# will never consult, i.e. a silent downgrade to no verification.
# The known_hosts hostname a peer's pin is filed under. It must be unique per
# *peer*, not per address: two peers reachable at the same address (different
# ports, a shared jump host, a reused tailnet name) would otherwise pool their
# host keys, and either one's key would satisfy verification for the other.
# The fleet id is the only stable per-peer name we have, so it is the alias.
# A fleet id is a key fingerprint ("SHA256:AbC+/…"): ':', '+' and '/' are not
# usable in a known_hosts hostname field, so the id is hashed to hex first.
# The hash is of the whole id, so distinct peers keep distinct aliases.
fleet_alias() {  # fleet_alias <peerdir>
  fad=${1:-}
  fap=$([ -n "$fad" ] && fleet_meta "$fad" peer 2>/dev/null || true)
  if [ -z "${fap:-}" ]; then printf 'n2-bootstrap\n'; return 0; fi
  printf 'n2-peer-%s\n' "$(printf '%s' "$fap" | shasum -a 256 | cut -c1-16)"
}

fleet_pin_host() {  # fleet_pin_host <peerdir> [unused-address] ; line on stdin
  fphd=$1 fpha=$(fleet_alias "$1")
  fleet_host_line > "$fphd/host.pub.$$"
  if [ -s "$fphd/host.pub.$$" ]; then
    printf '%s %s\n' "$fpha" "$(awk '{print $2" "$3}' "$fphd/host.pub.$$")" > "$fphd/host.pub"
    rm -f "$fphd/host.pub.$$"; return 0
  fi
  rm -f "$fphd/host.pub.$$"; return 1
}

# Fleet-private known_hosts, pinned at enrollment. Host verification stays on;
# we just do not consult the user's personal known_hosts for fleet traffic.
fleet_known_hosts() {
  khout=$fleet_root/known_hosts
  khtmp=$khout.$$
  : > "$khtmp"
  for khd in "$fleet_root/peers"/*; do
    [ -d "$khd" ] || continue
    khpid=$(fleet_meta "$khd" peer 2>/dev/null) || continue
    fleet_revoked "$khpid" && continue
    [ -f "$khd/host.pub" ] && fleet_host_line < "$khd/host.pub" >> "$khtmp"
  done
  # The first hop of an enrollment has no peer record yet, so the operator's
  # out-of-band host key (`join/pair --host-key`) is pinned here for exactly
  # that hop. Without it ssh has nothing to verify against and fails closed.
  if [ -f "$fleet_root/bootstrap/host.pub" ]; then
    # Filed under the bootstrap alias only. The bootstrap directory is wiped at
    # the start of every enrollment, so this pin authorizes exactly the hop the
    # operator handed a host key for, and never a later peer.
    fleet_host_line < "$fleet_root/bootstrap/host.pub" |
      awk '{print "n2-bootstrap", $2, $3}' >> "$khtmp"
  fi
  mv "$khtmp" "$khout"
  chmod 600 "$khout" 2>/dev/null || true
  echo "$khout"
}

fleet_event() {  # fleet_event <kind> <detail…>   — never carries secret values
  mkdir -p "$fleet_root"
  printf '%s\t%s\t%s\n' "$(fleet_now)" "$1" "$(shift; printf '%s' "$*")" \
    >> "$fleet_root/events.log" 2>/dev/null || true
}

# --- envelope --------------------------------------------------------------
# Signed bytes are header lines + base64 payload; the armored signature follows
# a --sig-- line. Base64 keeps the whole message line-oriented so `sh` can
# split it without corrupting binary payloads.

fleet_envelope() {  # fleet_envelope <to> <verb> <payload-file> ; writes message to stdout
  to=$1 verb=$2 pf=${3:-/dev/null}
  case $verb in ''|*[!a-z-]*) echo "ERR malformed-verb" >&2; return 1 ;; esac
  case $to in ''|*[!A-Za-z0-9:+/=_.-]*) echo "ERR malformed-recipient" >&2; return 1 ;; esac
  from=$(fleet_self_id) || fleet_die "no fleet identity (run: agents fleet init)"
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/n2fleet.XXXXXX") || fleet_die "mktemp failed"
  b64=$tmpd/b64
  base64 < "$pf" > "$b64"
  {
    echo "$FLEET_PROTO"
    echo "from=$from"
    echo "to=$to"
    echo "verb=$verb"
    echo "nonce=$(fleet_nonce)"
    echo "ts=$(fleet_now)"
    echo "len=$(wc -c < "$pf" | tr -d ' ')"
    echo "--"
    cat "$b64"
  } > "$tmpd/signed"
  ssh-keygen -Y sign -q -f "$(fleet_key)" -n "$FLEET_NS" "$tmpd/signed" >/dev/null 2>&1 ||
    { rm -rf "$tmpd"; fleet_die "could not sign fleet request"; }
  cat "$tmpd/signed"
  echo "--sig--"
  cat "$tmpd/signed.sig"
  rm -rf "$tmpd"
}

fleet_nonce() {
  od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || date +%s%N
}

# Split a received message into <dir>/signed and <dir>/sig. Fails on a message
# with no signature section — an unsigned request is never partially parsed.
fleet_split() {  # fleet_split <msg-file> <dir>
  awk -v d="$2" '
    /^--sig--$/ && !seen { seen=1; next }
    { print > (seen ? d "/sig" : d "/signed") }
    END { exit seen ? 0 : 1 }
  ' "$1"
}

fleet_header() { awk -F= -v k="$2" '/^--$/{exit} $1==k {sub(/^[^=]*=/,""); print}' "$1"; }

fleet_payload() {  # decoded payload of a signed-part file, to stdout
  awk 'f{print} /^--$/{f=1}' "$1" | base64 -d 2>/dev/null
}

# Decode the payload *and* hold it to the framing the sender signed.
#
# `base64 -d` on a truncated or non-base64 body exits non-zero and writes
# whatever it managed to decode; piping it straight to a file threw both away,
# so a message could declare `len=999999`, carry nothing, and still reach a
# handler with an empty payload that every later check read as legitimate.
# The declared length is signed, so disagreeing with it means the body is not
# the body that was signed -- refuse rather than guess which half is true.
fleet_decode_payload() {  # fleet_decode_payload <signed-file> <out-file> <declared-len>
  case $3 in ''|*[!0-9]*) return 1 ;; esac
  [ "${#3}" -le 18 ] || return 1
  awk 'f{print} /^--$/{f=1}' "$1" > "$2.b64" || return 1
  # Reject anything outside the base64 alphabet before decoding: some `base64`
  # implementations silently skip stray characters instead of failing.
  LC_ALL=C tr -d 'A-Za-z0-9+/=\n' < "$2.b64" | LC_ALL=C tr -d '\n' | grep -q . && return 1
  base64 -d < "$2.b64" > "$2" 2>/dev/null || return 1
  [ "$(wc -c < "$2" | tr -d ' ')" = "$3" ] || return 1
  return 0
}

# --- verification ----------------------------------------------------------
# Order matters and is asserted by tests: shape → signature → roster → state →
# addressing → freshness → replay. Nothing in the payload is interpreted until
# every one of them has passed.

fleet_verify_sig() {  # fleet_verify_sig <signed> <sig> <principal> <allowed_signers>
  ssh-keygen -Y verify -f "$4" -I "$3" -n "$FLEET_NS" -s "$2" < "$1" >/dev/null 2>&1
}

# Reservation, not a check followed by a write: test-then-create loses the
# race when the same envelope is replayed into several receivers at once (they
# all read "absent", they all accept). mkdir of the nonce entry itself is the
# reservation -- the directory create is atomic, so exactly one concurrent
# caller can win it and every other one is told the nonce is spent.
fleet_seen_nonce() {  # true if this nonce was already used
  case $1 in ''|*[!0-9a-f]*) return 0 ;; esac
  mkdir -p "$fleet_root/seen" 2>/dev/null || return 0
  mkdir "$fleet_root/seen/$1" 2>/dev/null || return 0
  return 1
}

# Verify a received message. Echoes the verified sender id on success, or
# "ERR <reason>" plus non-zero on failure. <dir> keeps signed/sig/payload.
fleet_verify() {  # fleet_verify <msg-file> <dir>
  fvd=$2
  mkdir -p "$fvd"
  fleet_split "$1" "$fvd" || { echo "ERR unsigned"; return 1; }
  [ -s "$fvd/signed" ] || { echo "ERR malformed"; return 1; }
  head -1 "$fvd/signed" | grep -qx "$FLEET_PROTO" || { echo "ERR proto"; return 1; }
  from=$(fleet_header "$fvd/signed" from)
  to=$(fleet_header "$fvd/signed" to)
  verb=$(fleet_header "$fvd/signed" verb)
  nonce=$(fleet_header "$fvd/signed" nonce)
  ts=$(fleet_header "$fvd/signed" ts)
  dlen=$(fleet_header "$fvd/signed" len)
  case $from in SHA256:*) ;; *) echo "ERR malformed"; return 1 ;; esac
  case $verb in ''|*[!a-z-]*) echo "ERR malformed"; return 1 ;; esac
  case $to in ''|*[!A-Za-z0-9:+/=_.-]*) echo "ERR malformed"; return 1 ;; esac
  case $nonce in ''|*[!0-9a-f]*) echo "ERR malformed"; return 1 ;; esac
  case $dlen in ''|*[!0-9]*) echo "ERR malformed"; return 1 ;; esac

  if [ "$verb" = enroll ] || [ "$verb" = enrolled ]; then
    # The sender is by definition not in the roster yet. Its key travels in the
    # payload; we accept the signature only if that key's fingerprint is the
    # claimed `from`, which proves possession without granting any authority.
    fleet_decode_payload "$fvd/signed" "$fvd/payload" "$dlen" ||
      { echo "ERR bad-framing"; return 1; }
    sed -n 's/^key=//p' "$fvd/payload" | head -1 > "$fvd/claim.pub"
    [ -s "$fvd/claim.pub" ] || { echo "ERR malformed"; return 1; }
    [ "$(fleet_fp "$fvd/claim.pub")" = "$from" ] || { echo "ERR wrong-identity"; return 1; }
    printf '%s %s\n' "$from" "$(awk '{print $1" "$2}' "$fvd/claim.pub")" > "$fvd/as"
    chmod 600 "$fvd/as"
    fleet_verify_sig "$fvd/signed" "$fvd/sig" "$from" "$fvd/as" || { echo "ERR bad-signature"; return 1; }
    fleet_revoked "$from" && { echo "ERR revoked"; return 1; }
  else
    # Refusing a claimed identity is not the same as trusting it: these two
    # checks only decide which refusal to name. Nothing is acted on until the
    # signature verifies against the key bound to that very fingerprint.
    fleet_revoked "$from" && { echo "ERR revoked"; return 1; }
    state=$(fleet_peer_state "$from")
    [ "$state" = unknown ] && { echo "ERR unknown-peer"; return 1; }
    as=$(fleet_candidate_signers)
    fleet_verify_sig "$fvd/signed" "$fvd/sig" "$from" "$as" || { echo "ERR bad-signature"; return 1; }
    [ "$state" = approved ] || { echo "ERR not-approved"; return 1; }
    fleet_decode_payload "$fvd/signed" "$fvd/payload" "$dlen" ||
      { echo "ERR bad-framing"; return 1; }
  fi

  me=$(fleet_self_id) || { echo "ERR no-identity"; return 1; }
  [ "$to" = any ] || [ "$to" = "$me" ] || { echo "ERR misaddressed"; return 1; }
  now=$(fleet_now)
  case $ts in ''|*[!0-9]*) echo "ERR malformed"; return 1 ;; esac
  skew=$(( now - ts )); [ "$skew" -lt 0 ] && skew=$(( -skew ))
  [ "$skew" -le "$FLEET_SKEW" ] || { echo "ERR stale"; return 1; }
  fleet_seen_nonce "$nonce" && { echo "ERR replay"; return 1; }
  echo "$from"
}

# --- serve -----------------------------------------------------------------

fleet_ok() { echo OK; base64 < "${1:-/dev/null}"; }

fleet_serve() {
  set +e   # see fleet_errexit_note
  fleet_have_identity || { echo "ERR no-identity"; return 1; }
  fsd=$(mktemp -d "${TMPDIR:-/tmp}/n2serve.XXXXXX") || return 1
  cat > "$fsd/msg"
  fsfrom=$(fleet_verify "$fsd/msg" "$fsd")
  case $fsfrom in
    ERR*) fleet_event reject "$fsfrom"; echo "$fsfrom"; rm -rf "$fsd"; return 1 ;;
  esac
  fsverb=$(fleet_header "$fsd/signed" verb)
  fleet_event request "verb=$fsverb from=$fsfrom"
  if command -v "fleet_handle_$(printf '%s' "$fsverb" | tr - _)" >/dev/null 2>&1 ||
     type "fleet_handle_$(printf '%s' "$fsverb" | tr - _)" >/dev/null 2>&1; then
    "fleet_handle_$(printf '%s' "$fsverb" | tr - _)" "$fsfrom" "$fsd/payload" "$fsd"
    fsrc=$?
  else
    echo "ERR unknown-verb"; fsrc=1
  fi
  rm -rf "$fsd"
  return $fsrc
}

# Token replies bypass fleet_ok and its reply files. Only the verified sender
# enters this helper; local/exec serve routes are not confidential carriers.
fleet_handle_auth_token() {
  [ -n "${SSH_CONNECTION:-}" ] || { echo "ERR encrypted-carrier-required" >&2; return 1; }
  python3 "$scripts_dir/fleet-auth-server.py" "$root" "$1" "$2"
}

fleet_handle_auth_login() {
  [ -n "${SSH_CONNECTION:-}" ] || { echo "ERR encrypted-carrier-required" >&2; return 1; }
  python3 "$scripts_dir/fleet-auth-login.py" serve "$root" "$1" "$2"
}

fleet_handle_ping() { printf 'pong %s %s\n' "$(fleet_self_machine)" "$(fleet_self_id)" > "$3/out"; fleet_ok "$3/out"; }

fleet_handle_status() {
  { printf 'machine=%s\npeer=%s\nts=%s\npeers=%s\n' \
      "$(fleet_self_machine)" "$(fleet_self_id)" "$(fleet_now)" "$(fleet_peer_ids | wc -l | tr -d ' ')"
  } > "$3/out"
  fleet_ok "$3/out"
}

fleet_handle_roster() {
  : > "$3/out"
  for dd in "$fleet_root/peers"/*; do
    [ -d "$dd" ] || continue
    rpid=$(fleet_meta "$dd" peer)
    # The public key travels so a discovering peer can build a pending record
    # it could actually approve later. It is public material; `fleet_approve`
    # still refuses it unless its fingerprint equals the advertised peer id.
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rpid" "$(fleet_meta "$dd" machine)" \
      "$(fleet_meta "$dd" transport)" "$(fleet_peer_state "$rpid")" \
      "$(fleet_meta "$dd" address)" \
      "$([ -f "$dd/key.pub" ] && awk '{print $1"_"$2}' "$dd/key.pub")" >> "$3/out"
  done
  fleet_ok "$3/out"
}

# Revocation propagation. The sender is already proven approved by
# fleet_verify, so this is a peer we have chosen to trust telling us it has
# cut someone off. We never let it revoke us, and we never re-broadcast (one
# hop per `revoke --propagate`, so a cycle of peers cannot loop forever).
fleet_handle_revoke() {
  rvfrom=$1
  rvtarget=$(fleet_meta_get_file "$2" peer)
  case $rvtarget in SHA256:*) ;; *) echo "ERR malformed"; return 1 ;; esac
  [ "$rvtarget" = "$(fleet_self_id)" ] && { echo "ERR refuse-self-revoke"; return 1; }
  [ "$rvtarget" = "$rvfrom" ] && { echo "ERR refuse-self-revoke"; return 1; }
  # Same honesty rule as the local CLI: the roster entry is gone either way,
  # but if the inbound ssh grant survived, the sender must not be told the
  # door is shut. Fail the reply so `revoke --propagate` prints `fail` for
  # this hop and the operator knows which machine still needs a hand.
  if fleet_revoke "$rvtarget"; then
    printf 'revoked %s\n' "$rvtarget" > "$3/out"
    fleet_ok "$3/out"
  else
    echo "ERR revoked-grant-not-removed $rvtarget on $(fleet_self_machine)"
    return 1
  fi
}

# Revocation reconciliation. `revoke --propagate` is one hop and only reaches
# peers that are online at that moment; a machine that was offline would keep
# an approved record of a peer the fleet has cut off. So a peer can also *ask*
# for a neighbour's revocation list when it comes back (see fleet_reconcile).
fleet_handle_revocations() {
  [ -f "$fleet_root/revoked" ] && awk '{print $1}' "$fleet_root/revoked" > "$3/out" || : > "$3/out"
  fleet_ok "$3/out"
}

# Host key rotation. A peer that reinstalls its OS (or regenerates
# /etc/ssh/ssh_host_*) keeps its fleet identity key but breaks every pin its
# peers hold, and it cannot be dialled to fix it. It can still dial out, so it
# announces the new key over a message signed by the identity key we already
# trust. Authentication rides the fleet signature, never the ssh host key, so
# accepting this is not trust-on-first-use: an attacker without the identity
# key cannot move the pin.
fleet_handle_rehost() {
  rhfrom=$1
  fleet_approved "$rhfrom" || { echo "ERR not-approved"; return 1; }
  rhd=$(fleet_peer_dir "$rhfrom"); [ -d "$rhd" ] || { echo "ERR unknown-peer"; return 1; }
  rhold=$(fleet_host_fp "$rhd/host.pub")
  if sed -n 's/^host=//p' "$2" | head -1 | fleet_pin_host "$rhd" "$(fleet_meta "$rhd" address)"; then
    fleet_meta_set "$rhd" host_fp "$(fleet_host_fp "$rhd/host.pub")"
    fleet_meta_set "$rhd" rehosted_at "$(fleet_now)"
    fleet_known_hosts >/dev/null
    fleet_event rehost "peer=$rhfrom old=${rhold:-none} new=$(fleet_host_fp "$rhd/host.pub")"
    printf 'rehosted %s\n' "$(fleet_host_fp "$rhd/host.pub")" > "$3/out"
    fleet_ok "$3/out"
  else
    echo "ERR bad-host-key"; return 1
  fi
}

# enroll: record the request. An unbound pairing code (or none) leaves it in
# `pending`; a code minted for this exact peer id auto-approves it.
fleet_handle_enroll() {
  # Uses hed/hepd for its own paths: fleet_approve rewrites the globals `d`
  # and `pid`, and fleet_serve removes "$fsd" afterwards, so a handler that
  # kept its scratch dir in `d` would have its reply — and the peer record —
  # deleted underneath it.
  hefrom=$1 hepf=$2 hed=$3
  machine=$(sed -n 's/^machine=//p' "$hepf" | head -1)
  transport=$(sed -n 's/^transport=//p' "$hepf" | head -1)
  address=$(sed -n 's/^address=//p' "$hepf" | head -1)
  euser=$(sed -n 's/^user=//p' "$hepf" | head -1)
  eport=$(sed -n 's/^port=//p' "$hepf" | head -1)
  ehome=$(sed -n 's/^home=//p' "$hepf" | head -1)
  etag=$(sed -n 's/^tag=//p' "$hepf" | head -1)
  ecodeid=$(sed -n 's/^codeid=//p' "$hepf" | head -1)
  sed -n 's/^host=//p' "$hepf" | fleet_host_line > "$hed/host.pub"

  if [ "$(fleet_peer_state "$hefrom")" = approved ]; then
    # Re-enrollment is the operator's recovery path when an approval callback
    # was lost (approver offline at `approve` time, joiner rebooted mid-flight).
    # A bare "already approved" is useless to the caller: fleet_record_reply
    # needs `peer=`/`key=` to identify who answered, so the rejoin failed with
    # no diagnosis and left the joiner with no way back. Answer with the same
    # identity block as a fresh request so the rejoin is idempotent -- it
    # re-pins our host key and re-arms the `joined/` marker, which is what lets
    # a *second* `approve` callback be accepted. It carries no `rtag`, so the
    # joiner holds us pending rather than believing the claim (see
    # fleet_record_reply); only the callback itself approves.
    { printf 'result=already-approved\n'
      printf 'peer=%s\n' "$(fleet_self_id)"
      printf 'machine=%s\n' "$(fleet_self_machine)"
      printf 'key=%s\n' "$(awk '{print $1" "$2}' "$(fleet_key).pub")"
      hhost=$(fleet_host_pub); if [ -n "$hhost" ]; then printf 'host=%s\n' "$hhost"; fi
    } > "$hed/out"
    fleet_event enroll "peer=$hefrom result=already-approved"
    fleet_ok "$hed/out"; return 0
  fi

  hepd=$(fleet_pending_dir "$hefrom")

  # Validation runs *before* any pending record exists. A rejected requester
  # supplies its own key, host key, address, user, port and home; persisting
  # those first left attacker-chosen roster fields on disk after an explicit
  # rejection, so nothing is written until the code has passed.
  eresult=pending ertag= epaired= eapprove=
  if [ -n "$ecodeid" ]; then
    if ! fleet_valid_codeid "$ecodeid"; then
      # A code id is an index into $fleet_root/invites; anything but the 16 hex
      # characters `fleet_invite` mints could escape that directory (../…) and
      # reach — or, on the expiry branch, delete — an unrelated file.
      fleet_event reject "enroll malformed-code"
      echo "ERR malformed-code"; return 1
    fi
    einv=$fleet_root/invites/$ecodeid
    ebound=$(fleet_meta_get_file "$einv" peer)
    esecret=$(fleet_meta_get_file "$einv" secret)
    if [ ! -f "$einv" ]; then
      eresult="pending unknown-code"
    elif [ "$(fleet_now)" -gt "$(fleet_meta_get_file "$einv" expires)" ]; then
      rm -f "$einv"; eresult="pending expired-code"
    elif [ -n "$ebound" ] && [ "$ebound" != "$hefrom" ]; then
      fleet_event reject "enroll wrong-identity code=$ecodeid"
      echo "ERR wrong-identity"; return 1
    elif [ "$etag" != "$(fleet_tag "$(fleet_meta_get_file "$einv" secret)" "$hefrom" "$(cat "$hed/host.pub" 2>/dev/null)")" ]; then
      fleet_event reject "enroll bad-pairing-tag"
      echo "ERR bad-pairing-tag"; return 1
    elif [ -n "$ebound" ]; then
      # Bound invite: the operator named this exact fingerprint when minting
      # the code, so possession of the secret completes an approval they have
      # already given. Unbound codes do not — see below.
      rm -f "$einv"                       # one-time use
      ertag=$(fleet_tag "$esecret" "$(fleet_self_id)" "$(fleet_host_pub)")
      eapprove=yes
    else
      # Unbound invite: the tag proves the joiner holds the secret, but the
      # operator never said which key may use it. Bind it to the key that
      # actually presented it and hold the peer for explicit approval, which
      # is what `fleet invite` tells the operator will happen.
      rm -f "$einv"                       # one-time use
      ertag=$(fleet_tag "$esecret" "$(fleet_self_id)" "$(fleet_host_pub)")
      epaired=yes
      eresult="pending paired"
    fi
  fi
  mkdir -p "$hepd"
  cp "$hed/claim.pub" "$hepd/key.pub"
  [ -s "$hed/host.pub" ] && cp "$hed/host.pub" "$hepd/host.pub"
  fleet_meta_set "$hepd" peer "$hefrom"
  fleet_meta_set "$hepd" machine "${machine:-unknown}"
  fleet_meta_set "$hepd" transport "${transport:-ssh}"
  fleet_meta_set "$hepd" address "${address:-}"
  fleet_meta_set "$hepd" user "${euser:-}"
  # Peer-supplied, so it goes through the same validator as address/user
  # before it can ever reach an ssh command line; junk is dropped, not dialled.
  if [ -n "$eport" ] && fleet_valid_port "$eport"; then fleet_meta_set "$hepd" port "$eport"; fi
  [ -n "$ehome" ] && fleet_meta_set "$hepd" home "$ehome"
  fleet_meta_set "$hepd" state pending
  fleet_meta_set "$hepd" requested_at "$(fleet_now)"

  if [ -n "$epaired" ]; then fleet_meta_set "$hepd" paired yes; fi
  if [ -n "$eapprove" ]; then
    if fleet_approve "$hefrom" "$(fleet_self_id)"; then eresult=approved; fi
  fi
  fleet_event enroll "peer=$hefrom machine=${machine:-unknown} result=$eresult"
  { printf 'result=%s\n' "$eresult"
    printf 'peer=%s\n' "$(fleet_self_id)"
    printf 'machine=%s\n' "$(fleet_self_machine)"
    printf 'key=%s\n' "$(awk '{print $1" "$2}' "$(fleet_key).pub")"
    ehost=$(fleet_host_pub); if [ -n "$ehost" ]; then printf 'host=%s\n' "$ehost"; fi
    # Proof the responder holds the pairing secret, bound to its own fleet id
    # and host key. The joiner refuses an unproven `result=approved` (set -eu
    # is on, so these are `if`s: a false `&&` test would abort the group).
    if [ -n "$ertag" ]; then printf 'rtag=%s\n' "$ertag"; fi
  } > "$hed/out"
  fleet_ok "$hed/out"
}

# Invite code ids are the first 16 hex chars of a sha256 and nothing else.
fleet_valid_codeid() {
  case $1 in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ ${#1} -eq 16 ]
}

fleet_meta_get_file() { [ -f "$1" ] || return 0; awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/,""); print}' "$1"; }

fleet_tag() { printf '%s' "$1|$2|$3" | shasum -a 256 2>/dev/null | awk '{print $1}'; }

# --- carriers --------------------------------------------------------------
# Each carrier only changes how bytes reach the peer's `agents fleet serve`.
# Verification is identical on the far side, so an `exec` test peer can never
# pass a check a tailscale or ssh peer would fail.

fleet_agents_cmd() { echo "${N2_FLEET_AGENTS:-${self:-agents}}"; }

# Peer-supplied routing fields (`address`, `user`, `port`) end up in ssh's
# argv. A value that begins with `-` would be read as an option and a value
# with whitespace would split into several, so both are rejected here rather
# than quoted and hoped for; `--` before the destination is belt to that brace.
fleet_valid_addr() {
  case ${1:-} in ''|-*) return 1 ;; *[!A-Za-z0-9._:%-]*) return 1 ;; esac
}
fleet_valid_user() {
  case ${1:-} in -*) return 1 ;; *[!A-Za-z0-9._-]*) return 1 ;; esac
}
fleet_valid_port() {
  case ${1:-} in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ]
}

# fleet_ssh_run <print|run> <alias> <port> <bootstrap> [dest] [remote-cmd]
#
# <bootstrap> may be `1` (use the operator's default ssh identities) or a path
# to one specific key: OpenSSH expands `~` from the passwd entry rather than
# $HOME, so an operator whose bootstrap credential is not a default identity
# -- or any isolated test -- needs to name it. Naming it also narrows the hop
# to that single key instead of offering every agent identity.
#
# Host verification is never disabled. The optional alias is the address the
# pin was keyed to (see fleet_pin_host): forcing HostKeyAlias makes ssh consult
# *that* entry, so a peer reached on a non-default port or through a different
# name still verifies against the key we actually pinned, instead of silently
# finding no entry and failing open the next time StrictHostKeyChecking moves.
#
# UserKnownHostsFile alone does not make the fleet pin exclusive: ssh also
# consults GlobalKnownHostsFile, which defaults to /etc/ssh/ssh_known_hosts
# and ssh_known_hosts2. A host key trusted there would satisfy verification
# even when it disagrees with what the fleet pinned at enrollment, so a
# machine-wide entry -- one the fleet never approved -- could stand in for the
# peer. Pointing it at /dev/null leaves the fleet's own file as the only
# source of host trust. This is the opposite of disabling verification: it
# removes a trust source rather than adding one.
#
# Two more inherited settings would hollow out that exclusivity, so they are
# forced here rather than left to whatever ~/.ssh/config says:
#
#   KnownHostsCommand -- a third source of host keys, consulted in addition to
#   the files above. An operator config that sets it could answer for a peer
#   with a key the fleet never pinned.
#
#   ControlMaster/ControlPath/ControlPersist -- a multiplexed session skips
#   host verification entirely and rides an existing socket. If that socket
#   was opened by a process with different host-key trust, the pin is never
#   consulted at all. `none` forces this hop to make its own connection.
#
# These are command-line -o values, so they take precedence over the user's
# config while leaving legitimate operator settings (Hostname, ProxyJump, the
# bootstrap relationship) intact -- the file is not discarded wholesale.
#
# <bootstrap> is set only for the single enrollment hop. Before approval the
# far side has never seen our fleet key, so pinning `IdentitiesOnly` to it
# would deadlock: the key that enrollment installs is the key enrollment would
# need. On that hop we let ssh use the operator's *existing* access to the
# machine -- which is the out-of-band relationship that justifies enrolling it
# at all -- while host verification, BatchMode and the pinned known_hosts file
# stay exactly as they are for every later hop.
#
# `print` renders the option list without dialing, so tests and audits can
# read the exact flags off the same code path that runs them.
fleet_ssh_run() {
  fsrm=$1 fsra=${2:-} fsrp=${3:-} fsrb=${4:-} fsrd=${5:-} fsrc=${6:-}
  set -- -o StrictHostKeyChecking=yes \
         -o "UserKnownHostsFile=$(fleet_known_hosts)" \
         -o GlobalKnownHostsFile=/dev/null \
         -o KnownHostsCommand=none \
         -o ControlMaster=no \
         -o ControlPath=none \
         -o ControlPersist=no \
         -o BatchMode=yes \
         -o "ConnectTimeout=${N2_FLEET_TIMEOUT:-8}"
  case $fsrb in
    '') set -- "$@" -o IdentitiesOnly=yes -i "$(fleet_key)" ;;
    1)  ;;
    *)  set -- "$@" -o IdentitiesOnly=yes -i "$fsrb" ;;
  esac
  if [ -n "$fsra" ]; then set -- "$@" -o "HostKeyAlias=$fsra"; fi
  if [ -n "$fsrp" ]; then set -- "$@" -p "$fsrp"; fi
  if [ "$fsrm" = print ]; then
    fsrout=; for fsra1 in "$@"; do fsrout="$fsrout$fsra1 "; done
    printf '%s\n' "$fsrout"; return 0
  fi
  ssh "$@" -- "$fsrd" "$fsrc"
}

# Kept for diagnostics/tests: the option string, from the same builder.
fleet_ssh_opts() { fleet_ssh_run print "${1:-}" "${2:-}" "${3:-}"; }

# Carrier stderr is discarded so a chatty ssh/tailscale banner cannot be
# mistaken for a reply; N2_FLEET_DEBUG=1 lets it through for diagnosis.
fleet_carry_err() { [ -n "${N2_FLEET_DEBUG:-}" ] && echo /dev/stderr || echo /dev/null; }

fleet_carry() {  # fleet_carry <peerdir> ; message on stdin, reply on stdout
  d=$1
  t=$(fleet_meta "$d" transport 2>/dev/null || echo ssh)
  addr=$(fleet_meta "$d" address 2>/dev/null || true)
  user=$(fleet_meta "$d" user 2>/dev/null || true)
  cmd=$(fleet_meta "$d" command 2>/dev/null || echo "${N2_FLEET_REMOTE_CMD:-agents}")
  case $t in
    exec)
      [ "${N2_FLEET_AUTH_CARRIER:-}" != 1 ] || return 1
      home=$(fleet_meta "$d" home) || return 1
      env SSH_CONNECTION= SSH_CLIENT= SSH_TTY= HOME="$home" N2_FLEET_AGENTS="$(fleet_agents_cmd)" \
        "$(fleet_agents_cmd)" fleet serve 2>"$(fleet_carry_err)"
      ;;
    tailscale|ssh)
      port=$(fleet_meta "$d" port 2>/dev/null || true)
      boot=$(fleet_meta "$d" bootstrap 2>/dev/null || true)
      if [ "${N2_FLEET_AUTH_CARRIER:-}" = 1 ]; then
        [ -z "$boot" ] || return 1
      fi
      fleet_valid_addr "$addr" || { echo "ERR bad-address" >&2; return 1; }
      fleet_valid_user "$user" || { echo "ERR bad-user" >&2; return 1; }
      [ -z "$port" ] || fleet_valid_port "$port" || { echo "ERR bad-port" >&2; return 1; }
      # `command` is local operator config (it may legitimately be a shell
      # fragment such as `env HOME=... agents`), so it is passed as ssh's
      # single remote-command word rather than character-restricted; only an
      # empty or newline-bearing value is rejected.
      [ -n "$cmd" ] && [ "$(printf '%s' "$cmd" | wc -l | tr -d ' ')" = 0 ] ||
        { echo "ERR bad-command" >&2; return 1; }
      dest=$addr; [ -n "$user" ] && dest=$user@$addr
      fleet_ssh_run run "$(fleet_alias "$d")" "$port" "$boot" "$dest" "$cmd fleet serve" 2>"$(fleet_carry_err)"
      ;;
    *) return 1 ;;
  esac
}

# --- client ----------------------------------------------------------------

fleet_call() {  # fleet_call <peerid> <verb> [payload-file] -> payload on stdout
  pid=$1 verb=$2 pf=${3:-/dev/null}
  case $verb in ''|*[!a-z-]*) echo "ERR malformed-verb" >&2; return 1 ;; esac
  case $verb in auth-token|auth-login) echo "ERR private-carrier-required" >&2; return 1 ;; esac
  d=$(fleet_peer_dir "$pid")
  [ -d "$d" ] || { echo "ERR unknown-peer" >&2; return 1; }
  fleet_approved "$pid" || { echo "ERR not-approved" >&2; return 1; }
  ctmp=$(mktemp -d "${TMPDIR:-/tmp}/n2call.XXXXXX") || return 1
  fleet_envelope "$pid" "$verb" "$pf" > "$ctmp/req" || { rm -rf "$ctmp"; return 1; }
  fleet_carry "$d" < "$ctmp/req" > "$ctmp/rep"
  rc=$?
  if [ $rc -ne 0 ] && [ ! -s "$ctmp/rep" ]; then
    fleet_event unreachable "peer=$pid verb=$verb"
    echo "ERR unreachable" >&2; rm -rf "$ctmp"; return 2
  fi
  case $(head -1 "$ctmp/rep" 2>/dev/null) in
    OK)
      # Decode before emitting: a pipeline's status is base64's, and it was
      # being discarded, so a corrupt reply body left the caller with partial
      # bytes and exit 0 -- indistinguishable from a real answer.
      if tail -n +2 "$ctmp/rep" | base64 -d > "$ctmp/out" 2>/dev/null; then
        cat "$ctmp/out"; rm -rf "$ctmp"; return 0
      fi
      echo "ERR malformed-reply" >&2; rm -rf "$ctmp"; return 1 ;;
    ERR*) head -1 "$ctmp/rep" >&2; rm -rf "$ctmp"; return 1 ;;
    *) echo "ERR malformed-reply" >&2; rm -rf "$ctmp"; return 1 ;;
  esac
}

# Private owner-response path. Only public requests use temporary files. Replies
# stay on stdout through the pinned encrypted carrier and are consumed in memory
# by fleet-auth-transport.py, which verifies their owner signature and context.
fleet_auth_call() (
  set +e
  [ "$#" = 2 ] || [ "$#" = 3 ] || return 1
  ac_peer=$1 ac_payload=$2 ac_protocol=${3:-token}
  case $ac_protocol in token) ac_verb=auth-token ;; login) ac_verb=auth-login ;; *) return 1 ;; esac
  /usr/bin/python3 "$scripts_dir/fleet-auth-transport.py" validate-request "$root" "$ac_peer" "$ac_payload" "$ac_protocol" 2>/dev/null || return 1
  ac_dir=$(fleet_peer_dir "$ac_peer")
  fleet_approved "$ac_peer" || return 1
  [ "$(fleet_fp "$ac_dir/key.pub")" = "$ac_peer" ] || return 1
  case $(fleet_meta "$ac_dir" transport) in ssh|tailscale) ;; *) return 1 ;; esac
  [ -z "$(fleet_meta "$ac_dir" bootstrap 2>/dev/null)" ] || return 1
  ac_tmp=$(mktemp -d "${TMPDIR:-/tmp}/n2auth-call.XXXXXX") || return 1
  trap 'rm -rf "$ac_tmp"' EXIT
  fleet_envelope "$ac_peer" "$ac_verb" "$ac_payload" > "$ac_tmp/request" || return 1
  N2_FLEET_AUTH_CARRIER=1 N2_FLEET_DEBUG= fleet_carry "$ac_dir" < "$ac_tmp/request"
  ac_rc=$?
  [ "$ac_rc" = 0 ] || return 1
  fleet_approved "$ac_peer" || return 1
  [ "$(fleet_fp "$ac_dir/key.pub")" = "$ac_peer" ] || return 1
)

# Best effort fan-out. An offline peer is a status, not a failure: the
# disconnect path in `execution` depends on this never aborting the caller.
fleet_broadcast() {  # fleet_broadcast <verb> [payload-file]
  verb=$1 pf=${2:-/dev/null}
  fleet_peer_ids | while read -r pid; do
    [ -n "$pid" ] || continue
    fleet_approved "$pid" || { printf '%s\tskipped\t%s\n' "$pid" "$(fleet_peer_state "$pid")"; continue; }
    out=$(fleet_call "$pid" "$verb" "$pf" 2>&1) &&
      printf '%s\tok\t%s\n' "$pid" "$(printf '%s' "$out" | tr '\n' ' ')" ||
      printf '%s\tfail\t%s\n' "$pid" "$(printf '%s' "$out" | tr '\n' ' ')"
  done
  return 0
}

fleet_reach() {  # one-word reachability for `peers`/`status`
  fleet_approved "$1" || { fleet_peer_state "$1"; return 0; }
  if fleet_call "$1" ping >/dev/null 2>&1; then echo online; else echo offline; fi
}

# --- roster mutation -------------------------------------------------------

# fleet_approve <peerid> <approver> [expected-host-fp] [nohost]
# Approval is where a self-asserted host key becomes trusted. Over Tailscale
# there is no pairing code binding it, so approval fails closed: a peer whose
# traffic will ride ssh must arrive with a host key, and if the operator
# supplies a fingerprint out of band it must match. `nohost` is the explicit,
# recorded escape hatch, not the default.
fleet_approve() {
  fapid=$1 fahfp=${3:-} fanohost=${4:-}
  fleet_revoked "$fapid" && { echo "agents: peer is revoked" >&2; return 1; }
  fapd=$(fleet_pending_dir "$fapid"); fad=$(fleet_peer_dir "$fapid")
  # Validate the request *where it still lives*. Moving pending -> peers first
  # meant a rejected approval (missing or mismatched host key) destroyed the
  # request: the operator could no longer `deny` it, nor retry with the
  # fingerprint they went and verified.
  if [ -d "$fapd" ]; then fasrc=$fapd; else fasrc=$fad; fi
  [ -d "$fasrc" ] || { echo "agents: no such enrollment request: $fapid" >&2; return 1; }
  [ -f "$fasrc/key.pub" ] && [ "$(fleet_fp "$fasrc/key.pub")" = "$fapid" ] ||
    { echo "agents: key does not match peer id" >&2; return 1; }
  fatrans=$(fleet_meta "$fasrc" transport 2>/dev/null || echo ssh)
  fahave=$(fleet_host_fp "$fasrc/host.pub")
  case $fatrans in
    ssh|tailscale)
      if [ -z "$fahave" ] && [ "$fanohost" != nohost ]; then
        echo "agents: no ssh host key recorded for $fapid — verify it out of band and re-run with --host-fp <fp>, or --no-host-key to accept an unpinned host" >&2
        fleet_event reject "approve missing-host-key peer=$fapid"; return 1
      fi ;;
  esac
  if [ -n "$fahfp" ] && [ "$fahfp" != "$fahave" ]; then
    echo "agents: host key fingerprint mismatch for $fapid (offered ${fahave:-none})" >&2
    fleet_event reject "approve host-fp-mismatch peer=$fapid"; return 1
  fi
  # Only now does the request become a peer.
  if [ "$fasrc" = "$fapd" ]; then
    mkdir -p "$fad"; cp "$fapd"/* "$fad"/ 2>/dev/null; rm -rf "$fapd"
  fi
  # Incoming enrollment carries the sender's hostname. SSH connects with our
  # per-peer HostKeyAlias, so copying that line verbatim breaks the reverse hop.
  # Keep the verified key bytes and bind them to the same alias as outbound joins.
  if [ -s "$fad/host.pub" ]; then
    fapin=$(cat "$fad/host.pub")
    printf '%s\n' "$fapin" | fleet_pin_host "$fad" || return 1
  fi
  fleet_meta_set "$fad" state approved
  fleet_meta_set "$fad" host_fp "${fahave:-unpinned}"
  fleet_meta_set "$fad" approved_at "$(fleet_now)"
  fleet_meta_set "$fad" added_by "${2:-$(fleet_self_id)}"
  farc=0; fleet_authorize "$fapid" "$fad" || farc=1
  fleet_allowed_signers >/dev/null; fleet_known_hosts >/dev/null
  fleet_event approve "peer=$fapid"
  # The peer is approved -- that decision stands and is durable -- but an
  # approval whose grant did not land is not a working peer, so say so and exit
  # non-zero rather than printing success over a transport that will not open.
  [ "${farc:-0}" = 1 ] && { echo "agents: $fapid is approved but has no inbound ssh grant; re-run 'agents fleet approve $fapid' after fixing $(fleet_authkeys)" >&2; return 1; }
  return 0
}

# --- inbound ssh authorization ---------------------------------------------
# An approved peer reaches `agents fleet serve` over ssh with its *fleet*
# key, so approval has to put that key into this account's authorized_keys —
# otherwise every ssh enrollment ends in a dead transport the operator has to
# fix by hand. Each line is tagged with the peer id so revocation can take it
# back out, and the command/restrictions keep the grant to this one verb.
fleet_authkeys() { echo "${N2_FLEET_AUTHORIZED_KEYS:-$HOME/.ssh/authorized_keys}"; }

# Both grant mutations are read-modify-write over the whole file: deauthorize
# filters a snapshot and writes it back, authorize deauthorizes and appends.
# Run two of them at once -- two revocations from different peers arriving at
# the same `fleet serve`, or a revoke racing an approval -- and the later
# writer's snapshot still holds the line the earlier writer removed, so it
# restores a grant that was supposed to be gone. That is a revoked peer whose
# ssh door is open again, and both calls report success. Measured: 3 grants
# survived removal in 30 concurrent trials before this lock.
#
# mkdir is the portable atomic test-and-set (flock is not on macOS), and the
# lock lives beside the file it guards rather than in the fleet root, because
# the file -- not the fleet -- is the shared resource: two peers sharing one
# account's authorized_keys must contend even with separate fleet roots.
#
# Freeing a lock directory has to be atomic. `rm -rf` is not: it unlinks the
# entries and then rmdir's the directory, so a waiter that creates a recovery
# marker inside it during that window leaves the directory behind with no pid
# file (rmdir returns ENOTEMPTY and rm -rf gives up). Every later waiter then
# reads an empty pid, treats it as a live acquire that has not written its pid
# yet, and waits out the full ceiling on a lock nobody holds. Measured: 1 of
# 100 waiters failed that way, always the last one, racing an unlock.
#
# rename is atomic and single-winner: the loser's mv fails because the source
# is already gone, and it must then do nothing -- falling back to rm -rf here
# would delete a lock some other waiter has since legitimately acquired.
# Anything created inside the directory after the rename rides along to the
# doomed name and is removed with it.
fleet_ak_drop() { # <lockdir>
  fleet_ak_seq=$(( ${fleet_ak_seq:-0} + 1 ))
  fakdg="$1.gone.$$.$fleet_ak_seq"
  mv "$1" "$fakdg" 2>/dev/null || return 1
  rm -rf "$fakdg" 2>/dev/null || true
  return 0
}

# Re-entrant: fleet_authorize holds the lock across its own fleet_deauthorize
# call, so the depth counter lets the inner acquire pass instead of deadlock.
fleet_ak_lock() {
  if [ "${fleet_ak_depth:-0}" -gt 0 ]; then
    fleet_ak_depth=$((fleet_ak_depth + 1)); return 0
  fi
  faklk=$(fleet_authkeys).n2lock faklt=0 faklnp=0 faklsw=0
  # The first approval on a machine runs before ~/.ssh exists; without this the
  # lock could never be taken and every grant would time out.
  mkdir -p "$(dirname "$faklk")" 2>/dev/null || true
  until mkdir "$faklk" 2>/dev/null; do
    # A holder that died mid-rewrite must not wedge every later revocation:
    # adopt the lock once its recorded pid is gone. An empty pid file is
    # normally a live acquire that has not reached its printf yet -- but a
    # holder killed in that same window, or a directory stranded by an older
    # non-atomic free, leaves one permanently. So an empty pid is waited out
    # for a grace period (40 x 0.05s = 2s, orders of magnitude longer than
    # mkdir-to-printf) and only then treated as stale.
    faklp=$(cat "$faklk/pid" 2>/dev/null || echo)
    if [ -n "$faklp" ]; then faklnp=0
    else faklnp=$((faklnp + 1)); [ "$faklnp" -gt 40 ] && faklp=nopid; fi
    if [ -n "$faklp" ] && { [ "$faklp" = nopid ] || ! kill -0 "$faklp" 2>/dev/null; }; then
      # Recovery must itself be exclusive. Deleting the directory on sight
      # lets two waiters that both saw the same dead pid each delete and
      # re-create it, and both then believe they hold the lock -- the very
      # double entry the lock exists to prevent. So claim the right to
      # recover atomically first: mkdir of a marker named for the dead pid
      # succeeds for exactly one waiter per lock instance.
      if mkdir "$faklk/steal.$faklp" 2>/dev/null; then
        faklsw=0
        # The marker may have landed in a *different*, newer lock directory
        # than the one whose pid we read (another waiter can recover and
        # re-acquire in between). Re-read under the marker: only a still
        # recorded, still dead holder may be removed. For the nopid case the
        # pid must still be absent -- if it appeared, a live holder wrote it.
        faklv=$(cat "$faklk/pid" 2>/dev/null || echo)
        if [ "$faklv" = "$faklp" ] || { [ "$faklp" = nopid ] && [ -z "$faklv" ]; }; then
          fleet_ak_drop "$faklk"
        else
          rmdir "$faklk/steal.$faklp" 2>/dev/null || true
        fi
        # Either way the lock instance we measured is gone: a later empty pid
        # belongs to a different acquire and is owed its own full grace. Without
        # this reset a waiter that loses the re-acquire race carries an expired
        # counter forward and would steal the next holder's lock inside its
        # mkdir-to-printf window -- reintroducing the double entry.
        faklnp=0
      else
        # The marker exists. Usually that is a live recoverer a few
        # milliseconds ahead of us and we simply wait. But a recoverer killed
        # between marker and rename leaves it forever, and because the drop
        # is now atomic a second recoverer cannot cause a double entry --
        # the loser's rename just fails. So reclaim an abandoned marker after
        # a grace period (100 x 0.05s = 5s) instead of waiting out the
        # ceiling and failing a lock nobody holds.
        faklsw=$((faklsw + 1))
        if [ "$faklsw" -gt 100 ]; then
          faklsw=0; rmdir "$faklk/steal.$faklp" 2>/dev/null || true
        fi
      fi
      faklt=$((faklt + 1))
      [ "$faklt" -gt 300 ] && return 1
      sleep 0.05 2>/dev/null || sleep 1
      continue
    fi
    faklt=$((faklt + 1))
    # ~15s ceiling. Timing out is reported as a failure by the caller rather
    # than proceeding unserialized, which is the bug this lock exists to fix.
    [ "$faklt" -gt 300 ] && return 1
    sleep 0.05 2>/dev/null || sleep 1
  done
  printf '%s\n' "$$" > "$faklk/pid" 2>/dev/null || true
  fleet_ak_depth=1
  return 0
}

fleet_ak_unlock() {
  fleet_ak_depth=$(( ${fleet_ak_depth:-1} - 1 ))
  [ "${fleet_ak_depth}" -gt 0 ] && return 0
  fleet_ak_depth=0
  fleet_ak_drop "$(fleet_authkeys).n2lock"
  return 0
}

# The exported names take the lock; the _locked bodies do the work. Both
# preserve the inner status so callers still see a named failure.
fleet_authorize() {  # <peerid> <peerdir>
  fleet_ak_lock || { fleet_authorize_failed "$1" "timed out waiting for another grant change to finish"; return 1; }
  fleet_authorize_locked "$@"; fawrc=$?
  fleet_ak_unlock
  return $fawrc
}

fleet_deauthorize() {  # <peerid>
  fleet_ak_lock || { fleet_deauthorize_failed "$1" "timed out waiting for another grant change to finish"; return 1; }
  fleet_deauthorize_locked "$@"; fdwrc=$?
  fleet_ak_unlock
  return $fdwrc
}

fleet_authorize_locked() {  # <peerid> <peerdir>
  fautrans=$(fleet_meta "$2" transport 2>/dev/null || echo ssh)
  case $fautrans in ssh|tailscale) ;; *) return 0 ;; esac
  [ -f "$2/key.pub" ] || return 0
  if [ "${N2_FLEET_NO_AUTHORIZED_KEYS:-}" = 1 ]; then return 0; fi
  fauf=$(fleet_authkeys); faud=$(dirname "$fauf")
  # A write that cannot happen is a dead transport, not a detail: swallowing it
  # lets approval report success while the peer can never reach us. Every
  # failure below is named and propagated to the caller.
  mkdir -p "$faud" 2>/dev/null || { fleet_authorize_failed "$1" "cannot create $faud"; return 1; }
  chmod 700 "$faud" 2>/dev/null || true
  [ -f "$fauf" ] || { : > "$fauf" 2>/dev/null || { fleet_authorize_failed "$1" "cannot create $fauf"; return 1; }; }
  chmod 600 "$fauf" 2>/dev/null || true
  fleet_deauthorize "$1" ||
    { fleet_authorize_failed "$1" "cannot clear the previous grant in $fauf"; return 1; }
  faucmd="${N2_FLEET_REMOTE_CMD:-agents} fleet serve"
  printf 'restrict,command="%s" %s n2-fleet:%s\n' \
    "$faucmd" "$(awk '{print $1" "$2}' "$2/key.pub")" "$1" >> "$fauf" ||
    { fleet_authorize_failed "$1" "cannot write $fauf"; return 1; }
  grep -q " n2-fleet:$1\$" "$fauf" 2>/dev/null ||
    { fleet_authorize_failed "$1" "grant missing from $fauf after write"; return 1; }
  fleet_event authorize "peer=$1"
}

fleet_authorize_failed() {  # <peerid> <why>
  echo "agents: could not install the inbound ssh grant for $1 ($2) — that peer cannot reach this machine until it is installed" >&2
  fleet_event authorize-failed "peer=$1 $2"
}

# Removing a grant can fail exactly like installing one (read-only file, a
# directory we cannot stage a rewrite in). A revocation that reports success
# while the peer's key is still in authorized_keys is worse than a loud
# failure: the operator believes inbound ssh is closed when it is still open.
# Every failure below is named and propagated to the caller.
# grep cannot distinguish "no match" from "could not read the file" by exit
# status alone -- both are non-zero (1 and 2 respectively). For an
# authorized_keys grant that distinction is the entire safety question:
# "absent" means the ssh door is shut, "unreadable" means we do not know and
# must not report success. 0 = present, 1 = absent, 2 = could not read.
fleet_grant_state() {  # <authkeys> <peerid>
  [ -e "$1" ] || return 1
  grep -q " n2-fleet:$2\$" "$1" 2>/dev/null
  case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

fleet_deauthorize_locked() {  # <peerid> — remove this peer's inbound ssh grant
  fduf=$(fleet_authkeys); [ -e "$fduf" ] || return 0
  fleet_grant_state "$fduf" "$1"; fdus=$?
  [ "$fdus" = 1 ] && return 0
  [ "$fdus" = 2 ] &&
    { fleet_deauthorize_failed "$1" "cannot read $fduf to find the grant"; return 1; }
  fdut=$fduf.n2$$
  # Stage the temp file explicitly: a redirection that fails to open its target
  # leaves a shell status indistinguishable from grep -v's legitimate "every
  # line matched" (1), so the create has to be checked on its own.
  : > "$fdut" 2>/dev/null ||
    { fleet_deauthorize_failed "$1" "cannot stage a rewrite beside $fduf"; return 1; }
  grep -v " n2-fleet:$1\$" "$fduf" > "$fdut" 2>/dev/null; fdug=$?
  # 0 = lines kept, 1 = the grant was the only line (empty result is correct),
  # 2+ = read or write error, which must never be mistaken for an empty result:
  # accepting it would truncate authorized_keys.
  if [ "$fdug" -gt 1 ]; then
    rm -f "$fdut" 2>/dev/null
    fleet_deauthorize_failed "$1" "cannot read $fduf while rewriting it"; return 1
  fi
  if ! cat "$fdut" > "$fduf" 2>/dev/null; then
    rm -f "$fdut" 2>/dev/null
    fleet_deauthorize_failed "$1" "cannot rewrite $fduf"; return 1
  fi
  rm -f "$fdut" 2>/dev/null
  chmod 600 "$fduf" 2>/dev/null || true
  fleet_grant_state "$fduf" "$1"; fdus=$?
  if [ "$fdus" != 1 ]; then
    [ "$fdus" = 2 ] &&
      { fleet_deauthorize_failed "$1" "cannot re-read $fduf to confirm the grant is gone"; return 1; }
    fleet_deauthorize_failed "$1" "the grant is still present after the rewrite"; return 1
  fi
  fleet_event deauthorize "peer=$1"
  return 0
}

fleet_deauthorize_failed() {  # <peerid> <why>
  echo "agents: could not remove the inbound ssh grant for $1 ($2) — that peer can still reach this machine over ssh until the line tagged n2-fleet:$1 is removed from $(fleet_authkeys)" >&2
  fleet_event deauthorize-failed "peer=$1 $2"
}

fleet_deny() {
  fdpd=$(fleet_pending_dir "$1"); [ -d "$fdpd" ] || { echo "agents: no pending request: $1" >&2; return 1; }
  fdrc=0; fleet_deauthorize "$1" || { fdrc=1; fleet_revoke_pending_add "$1"; }
  rm -rf "$fdpd"; fleet_event deny "peer=$1"
  # The denial itself stands -- the request is gone and the peer is not
  # enrolled -- but a stale inbound grant is a live hole, so fail loudly.
  # Status 3 distinguishes "denied, grant left behind" from "no such request".
  [ "$fdrc" = 1 ] && return 3
  return 0
}

# A revocation whose grant removal failed leaves work behind. The revocation
# itself is durable (the id is on the `revoked` list and every fleet request
# from it is refused), but the ssh door is still open, and nothing in the
# roster remembers that: the peer record is gone and `fleet_revoked` short
# -circuits every later pass. So the unfinished half is written down here, and
# reconciliation retries it until the grant is really gone.
fleet_revoke_pending_file() { echo "$fleet_root/revoke-pending"; }

fleet_revoke_pending_add() {  # <peerid>
  frpf=$(fleet_revoke_pending_file)
  grep -qx "$1" "$frpf" 2>/dev/null && return 0
  printf '%s\n' "$1" >> "$frpf" 2>/dev/null || true
}

fleet_revoke_pending_clear() {  # <peerid>
  frcf=$(fleet_revoke_pending_file); [ -f "$frcf" ] || return 0
  grep -qx "$1" "$frcf" 2>/dev/null || return 0
  frct=$frcf.n2$$
  grep -vx "$1" "$frcf" > "$frct" 2>/dev/null || : > "$frct" 2>/dev/null || return 1
  cat "$frct" > "$frcf" 2>/dev/null; rm -f "$frct" 2>/dev/null
}

fleet_revoke_pending_ids() {
  frif=$(fleet_revoke_pending_file); [ -f "$frif" ] || return 0
  awk 'NF' "$frif" 2>/dev/null
}

# Retry every grant removal a past revocation could not finish. Prints one
# line per peer it touched and returns non-zero while any grant survives, so
# the caller (and the operator) learn that the ssh door is still open.
fleet_retry_pending_revocations() {
  frprc=0
  for frpid2 in $(fleet_revoke_pending_ids); do
    [ -n "$frpid2" ] || continue
    if fleet_deauthorize "$frpid2"; then
      fleet_revoke_pending_clear "$frpid2"
      fleet_event revoke-cleanup "peer=$frpid2"
      printf 'revoked-grant-removed\t%s\tretry\n' "$frpid2"
    else
      frprc=1
      printf 'revoked-grant-not-removed\t%s\tpending\n' "$frpid2"
    fi
  done
  return $frprc
}

fleet_revoke() {
  frpid=$1
  grep -q "^$frpid " "$fleet_root/revoked" 2>/dev/null ||
    printf '%s %s\n' "$frpid" "$(fleet_now)" >> "$fleet_root/revoked"
  frrc=0; fleet_deauthorize "$frpid" || frrc=1
  rm -rf "$(fleet_peer_dir "$frpid")" "$(fleet_pending_dir "$frpid")"
  fleet_allowed_signers >/dev/null; fleet_known_hosts >/dev/null
  fleet_event revoke "peer=$frpid"
  # Application-level revocation is durable regardless; the non-zero status
  # says the *ssh* door is still open and needs a hand. Remember the unfinished
  # cleanup either way, so a later `fleet reconcile` can finish (or confirm) it.
  if [ "$frrc" = 1 ]; then fleet_revoke_pending_add "$frpid"; return 1; fi
  fleet_revoke_pending_clear "$frpid"
  return 0
}

# Record a peer locally without approving it (the joiner's side: it must be
# able to answer the approver later, but grants it nothing until approved).
fleet_peer_record() {  # <peerid> <keyfile> <machine> <transport> <address> <user> <home> <state>
  prd=$(fleet_peer_dir "$1"); mkdir -p "$prd"
  cp "$2" "$prd/key.pub"
  fleet_meta_set "$prd" peer "$1"; fleet_meta_set "$prd" machine "$3"
  fleet_meta_set "$prd" transport "$4"; fleet_meta_set "$prd" address "$5"
  fleet_meta_set "$prd" user "$6"; [ -n "$7" ] && fleet_meta_set "$prd" home "$7"
  fleet_meta_set "$prd" state "$8"
  fleet_allowed_signers >/dev/null; fleet_known_hosts >/dev/null
}

# The approver calls back after `approve`, so the joiner learns the approval
# without polling. The joiner accepts it only from a peer it itself asked to
# join (the `joined/` marker) — mutual consent, not a claim from a stranger.
fleet_handle_enrolled() {
  ndfrom=$1 ndpf=$2 ndd=$3
  [ -f "$fleet_root/joined/$(fleet_slug "$ndfrom")" ] || { echo "ERR not-invited"; return 1; }
  ndmachine=$(sed -n 's/^machine=//p' "$ndpf" | head -1)
  ndpeer=$(fleet_peer_dir "$ndfrom")
  [ -d "$ndpeer" ] || { echo "ERR unknown-peer"; return 1; }
  cp "$ndd/claim.pub" "$ndpeer/key.pub"
  [ -n "$ndmachine" ] && fleet_meta_set "$ndpeer" machine "$ndmachine"
  fleet_approve "$ndfrom" "$ndfrom" >/dev/null 2>&1 || { echo "ERR approve-failed"; return 1; }
  rm -f "$fleet_root/joined/$(fleet_slug "$ndfrom")"
  printf 'ack\n' > "$ndd/out"; fleet_ok "$ndd/out"
}

# --- discovery -------------------------------------------------------------
# Hub-free discovery: ask every approved peer for its roster and file anything
# we do not already know as *pending*. Reachability and a neighbour's trust
# are not enrollment approval — the operator still runs `fleet approve`.
fleet_discover() {
  dscount=0
  # Coming back online: learn about revocations before adopting new pending
  # records, so a peer the fleet cut off while we were away is not re-filed.
  fleet_reconcile 2>/dev/null | sed 's/^/reconcile\t/'

  for dspid in $(fleet_peer_ids); do
    [ -n "$dspid" ] || continue
    [ "$dspid" = "$(fleet_self_id)" ] && continue
    fleet_approved "$dspid" || continue
    dsout=$(fleet_call "$dspid" roster 2>/dev/null) || continue
    printf '%s\n' "$dsout" | while IFS="$(printf '\t')" read -r cid cmach ctrans cstate caddr ckey; do
      [ -n "$cid" ] || continue
      case $cid in SHA256:*) ;; *) continue ;; esac
      [ "$cid" = "$(fleet_self_id)" ] && continue
      [ "$cstate" = approved ] || continue
      fleet_revoked "$cid" && continue
      [ "$(fleet_peer_state "$cid")" = unknown ] || continue
      [ -n "$ckey" ] || continue
      dspd=$(fleet_pending_dir "$cid"); mkdir -p "$dspd"
      printf '%s\n' "$ckey" | tr '_' ' ' > "$dspd/key.pub"
      # A neighbour that lies about a key cannot make it stick: the
      # fingerprint must equal the id it was advertised under.
      if [ "$(fleet_fp "$dspd/key.pub")" != "$cid" ]; then rm -rf "$dspd"; continue; fi
      fleet_meta_set "$dspd" peer "$cid"; fleet_meta_set "$dspd" machine "$cmach"
      fleet_meta_set "$dspd" transport "$ctrans"; fleet_meta_set "$dspd" address "$caddr"
      fleet_meta_set "$dspd" state pending
      fleet_meta_set "$dspd" discovered_from "$dspid"
      fleet_meta_set "$dspd" requested_at "$(fleet_now)"
      fleet_event discover "peer=$cid via=$dspid"
      printf 'discovered\t%s\t%s\tvia %s\n' "$cid" "$cmach" "$dspid"
    done
    dscount=$((dscount+1))
  done
  [ "$dscount" -gt 0 ] || echo "agents: no approved peers to ask" >&2
  return 0
}

# Reconnect reconciliation for revocation. Pull each approved neighbour's
# revocation list and adopt anything new. Same trust rule as fleet_handle_revoke:
# a peer we already trust may tell us it cut someone off, but it can never
# revoke us, and never itself through itself.
fleet_reconcile() {
  rcn=0; rcmark=$fleet_root/.reconcile-incomplete.$$; rm -f "$rcmark" 2>/dev/null
  # Unfinished cleanup from an earlier revocation comes first, and needs no
  # peer: the grant is on *this* machine. `fleet_revoked` makes the roster
  # pass skip these ids, so without this retry the door stays open forever.
  fleet_retry_pending_revocations || : > "$rcmark"
  for rcpid in $(fleet_peer_ids); do
    [ -n "$rcpid" ] || continue
    [ "$rcpid" = "$(fleet_self_id)" ] && continue
    fleet_approved "$rcpid" || continue
    rcout=$(fleet_call "$rcpid" revocations 2>/dev/null) || { printf 'unreachable\t%s\n' "$rcpid"; continue; }
    rcn=$((rcn+1))
    printf '%s\n' "$rcout" | while read -r rcid; do
      case $rcid in SHA256:*) ;; *) continue ;; esac
      [ "$rcid" = "$(fleet_self_id)" ] && continue
      [ "$rcid" = "$rcpid" ] && continue
      fleet_revoked "$rcid" && continue
      if fleet_revoke "$rcid"; then
        printf 'revoked\t%s\tvia %s\n' "$rcid" "$rcpid"
      else
        printf 'revoked-grant-not-removed\t%s\tvia %s\n' "$rcid" "$rcpid"
        : > "$rcmark"
      fi
    done
  done
  [ "$rcn" -gt 0 ] || echo "agents: no approved peers to reconcile with" >&2
  # The `while read` above runs in a subshell, so incomplete cleanup is
  # reported through a marker file rather than a lost exit status.
  if [ -f "$rcmark" ]; then rm -f "$rcmark" 2>/dev/null; return 1; fi
  return 0
}

# --- enrollment (client side) ----------------------------------------------

fleet_host_pub() {  # this machine's ssh host key line, for known_hosts pinning
  for f in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    [ -f "$f" ] || continue
    printf '%s %s\n' "${N2_FLEET_HOSTNAME:-$(hostname 2>/dev/null)}" "$(awk '{print $1" "$2}' "$f")"
    return 0
  done
  return 0
}

fleet_invite() {  # fleet_invite [ttl] [peerid]
  ttl=${1:-900}; want=${2:-}
  mkdir -p "$fleet_root/invites"; chmod 700 "$fleet_root/invites" 2>/dev/null || true
  secret=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
  codeid=$(printf '%s' "$secret" | shasum -a 256 | cut -c1-16)
  f=$fleet_root/invites/$codeid
  : > "$f"; chmod 600 "$f"
  { printf 'secret=%s\nexpires=%s\npeer=%s\n' "$secret" "$(( $(fleet_now) + ttl ))" "$want"; } > "$f"
  fleet_event invite "codeid=$codeid ttl=$ttl bound=${want:+yes}"   # the code itself is never journaled
  printf '%s\n' "$secret"
}

fleet_enroll_request() {  # transport address user home [code] [hostkey] [port] [identity]
  t=$1 addr=$2 user=$3 home=$4 code=$5 ehk=${6:-} eport=${7:-} eid=${8:-}
  fleet_have_identity || fleet_die "no fleet identity (run: agents fleet init)"
  b=$fleet_root/bootstrap; rm -rf "$b"; mkdir -p "$b"
  # Pin the responder's host key for this one hop before we speak to it. ssh
  # host verification is never turned off, so an ssh enrollment with no
  # out-of-band host key has nothing to check and is refused here rather than
  # silently trusting whatever answers the address.
  if [ -n "$ehk" ]; then
    printf '%s\n' "$ehk" | fleet_host_line > "$b/host.pub"
    [ -s "$b/host.pub" ] || fleet_die "--host-key is not a valid known_hosts line"
    # The pin is keyed by the address we are about to dial, not by the name
    # the remote wrote into it.
    ehkk=$(awk '{print $2" "$3}' "$b/host.pub")
    printf '%s %s\n' n2-bootstrap "$ehkk" > "$b/host.pub"
  fi
  case $t in
    ssh|tailscale)
      # An existing pin belongs to the peer it was filed under, never to the
      # address; reusing it here would let an already-enrolled machine vouch
      # for whatever now answers that name. Every ssh enrollment needs its own
      # out-of-band host key.
      if [ ! -s "$b/host.pub" ]; then
        fleet_die "no pinned ssh host key for $addr — get it from the other machine (agents fleet id --host-key) and pass --host-key '<line>'"
      fi ;;
  esac
  fleet_meta_set "$b" transport "$t"; fleet_meta_set "$b" address "$addr"
  # The responder's sshd may not be on 22, and the bootstrap hop is dialled
  # before any peer record exists to carry the port. Without this the only way
  # to enroll such a machine was to hand-edit meta after the fact.
  if [ -n "$eport" ]; then
    fleet_valid_port "$eport" || fleet_die "--port is not a port number: $eport"
    fleet_meta_set "$b" port "$eport"
  fi
  fleet_meta_set "$b" user "$user"; [ -n "$home" ] && fleet_meta_set "$b" home "$home"
  fleet_meta_set "$b" command "${N2_FLEET_REMOTE_CMD:-agents}"
  # The one hop that predates any fleet authorization (see fleet_ssh_run).
  if [ -n "$eid" ]; then
    [ -f "$eid" ] || fleet_die "--ssh-identity is not a file: $eid"
    fleet_meta_set "$b" bootstrap "$eid"
  else
    fleet_meta_set "$b" bootstrap 1
  fi
  etmp=$(mktemp -d "${TMPDIR:-/tmp}/n2join.XXXXXX") || return 1
  host=$(fleet_host_pub)
  {
    printf 'key=%s\n' "$(awk '{print $1" "$2}' "$(fleet_key).pub")"
    printf 'machine=%s\n' "$(fleet_self_machine)"
    printf 'transport=%s\n' "$t"
    printf 'address=%s\n' "${N2_FLEET_SELF_ADDRESS:-$(fleet_self_machine)}"
    printf 'user=%s\n' "${N2_FLEET_SELF_USER:-$(id -un)}"
    [ -n "${N2_FLEET_SELF_PORT:-}" ] && printf 'port=%s\n' "$N2_FLEET_SELF_PORT"
    [ "$t" = exec ] && printf 'home=%s\n' "$HOME"
    [ -n "$host" ] && printf 'host=%s\n' "$host"
    if [ -n "$code" ]; then
      printf 'codeid=%s\n' "$(printf '%s' "$code" | shasum -a 256 | cut -c1-16)"
      printf 'tag=%s\n' "$(fleet_tag "$code" "$(fleet_self_id)" "$host")"
    fi
  } > "$etmp/payload"
  fleet_envelope any enroll "$etmp/payload" > "$etmp/req"
  fleet_carry "$b" < "$etmp/req" > "$etmp/rep"
  case $(head -1 "$etmp/rep" 2>/dev/null) in
    OK) body=$(tail -n +2 "$etmp/rep" | base64 -d 2>/dev/null) ;;
    ERR*) head -1 "$etmp/rep" >&2; rm -rf "$etmp"; return 1 ;;
    *) echo "ERR unreachable" >&2; rm -rf "$etmp"; return 1 ;;
  esac
  rm -rf "$etmp"
  printf '%s\n' "$body"
}

# Record the machine we just asked to join, from its enroll reply. Approved
# means the bound pairing code authenticated it; otherwise it stays pending
# here too until its own approval callback arrives.
fleet_record_reply() {  # fleet_record_reply <reply-body-file> <transport> <addr> <user> <home> [code] [port]
  rb=$1 rcode=${6:-} rport=${7:-}
  rpeer=$(sed -n 's/^peer=//p' "$rb" | head -1)
  rmach=$(sed -n 's/^machine=//p' "$rb" | head -1)
  rres=$(sed -n 's/^result=//p' "$rb" | head -1)
  rhost=$(sed -n 's/^host=//p' "$rb" | head -1)
  rtag=$(sed -n 's/^rtag=//p' "$rb" | head -1)
  [ -n "$rpeer" ] || return 1
  rtmp=$(mktemp -d "${TMPDIR:-/tmp}/n2rec.XXXXXX") || return 1
  sed -n 's/^key=//p' "$rb" | head -1 > "$rtmp/key.pub"
  [ "$(fleet_fp "$rtmp/key.pub")" = "$rpeer" ] || { rm -rf "$rtmp"; echo "agents: reply key does not match peer id" >&2; return 1; }
  # A reply is self-asserted: `key=` only proves internal consistency, never
  # *which* machine answered. When we paired with a code, the responder must
  # prove it holds that secret, bound to the fleet id and host key it just
  # claimed — otherwise whoever intercepted the carrier could name itself our
  # approved peer. Without that proof we never record `approved`.
  if [ -n "$rcode" ]; then
    if [ -z "$rtag" ]; then
      rm -rf "$rtmp"
      echo "agents: responder did not prove it holds the pairing code — refusing to enroll $rpeer" >&2
      fleet_event reject "join missing-responder-proof peer=$rpeer"; return 1
    fi
    if [ "$rtag" != "$(fleet_tag "$rcode" "$rpeer" "$rhost")" ]; then
      rm -rf "$rtmp"
      echo "agents: responder identity does not match the pairing code — refusing to enroll $rpeer" >&2
      fleet_event reject "join responder-proof-mismatch peer=$rpeer"; return 1
    fi
  fi
  state=pending
  if [ "$rres" = approved ]; then
    if [ -n "$rcode" ]; then state=approved
    else
      echo "agents: peer claims approval but presented no pairing proof — holding $rpeer pending" >&2
      fleet_event reject "join unproven-approval peer=$rpeer"
      rres="pending unproven-approval"
    fi
  fi
  fleet_peer_record "$rpeer" "$rtmp/key.pub" "${rmach:-unknown}" "$2" "$3" "$4" "$5" "$state"
  d=$(fleet_peer_dir "$rpeer")
  # Where the peer's lasting pin comes from. The operator's out-of-band
  # `--host-key` is the stronger claim: it was carried by a human who already
  # had access to that machine, and it is the key this hop actually verified
  # against. The responder's self-reported `host=` line is the weaker one --
  # it is whatever the far side chose to say about itself. Letting the weaker
  # claim overwrite the stronger one would let a peer swap in a different host
  # key for every hop after enrollment, which is the pin quietly going away.
  # So the operator's key wins, and the self-report is only used when the
  # enrollment had no out-of-band key to begin with (the exec/tailscale paths).
  # This is also the only correct answer for an sshd whose host key is not the
  # system default (a per-instance sshd, a non-standard HostKey): the machine
  # cannot name that key from /etc/ssh, but the operator can.
  if [ -s "$fleet_root/bootstrap/host.pub" ]; then
    fleet_host_line < "$fleet_root/bootstrap/host.pub" | fleet_pin_host "$d" || rm -f "$d/host.pub"
  else
    sed -n 's/^host=//p' "$rb" | head -1 | fleet_pin_host "$d" || rm -f "$d/host.pub"
  fi
  fleet_meta_set "$d" command "${N2_FLEET_REMOTE_CMD:-agents}"
  # The port that just worked for the bootstrap hop is the port every later
  # hop must use; dropping it here would strand the peer on 22.
  [ -n "$rport" ] && fleet_valid_port "$rport" && fleet_meta_set "$d" port "$rport"
  [ "$state" = approved ] && fleet_meta_set "$d" approved_at "$(fleet_now)"
  # Open the inbound channel for the machine we just dialled -- in *both*
  # outcomes, and this is the difference between an approval-only enrollment
  # that completes and one that deadlocks. `approve` on the far side answers
  # with an `enrolled` callback (fleet_notify_approved) so the joiner learns
  # its fate without polling, and that callback arrives over ssh carrying the
  # approver's fleet key. If the joiner only authorized an *already* approved
  # responder, the pending case could never receive the very message that
  # would approve it: the approver cannot connect, its failure is swallowed,
  # and the peer sits pending forever.
  #
  # Granting it at pending is not granting trust. The grant is
  # `restrict,command="agents fleet serve"` -- a fleet protocol socket, not a
  # shell -- and fleet_verify refuses every verb but enroll/enrolled from a
  # peer that is not approved here. `enrolled` additionally demands the
  # `joined/` marker written just below, so only a machine we ourselves chose
  # to dial can use it, and fleet_handle_enrolled consumes that marker. The
  # authority this adds over a stranger is: may tell us we were approved, once,
  # having proved possession of the exact fleet key whose fingerprint we
  # recorded. fleet_revoke/fleet_deauthorize withdraw it.
  rauthrc=0; fleet_authorize "$rpeer" "$d" || rauthrc=1
  # Arm the one-shot callback marker only while a callback is still owed. A
  # bound-code join answers `approved` on the spot, so no `enrolled` will ever
  # come; arming it there left a capability nobody was going to spend, valid
  # forever. Disarm in that case instead, which also clears a marker left over
  # from an earlier attempt at the same peer.
  mkdir -p "$fleet_root/joined"
  if [ "$state" = approved ]; then rm -f "$fleet_root/joined/$(fleet_slug "$rpeer")"
  else : > "$fleet_root/joined/$(fleet_slug "$rpeer")"; fi
  fleet_allowed_signers >/dev/null; fleet_known_hosts >/dev/null
  rm -rf "$rtmp"
  printf '%s\t%s\t%s\n' "$rpeer" "${rmach:-unknown}" "$rres"
  [ "${rauthrc:-0}" = 1 ] && return 1
  return 0
}

# Tell a newly approved peer that it is in, so it can approve us back without
# polling. Failure here is not fatal: the peer can re-run `join`.
fleet_notify_approved() {  # <peerid>
  ntmp=$(mktemp -d "${TMPDIR:-/tmp}/n2not.XXXXXX") || return 0
  { printf 'key=%s\n' "$(awk '{print $1" "$2}' "$(fleet_key).pub")"
    printf 'machine=%s\n' "$(fleet_self_machine)"; } > "$ntmp/p"
  fleet_envelope "$1" enrolled "$ntmp/p" > "$ntmp/req"
  if fleet_carry "$(fleet_peer_dir "$1")" < "$ntmp/req" >/dev/null 2>&1; then
    nrc=0
  else
    nrc=1
  fi
  rm -rf "$ntmp"
  return $nrc
}

# Re-point an already-enrolled peer at a different address, port, account,
# home or carrier. Discovery (fleet_discover) learns *who* a peer-of-peer is
# from a referrer, but the referrer's own routing fields are its private view
# of the network -- a tailscale name it can resolve, an ssh port only it has
# open -- so a newly approved peer often has no route this machine can dial.
# Before this verb the only repair was hand-editing meta, which meant the
# routing fields escaped every check fleet_carry applies. `route` writes the
# same fields through the same validators the enrollment paths use.
#
# It never changes trust: the peer id, its public key and its approval state
# are untouched, and an ssh/tailscale route still refuses to exist without a
# pinned host key (host verification is never disabled).
# Fields arrive positionally, empty meaning "leave alone"; none of them has a
# meaningful empty value, so no information is lost and the caller needs no
# quoting dance to pass a home or a command containing spaces.
fleet_route() {  # fleet_route <peerid> <transport> <address> <port> <user> <home> <command> <hostkey>
  rtid=$1 rtt=${2:-} rtaddr=${3:-} rtport=${4:-} rtuser=${5:-} rthome=${6:-} rtcmd=${7:-} rthk=${8:-}
  rtd=$(fleet_peer_dir "$rtid"); [ -d "$rtd" ] || { echo "agents: unknown peer: $rtid" >&2; return 1; }
  [ "$rtid" = "$(fleet_self_id)" ] && { echo "agents: refusing to route this machine to itself" >&2; return 1; }
  if [ -z "$rtt$rtaddr$rtport$rtuser$rthome$rtcmd$rthk" ]; then
    echo "agents: route needs at least one field to change" >&2; return 1
  fi

  # Validate everything before writing anything, so a rejected field cannot
  # leave the peer half-re-routed and unreachable.
  rteff=${rtt:-$(fleet_meta "$rtd" transport)}
  case $rteff in
    ssh|tailscale|exec) ;;
    *) echo "agents: --transport must be ssh, tailscale or exec (got: $rteff)" >&2; return 1 ;;
  esac
  [ -z "$rtaddr" ] || fleet_valid_addr "$rtaddr" || { echo "agents: --address is not a routable host: $rtaddr" >&2; return 1; }
  [ -z "$rtuser" ] || fleet_valid_user "$rtuser" || { echo "agents: --user is not a user name: $rtuser" >&2; return 1; }
  [ -z "$rtport" ] || fleet_valid_port "$rtport" || { echo "agents: --port is not a port number: $rtport" >&2; return 1; }
  if [ -n "$rthome" ]; then
    case $rthome in /*) ;; *) echo "agents: --home must be an absolute path: $rthome" >&2; return 1 ;; esac
    [ "$(printf '%s' "$rthome" | wc -l | tr -d ' ')" = 0 ] || { echo "agents: --home must be a single line" >&2; return 1; }
  fi
  if [ -n "$rtcmd" ]; then
    [ "$(printf '%s' "$rtcmd" | wc -l | tr -d ' ')" = 0 ] || { echo "agents: --command must be a single line" >&2; return 1; }
  fi
  if [ -n "$rthk" ]; then
    rthkt=$(mktemp "${TMPDIR:-/tmp}/n2rt.XXXXXX") || return 1
    printf '%s\n' "$rthk" | fleet_host_line > "$rthkt"
    [ -s "$rthkt" ] || { rm -f "$rthkt"; echo "agents: --host-key is not a valid known_hosts line" >&2; return 1; }
  fi
  case $rteff in
    ssh|tailscale)
      rtea=${rtaddr:-$(fleet_meta "$rtd" address)}
      fleet_valid_addr "$rtea" || { rm -f "${rthkt:-}"; echo "agents: $rteff routing needs an --address" >&2; return 1; }
      # A route we cannot verify the host key of is a route we will not dial.
      if [ -z "$rthk" ] && [ ! -s "$rtd/host.pub" ] && ! grep -q "^${rtea} " "$(fleet_known_hosts)" 2>/dev/null; then
        echo "agents: no pinned ssh host key for $rtea — pass --host-key '<line>' (from: agents fleet id --host-key on $rtid)" >&2
        return 1
      fi ;;
    exec)
      rteh=${rthome:-$(fleet_meta "$rtd" home)}
      [ -n "$rteh" ] || { echo "agents: exec routing needs a --home" >&2; return 1; }
      ;;
  esac

  [ -n "$rtt" ] && fleet_meta_set "$rtd" transport "$rtt"
  [ -n "$rtaddr" ] && fleet_meta_set "$rtd" address "$rtaddr"
  [ -n "$rtport" ] && fleet_meta_set "$rtd" port "$rtport"
  [ -n "$rtuser" ] && fleet_meta_set "$rtd" user "$rtuser"
  [ -n "$rthome" ] && fleet_meta_set "$rtd" home "$rthome"
  [ -n "$rtcmd" ] && fleet_meta_set "$rtd" command "$rtcmd"
  if [ -n "$rthk" ]; then
    # Re-pin under this peer's own alias, exactly as enrollment does, so the
    # new key replaces the old one for this peer and no other.
    printf '%s\n' "$rthk" | fleet_pin_host "$rtd" "$(fleet_meta "$rtd" address)" ||
      { rm -f "$rthkt"; echo "agents: --host-key is not a valid known_hosts line" >&2; return 1; }
    fleet_meta_set "$rtd" host_fp "$(fleet_host_fp "$rtd/host.pub")"
    fleet_known_hosts >/dev/null
    rm -f "$rthkt"
  fi
  fleet_meta_set "$rtd" routed_at "$(fleet_now)"
  fleet_event route "peer=$rtid transport=$(fleet_meta "$rtd" transport) by=operator"
  printf 'routed\t%s\t%s\t%s\n' "$rtid" "$(fleet_meta "$rtd" transport)" \
    "$(fleet_meta "$rtd" address)$( [ "$(fleet_meta "$rtd" transport)" = exec ] && printf ' %s' "$(fleet_meta "$rtd" home)")"
}

# --- CLI -------------------------------------------------------------------

# Registration shares the exact record/metadata locks with sync writers.
fleet_auth_manage() (
  set +e
  action=${1:-}; name=${2:-}
  case $action in register|status|allow|deny|login|reconcile|retire|grants|allow-login|deny-login) ;; *) fleet_die "usage: agents fleet auth <register|status|allow|deny|login|reconcile|retire|grants|allow-login|deny-login> Profile [--grant ID|--peer ID]" ;; esac
  [ -n "$name" ] || fleet_die "an auth profile is required"
  shift 2
  name=$(resolve_profile "$name") || fleet_die "unknown profile"
  cfg=$(config_dir "$name" codex) || return 1
  [ -d "$cfg" ] || fleet_die "profile has no Codex slot"
  if [ "$action" = login ]; then
    /usr/bin/python3 "$scripts_dir/fleet-auth-manage.py" login "$root" "$name" "$cfg" "$@"
    return $?
  fi
  sync_need
  metadata_address=$(sync_addr profile "$name" '-' "$SYNC_PROFILE_REL")
  binding_address=$(sync_addr settings "$name" codex .n2-owner.json)
  sync_res_lock "$metadata_address" || return 1
  trap 'sync_res_unlock "$metadata_address"' EXIT
  sync_res_lock "$binding_address" || return 1
  trap 'sync_res_unlock "$binding_address"; sync_res_unlock "$metadata_address"' EXIT
  owner_gate=$(sync_addr settings "$name" codex .n2-owner-gate)
  sync_res_lock "$owner_gate" || return 1
  trap 'sync_res_unlock "$owner_gate"; sync_res_unlock "$binding_address"; sync_res_unlock "$metadata_address"' EXIT
  /usr/bin/python3 "$scripts_dir/fleet-auth-manage.py" "$action" "$root" "$name" "$cfg" "$@"
)

# The verb table, printed by `agents fleet help` and by any unknown verb. Kept
# in step with the "CLI surface" section of docs/fleet-design.md.
fleet_usage() {
  cat <<'EOF'
agents fleet <verb>

  init [--machine <name>]                  become the founder peer
  id [--host-key]                          this machine's peer id (or host key line)
  invite [--ttl <secs>] [--peer <peerid>]  mint a one-time pairing code
  join --to <addr> [--user u] [--port n] [--ssh-identity <key>] [--code c] [--host-key <line>]
  pair --to <addr> --code <code> [--user u] [--port n] --host-key <line>
  pending                                  requests awaiting approval here
  approve <peerid> [--host-fp <fp>] [--no-host-key]
  deny <peerid>
  revoke [--propagate] <peerid>
  discover                                 learn peers-of-peers (stay pending)
  reconcile [--no-sync]                    revocations + roster + one sync round after time offline
  route <peerid> [--transport t] [--address a] [--port n] [--user u]
        [--home p] [--command c] [--host-key <line>|--host-key-file <f>]
  rehost --announce                        tell peers this machine's ssh host key changed
  rehost <peerid> --host-key <line>        re-pin a peer's host key out of band
  roster <peerid>                          read an approved peer's roster
  peers [--porcelain] [--no-probe]         roster + reachability
  ping <peerid>                            signed round trip
  status [--porcelain]                     self + peers + pending
  sync <verb>                              shared profile replication (sync help)
  tools <verb>                             fleet-managed utilities (tools help)
  task <verb>                              dispatch, handoff and task lifecycle (task help)
  send <peerid> --verb <v> [--payload-file <f>]   raw signed request
  auth <register|status|allow|deny|login|reconcile|retire|grants|allow-login|deny-login> Profile  owner binding and explicit peer consent
  serve                                    stdio responder (the remote end)
  help                                     this list
EOF
}

fleet_need_id() { fleet_have_identity || fleet_die "no fleet identity yet (run: agents fleet init)"; }

# fleet_errexit_note: `agents` runs under `set -eu`. Every fleet path reports
# failure through an explicit return code or a one-line `ERR <reason>` reply,
# and routine outcomes (peer offline, unsigned request, denied enrollment) are
# non-zero by design. Under errexit those become a silent exit(1) with no
# reply on the wire, so the fleet subsystem turns errexit off at its two entry
# points and checks every status itself.
cmd_fleet() {
  set +e
  verb=${1:-status}; [ $# -ge 1 ] && shift
  case $verb in
    auth) fleet_auth_manage "$@" ;;
    init)
      machine=$(hostname -s 2>/dev/null || echo unknown)
      while [ $# -gt 0 ]; do case $1 in --machine) machine=$2; shift 2 ;; *) fleet_die "unknown option: $1" ;; esac; done
      fleet_identity_create "$machine"
      me=$(fleet_self_id)
      d=$(fleet_peer_dir "$me"); mkdir -p "$d"
      cp "$(fleet_key).pub" "$d/key.pub"
      fleet_meta_set "$d" peer "$me"; fleet_meta_set "$d" machine "$machine"
      fleet_meta_set "$d" transport self; fleet_meta_set "$d" address localhost
      fleet_meta_set "$d" state approved; fleet_meta_set "$d" added_by "$me"
      fleet_meta_set "$d" approved_at "$(fleet_now)"
      fleet_allowed_signers >/dev/null; fleet_known_hosts >/dev/null
      fleet_event init "machine=$machine peer=$me"
      printf '%s\t%s\n' "$machine" "$me"
      ;;
    id)
      fleet_need_id
      case ${1:-} in
        # What the operator carries to the joining machine alongside the code.
        --host-key) fleet_host_pub; [ -n "$(fleet_host_pub)" ] ||
          { echo "agents: this machine has no ssh host key (/etc/ssh/ssh_host_*_key.pub)" >&2; return 1; } ;;
        '') printf '%s\t%s\n' "$(fleet_self_machine)" "$(fleet_self_id)" ;;
        *) fleet_die "unknown option: $1" ;;
      esac
      ;;
    invite)
      fleet_need_id; ttl=900; want=
      while [ $# -gt 0 ]; do case $1 in
        --ttl) ttl=$2; shift 2 ;; --peer) want=$2; shift 2 ;; *) fleet_die "unknown option: $1" ;; esac; done
      [ -n "$want" ] || echo "agents: unbound code — the peer will land in 'pending' and still needs approval" >&2
      ihk=$(fleet_host_pub)
      if [ -n "$ihk" ]; then
        echo "agents: carry this host key to the other machine too: --host-key '$ihk'" >&2
      fi
      fleet_invite "$ttl" "$want"
      ;;
    join|pair)
      fleet_need_id
      t=tailscale; [ "$verb" = pair ] && t=ssh
      addr= user= home= code= hostkey= jport= jid=
      while [ $# -gt 0 ]; do case $1 in
        --to) addr=$2; shift 2 ;; --user) user=$2; shift 2 ;;
        --port) jport=$2; shift 2 ;;
        --ssh-identity) jid=$2; shift 2 ;;
        --home) home=$2; t=exec; shift 2 ;; --code) code=$2; shift 2 ;;
        --host-key) hostkey=$2; shift 2 ;;
        --host-key-file) hostkey=$(cat "$2"); shift 2 ;;
        --transport) t=$2; shift 2 ;; *) fleet_die "unknown option: $1" ;; esac; done
      [ -n "$addr" ] || [ -n "$home" ] || fleet_die "usage: agents fleet $verb --to <address> [--user u] [--port n] [--code c] [--host-key <line>]"
      [ "$verb" = pair ] && [ -z "$code" ] && fleet_die "pairing requires --code (mint one with: agents fleet invite --peer <peerid>)"
      jtmp=$(mktemp -d "${TMPDIR:-/tmp}/n2j.XXXXXX")
      fleet_enroll_request "$t" "$addr" "$user" "$home" "$code" "$hostkey" "$jport" "$jid" > "$jtmp/rep" || { rm -rf "$jtmp"; return 1; }
      fleet_record_reply "$jtmp/rep" "$t" "$addr" "$user" "$home" "$code" "$jport"
      jrc=$?
      rm -rf "$jtmp"
      return $jrc
      ;;
    pending)
      fleet_need_id
      for d in "$fleet_root/pending"/*; do [ -d "$d" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$(fleet_meta "$d" peer)" "$(fleet_meta "$d" machine)" \
          "$(fleet_meta "$d" transport)" "$(fleet_meta "$d" requested_at)"; done
      ;;
    approve)
      fleet_need_id; [ -n "${1:-}" ] || fleet_die "usage: agents fleet approve <peerid> [--host-fp <fp>] [--no-host-key]"
      apid=$1; shift; ahfp=; anohost=
      while [ $# -gt 0 ]; do case $1 in
        --host-fp) ahfp=$2; shift 2 ;; --no-host-key) anohost=nohost; shift ;;
        *) fleet_die "unknown option: $1" ;; esac; done
      set -- "$apid"
      fleet_approve "$1" "$(fleet_self_id)" "$ahfp" "$anohost" || return 1
      # The approval is recorded either way; the callback is best-effort
      # because the joiner may be offline. But "best-effort" must not mean
      # "invisible": if it did not land, the joiner still believes it is
      # pending, and the operator needs to know to tell it to re-run `join`.
      if fleet_notify_approved "$1"; then ansent=notified; else
        ansent=unreachable
        echo "agents: approved $1, but could not tell it (offline?) — re-run 'agents fleet join' there, or 'agents fleet approve' again once it is reachable" >&2
      fi
      printf 'approved\t%s\t%s\n' "$1" "$ansent"
      ;;
    deny)
      fleet_need_id; [ -n "${1:-}" ] || fleet_die "usage: agents fleet deny <peerid>"
      dnrc=0; fleet_deny "$1" || dnrc=$?
      [ "$dnrc" = 0 ] || [ "$dnrc" = 3 ] || return "$dnrc"
      printf 'denied\t%s\n' "$1"
      if [ "$dnrc" = 3 ]; then
        echo "agents: $1 is denied but its inbound ssh grant could not be removed — delete the line tagged n2-fleet:$1 from $(fleet_authkeys)" >&2
        return 1
      fi
      return 0
      ;;
    revoke)
      fleet_need_id; prop=0; rvid=
      while [ $# -gt 0 ]; do case $1 in --propagate) prop=1; shift ;; *) rvid=$1; shift ;; esac; done
      [ -n "$rvid" ] || fleet_die "usage: agents fleet revoke [--propagate] <peerid>"
      rvrc=0; fleet_revoke "$rvid" || rvrc=1
      printf 'revoked\t%s\n' "$rvid"
      [ "$rvrc" = 1 ] && echo "agents: $rvid is revoked here but its inbound ssh grant could not be removed — delete the line tagged n2-fleet:$rvid from $(fleet_authkeys), or rerun \`agents fleet reconcile\` once that file is writable" >&2
      if [ "$prop" = 1 ]; then
        rvpf=$(mktemp "${TMPDIR:-/tmp}/n2rv.XXXXXX")
        printf 'peer=%s\n' "$rvid" > "$rvpf"
        fleet_broadcast revoke "$rvpf" | sed 's/^/propagate\t/'
        rm -f "$rvpf"
      fi
      [ "$rvrc" = 1 ] && return 1
      return 0
      ;;
    discover) fleet_need_id; fleet_discover ;;
    reconcile)
      fleet_need_id; rcrc=0; fleet_reconcile || rcrc=1
      # Reconnecting is exactly when replication is owed, so a reconcile also
      # runs one automatic sync round. --no-sync exists for the revocation-only
      # case; it is opt-out because forgetting to sync is the failure mode.
      rcsync=1
      while [ $# -gt 0 ]; do case $1 in --no-sync) rcsync=0; shift ;; *) shift ;; esac; done
      # Interval 0: reconcile is the operator saying "I have been away", so
      # every reachable peer is due by definition, not merely the ones whose
      # timer happened to expire.
      [ "$rcsync" = 1 ] && sync_ready 2>/dev/null &&
        sync_tick 0 2>/dev/null | sed 's/^/sync\t/'
      [ "$rcrc" = 1 ] && echo "agents: a revoked peer still holds an inbound ssh grant on this machine — see the revoked-grant-not-removed lines above; rerun \`agents fleet reconcile\` once $(fleet_authkeys) is writable" >&2
      return $rcrc
      ;;
    rehost)
      fleet_need_id; rhp=; rhk=; rhann=0
      while [ $# -gt 0 ]; do case $1 in
        --announce) rhann=1; shift ;;
        --host-key) rhk=$2; shift 2 ;;
        --host-key-file) rhk=$(cat "$2"); shift 2 ;;
        *) rhp=$1; shift ;; esac; done
      if [ "$rhann" = 1 ]; then
        rhh=$(fleet_host_pub)
        [ -n "$rhh" ] || fleet_die "this machine has no ssh host key to announce"
        rhpf=$(mktemp "${TMPDIR:-/tmp}/n2rh.XXXXXX")
        printf 'host=%s\n' "$rhh" > "$rhpf"
        fleet_broadcast rehost "$rhpf" | sed 's/^/announce\t/'
        rm -f "$rhpf"
      else
        [ -n "$rhp" ] && [ -n "$rhk" ] ||
          fleet_die "usage: agents fleet rehost --announce | agents fleet rehost <peerid> --host-key <line>"
        rhd=$(fleet_peer_dir "$rhp"); [ -d "$rhd" ] || fleet_die "unknown peer: $rhp"
        printf '%s\n' "$rhk" | fleet_pin_host "$rhd" "$(fleet_meta "$rhd" address)" ||
          fleet_die "--host-key is not a valid known_hosts line"
        fleet_meta_set "$rhd" host_fp "$(fleet_host_fp "$rhd/host.pub")"
        fleet_known_hosts >/dev/null
        fleet_event rehost "peer=$rhp new=$(fleet_host_fp "$rhd/host.pub") by=operator"
        printf 'rehosted\t%s\t%s\n' "$rhp" "$(fleet_host_fp "$rhd/host.pub")"
      fi
      ;;
    route)
      fleet_need_id; rtp=; rtt=; rtaddr=; rtport=; rtuser=; rthome=; rtcmd=; rthk=
      while [ $# -gt 0 ]; do case $1 in
        --transport) rtt=$2; shift 2 ;;
        --address) rtaddr=$2; shift 2 ;;
        --port) rtport=$2; shift 2 ;;
        --user) rtuser=$2; shift 2 ;;
        --home) rthome=$2; shift 2 ;;
        --command) rtcmd=$2; shift 2 ;;
        --host-key) rthk=$2; shift 2 ;;
        --host-key-file) rthk=$(cat "$2") || fleet_die "--host-key-file is not readable: $2"; shift 2 ;;
        -*) fleet_die "unknown option: $1" ;;
        *) [ -n "$rtp" ] && fleet_die "route takes one peer id (got $rtp and $1)"; rtp=$1; shift ;;
      esac; done
      [ -n "$rtp" ] || fleet_die "usage: agents fleet route <peerid> [--transport t] [--address a] [--port n] [--user u] [--home p] [--command c] [--host-key <line>|--host-key-file <f>]"
      fleet_route "$rtp" "$rtt" "$rtaddr" "$rtport" "$rtuser" "$rthome" "$rtcmd" "$rthk" || return 1 ;;
    roster)
      fleet_need_id; [ -n "${1:-}" ] || fleet_die "usage: agents fleet roster <peerid>"
      fleet_call "$1" roster || return 1 ;;
    peers)
      fleet_need_id; probe=1
      case ${1:-} in --porcelain) shift ;; --no-probe) probe=0; shift ;; esac
      for d in "$fleet_root/peers"/*; do [ -d "$d" ] || continue
        pid=$(fleet_meta "$d" peer)
        if [ "$pid" = "$(fleet_self_id)" ]; then reach=self
        elif [ "$probe" = 1 ]; then reach=$(fleet_reach "$pid")
        else reach=$(fleet_peer_state "$pid"); fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$(fleet_meta "$d" machine)" \
          "$(fleet_meta "$d" transport)" "$(fleet_peer_state "$pid")" "$reach"; done
      ;;
    ping)
      fleet_need_id; [ -n "${1:-}" ] || fleet_die "usage: agents fleet ping <peerid>"
      fleet_call "$1" ping || return 1 ;;
    send)
      fleet_need_id; pid=${1:-}; shift 2>/dev/null || true
      v=; pf=/dev/null
      while [ $# -gt 0 ]; do case $1 in --verb) v=$2; shift 2 ;; --payload-file) pf=$2; shift 2 ;; *) fleet_die "unknown option: $1" ;; esac; done
      [ -n "$pid" ] && [ -n "$v" ] || fleet_die "usage: agents fleet send <peerid> --verb <verb> [--payload-file f]"
      fleet_call "$pid" "$v" "$pf" || return 1 ;;
    status)
      if ! fleet_have_identity; then echo "fleet\tuninitialized"; return 0; fi
      printf 'self\t%s\t%s\n' "$(fleet_self_machine)" "$(fleet_self_id)"
      cmd_fleet peers "$@"
      for d in "$fleet_root/pending"/*; do [ -d "$d" ] || continue
        printf 'pending\t%s\t%s\n' "$(fleet_meta "$d" peer)" "$(fleet_meta "$d" machine)"; done
      ;;
    sync) cmd_fleet_sync "$@" ;;
    tools) cmd_fleet_tools "$@" ;;
    task) cmd_fleet_task "$@" ;;
    serve) fleet_serve ;;
    help|-h|--help) fleet_usage ;;
    *) fleet_usage >&2; fleet_die "unknown fleet verb: $verb" ;;
  esac
}
