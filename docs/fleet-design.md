> Historical design record recovered from draft PR #3. For the current-main QA
> spike, deployment instructions, provider evidence and limitations, see
> [fleet-spike.md](fleet-spike.md) and [fleet authentication](fleet-authentication.md).
> Some vendor observations below predate main.

# Fleet design — identity, enrollment, transport

Status: implementation in progress (issue #1, task `transport`).
This document is the interface contract for the later fleet tasks (`sync`,
`execution`, `native-ui`). Change it in the same commit that changes behavior.

## Constraints that fixed the design

* `agents` is POSIX `sh` and ships as one file plus sourced adapter tables
  (`vendors.sh`). Fleet code follows that shape: `fleet.sh` is a sourced
  library, `agents fleet <verb>` is the user surface, and the tray shells out
  to it. No new runtime dependency (no jq, no Python, no Node) — everything
  uses tools present on a stock macOS: `ssh`, `ssh-keygen`, `base64`, `awk`.
* No required central hub. Every enrolled Mac holds the full roster and can
  approve, dispatch and serve. Records are append-only and self-authenticating,
  so any peer can replay them to any other peer.
* Nothing may weaken SSH host verification. We never pass
  `StrictHostKeyChecking=no`; we *pin* the peer host key at pairing time into a
  fleet-private `known_hosts`.

## Identity

Each machine holds one Ed25519 **fleet identity key**, separate from the user's
personal SSH keys:

    ~/.n2-agents/fleet/identity/id_ed25519       (0600, never leaves the machine)
    ~/.n2-agents/fleet/identity/id_ed25519.pub
    ~/.n2-agents/fleet/identity/machine          machine id, e.g. seths-mac-mini

The **peer id** is the SSH key fingerprint (`SHA256:…`) of that public key. It
is the only thing that authorizes a peer; hostnames, Tailscale membership and
IP addresses are routing hints and are never treated as authorization.

Signing and verification use OpenSSH's signature mode
(`ssh-keygen -Y sign|verify`, namespace `n2-agents-fleet`) against an
allowed-signers file generated from the roster. macOS ships OpenSSH ≥ 8.2, so
this needs no install. Payload signing is over the exact bytes transmitted.

## Roster (durable local fleet state)

    ~/.n2-agents/fleet/
      identity/            this machine's key + machine id
      peers/<peerid>/      one directory per known peer
        meta               key=value record (see below)
        key.pub            the peer's fleet identity public key
        host.pub           the peer's SSH *host* key line (pinned at pairing)
      pending/<peerid>/    enrollment requests awaiting approval
      revoked              append-only list of revoked peer ids + timestamp
      known_hosts          fleet-private pinned host keys (generated from peers)
      allowed_signers      generated from peers/*/key.pub
      events.log           append-only local event journal

`meta` is line-oriented `key=value` (values are never secrets):

    peer=SHA256:…            fingerprint of the fleet identity key
    machine=seth-webster-m4  human name, advisory only
    transport=tailscale|ssh|exec
    address=seth-webster-m4  ssh destination (tailscale MagicDNS name or host)
    user=sethwebster         ssh login user
    port=22                  ssh port, optional; omitted means the ssh default
    command=agents           remote command used to reach `agents fleet serve`
    state=approved|pending|revoked
    approved_at=<epoch>
    added_by=SHA256:…        peer id that approved it (self for the founder)

State transitions are one-way into `revoked`; a revoked peer id can never be
re-approved under the same key, which is what makes removal meaningful.

## Enrollment

Two paths, both of which bind the peer's identity key before any profile or
secret is exchanged.

**Tailscale (preferred).** The joining machine runs `agents fleet join`, which
prints a request containing its peer id, machine name, Tailscale address and
host key. An already-enrolled machine runs `agents fleet approve <peerid>`.
Being reachable on the tailnet grants nothing: an unapproved peer that connects
is rejected by `agents fleet serve` before any request body is interpreted.

**Direct SSH (outside Tailscale).** `agents fleet pair --code <code>` on both
sides. The pairing code is a one-time high-entropy secret with a TTL; the
request is signed by the joining key and carries an HMAC-style tag derived from
the code over the joining peer id and host key, so a code alone with a
different identity is rejected (`wrong-identity`), and a code is consumed on
first successful use.

Approval is never implicit: the founder machine (`agents fleet init`) is the
only self-approved peer.

## Transport

A request is a signed envelope written to the peer's `agents fleet serve`
process:

    N2FLEET/1
    from=<peerid>
    to=<peerid>|any
    verb=<ping|status|roster|…>
    nonce=<32 hex>
    ts=<epoch>
    len=<bytes>
    --
    <payload bytes>
    --sig--
    <ssh signature, armored>

`serve` verifies, in this order, before acting: envelope shape → signature over
the header+payload bytes → sender is in the roster → sender is `approved` (not
`pending`, not `revoked`) → `to` matches this peer or is `any` → timestamp
inside the freshness window → nonce unseen. Any failure returns a one-line
`ERR <reason>` and is journaled; nothing else is read or returned.

Three carriers implement the same envelope so tests exercise the real
verification path:

| carrier | reach | used for |
|---|---|---|
| `tailscale` | `ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<fleet known_hosts> user@magicdns agents fleet serve` | default |
| `ssh` | same, address is a plain host | paired peers off-tailnet |
| `exec` | run `agents fleet serve` as a local child process with the peer's `HOME` | multi-peer tests on one machine |

Host verification is never relaxed for any carrier. The ssh options are built
in one place, `fleet_ssh_run` (`fleet_ssh_opts` renders the same list without
dialing, so tests audit the flags that actually run): `StrictHostKeyChecking=yes`, a fleet-private
`UserKnownHostsFile` (the user's personal `known_hosts` is neither read nor
written), `BatchMode=yes`, `IdentitiesOnly=yes` with the fleet identity key,
and `HostKeyAlias=<address>`. The alias matters because pins are keyed to the
address we dial (`fleet_pin_host`): without it, a peer reached on a non-default
port or under a name different from its own `hostname` would find no matching
entry, which is a pin that verifies nothing.

### The enrollment hop

Approval is what installs a peer's fleet key into this account's
`authorized_keys` (`fleet_authorize`). That makes the *first* contact a
chicken-and-egg problem: pinning `IdentitiesOnly` to the fleet key on the
enrollment hop would require the key that enrollment is trying to obtain.
The enroll request is therefore marked `bootstrap=1` on its throwaway peer
directory, and only that hop omits `IdentitiesOnly`/`-i`, letting ssh
authenticate with the operator's **existing** access to the machine — which is
the out-of-band relationship that justifies enrolling it at all. Everything
else is unchanged on that hop: `StrictHostKeyChecking=yes`, the fleet-private
`known_hosts`, `BatchMode=yes`. Nothing is trusted because it answered; the
reply still has to carry the bound-code proof before it is recorded approved.

`join`/`pair` therefore accept two operator-supplied knobs that only affect
that hop. `--port <n>` names the responder's sshd port; it is validated by
`fleet_valid_port`, carried in the enroll payload as `port=` (advertised by the
joiner as `N2_FLEET_SELF_PORT`), re-validated on the responder before it can
reach an ssh argv, and recorded on both durable peer records — without it a
machine whose sshd is not on 22 cannot be enrolled at all, and a peer that
enrolled on a non-default port would be stranded on 22 for every later hop.
`--ssh-identity <key>` names the operator credential to bootstrap with:
`fleet_ssh_run`'s bootstrap argument is empty (use the fleet key), `1` (use the
operator's default identities) or a key path (pin `IdentitiesOnly` to exactly
that key). It exists because OpenSSH expands `~` from the passwd entry rather
than `$HOME`, so an operator whose bootstrap credential is not a default
identity has no other way to name it. Host verification, `BatchMode` and the
fleet-private `known_hosts` are identical in all three branches.

### Two doors, and which one owes a callback

`join` (no code) files the joiner in `pending` and the operator runs `approve`
on the responder; the approval travels back as a one-shot `enrolled` callback
over ssh, which means the **joiner** must be reachable at approve time. When it
is not, `approve` still records the approval locally, prints `unreachable` and
tells the operator to re-run `join` there or re-approve later — the joiner
keeps believing it is pending, which is the honest state, not a failure that is
swallowed. `pair --code` with a code bound to a fingerprint is answered
`approved` in the same round trip with an `rtag` proving the responder holds the
secret, so nothing is owed in the other direction and a joiner behind NAT (or
simply running no sshd) can still complete enrollment. Section 28 of
`scripts/test-fleet.sh` drives both doors against a real user-level sshd whose
`authorized_keys` starts out holding only the operator bootstrap key.

Approval is also symmetric. When a responder auto-approves us on a bound code,
`fleet_record_reply` runs `fleet_authorize` for *it* as well, otherwise the
trust is one-way and the approved peer could never call back (`enrolled`,
`ping`, revocation propagation) over ssh.

### Routing fields are argv, and are validated as such

`address`, `user` and `port` are written from a peer's own enroll reply, and
they end up in ssh's argument list. Expanded unquoted, a value with whitespace
splits into several arguments and a leading `-` is read as an option — so a
peer could name itself `-oProxyCommand=…` and run a command on *our* machine.
`fleet_carry` rejects those fields outright (`ERR bad-address` / `bad-user` /
`bad-port`) rather than quoting and hoping, builds ssh's argv positionally, and
puts `--` before the destination. `command` is local operator configuration
(it may legitimately be a fragment such as `env HOME=… agents`) and is checked
only for emptiness and embedded newlines.

A refused enrollment exits non-zero. `join`/`pair` used to end on `rm -rf`, so
cleanup's status replaced the refusal's and `if agents fleet pair …` enrolled
nothing while reporting success; the status is now captured and returned.

The `exec` carrier is a test convenience, not a second protocol — it changes
only how bytes reach `fleet serve`. To keep that claim honest rather than
assumed, `scripts/test-fleet.sh` section 23 also drives the real `ssh` carrier
against a throwaway user-level `sshd` on loopback (its own host key, its own
`authorized_keys`, no root, no system configuration touched). It asserts that a
matching pin carries a signed round trip, that a host key which does not match
the pin is refused as `unreachable` before any fleet message is exchanged, that
the refusal writes nothing to the user's personal `known_hosts`, that
re-pinning the true key restores service, and that an ssh identity the server
does not authorize cannot open the transport even when the host pin is correct.
Transport authentication and fleet authentication are separate gates and both
must pass.

`exec` changes only *how bytes reach* `serve`; the signature and roster checks
are identical, so a test peer cannot pass a check a real peer would fail.

## CLI surface (stable for later tasks)

    agents fleet init [--machine <name>]        become the founder peer
    agents fleet id [--host-key]                peer id, or the host key line
                                                the operator carries out of band
    agents fleet join --to <addr> [--user u]    request enrollment (tailscale)
    agents fleet pair --code <code> --host-key <line> …   enrollment (direct ssh)
    agents fleet invite [--ttl <secs>]          mint a one-time pairing code
    agents fleet pending                        list requests awaiting approval
    agents fleet approve <peerid> [--host-fp <fp>] [--no-host-key]
    agents fleet deny <peerid>
    agents fleet revoke [--propagate] <peerid>
    agents fleet discover                       learn peers-of-peers (pending)
    agents fleet reconcile                      re-sync roster + revocations
                                                after a spell offline
    agents fleet rehost --announce              publish a rotated ssh host key
    agents fleet rehost <peerid> --host-key <line>   re-pin a peer out of band
    agents fleet roster <peerid>                read a peer's roster
    agents fleet peers [--porcelain]            roster + reachability
    agents fleet ping <peerid>                  signed round trip
    agents fleet status [--porcelain]           local + peer status
    agents fleet send <peerid> --verb v [--payload-file f]   raw signed request
    agents fleet serve                          stdio responder (remote end)
    agents fleet help                           the verb table

`--porcelain` emits tab-separated records, the convention the tray already
consumes (`agents porcelain`).

Every verb above is offered by the zsh, bash and fish completions, and
`scripts/test-fleet.sh` fails if the three surfaces — the verb table, the
dispatcher and the completions — ever drift apart.

## Host key pinning

Fleet ssh never consults the user's personal `known_hosts`; it uses
`$fleet_root/known_hosts`, rebuilt from the roster on every use, with
`StrictHostKeyChecking=yes`. A peer with no pinned host key therefore cannot
be reached at all — the design fails closed rather than trusting on first use.

Where the pin comes from decides how much it is worth:

- **Paired (direct SSH).** The enroll request's pairing tag is computed over
  the invite secret, the peer id *and* the host line, so a host key that was
  swapped in flight fails the tag and the request is refused outright.
- **Tailscale.** There is no pairing code, so the host line is self-asserted.
  Approval is the checkpoint: `fleet approve` refuses an ssh/tailscale peer
  that arrived with no host key, and `--host-fp <fp>` makes the operator's
  out-of-band fingerprint a precondition. `--no-host-key` is the explicit
  escape hatch and records `host_fp=unpinned` on the peer, so an unverified
  pin is visible in the roster rather than indistinguishable from a checked
  one.

### The first hop

Pinning from the roster leaves the enrollment hop itself unpinned: the joiner
has no peer record for the machine it is about to dial. Trust-on-first-use
would undo everything above, so the joiner refuses instead. `join`/`pair`
take `--host-key '<line>'` (or `--host-key-file`), which the operator reads
off the other machine with `agents fleet id --host-key` and carries with the
pairing code; `fleet invite` prints that line next to the code for exactly
this reason. It is parsed by the same `fleet_host_line` filter, re-keyed to
the address actually being dialled — not to the name inside the line — and
written to `$fleet_root/bootstrap/host.pub`, which `fleet_known_hosts` folds
in. Without it, an ssh/tailscale enrollment stops before any bytes leave.

That bootstrap key is also what becomes the peer's *lasting* pin. The
enroll response carries a self-reported `host=` line, built by
`fleet_host_pub` from `/etc/ssh/ssh_host_*`, and a machine whose sshd runs a
non-default `HostKey` (a per-instance sshd, a non-standard install) cannot
name the key it is actually serving — so the self-report is both the weaker
claim and, there, the wrong one. Letting it overwrite the operator's key
would also let a peer substitute a different host key on every hop after
enrollment, i.e. the operator-verified pin quietly disappearing. So
`$fleet_root/bootstrap/host.pub` wins when it exists, and the responder's
`host=` line is used only when the enrollment had no out-of-band key at all
(the exec carrier, and a tailscale `join` that defers verification to
`approve --host-fp`). The bootstrap directory is wiped at the start of every
enrollment, so no earlier operator key can leak into a later one.

## Inbound authorization (authorized_keys)

A peer reaches `agents fleet serve` over ssh with its *fleet* key, so approval
is also where that key is granted inbound access:
`fleet_approve` -> `fleet_authorize` appends

    restrict,command="agents fleet serve" <peer key> n2-fleet:<peerid>

to `$HOME/.ssh/authorized_keys` (override with `N2_FLEET_AUTHORIZED_KEYS`;
`N2_FLEET_NO_AUTHORIZED_KEYS=1` opts out for operators who provision it
themselves). `restrict` plus the forced command keeps the grant to that one
verb — no ports, no agent, no pty, no other command. `deny` and `revoke` call
`fleet_deauthorize`, which removes only the line tagged with that peer id, so
revocation actually closes the door instead of merely forgetting the peer.
Exec-carrier peers are never granted anything.

### The joiner's pending-time grant, and the one-shot callback marker

The approval-only path (the acceptance criterion "enroll a Mac through
Tailscale with approval") has no pairing code: the joiner dials, lands
`pending`, and a human runs `approve` on the far machine. That approval
answers with an `enrolled` callback over ssh, so the joiner learns its fate
without polling — which means the joiner must have authorized the responder's
key *before* it is approved here, or the message that would approve it can
never arrive. `fleet_record_reply` therefore calls `fleet_authorize` for the
machine it dialled in both outcomes.

That grant is a callback channel, not trust, and three things bound it:

- it is `restrict,command="agents fleet serve"`, the same line as any peer;
- `fleet_verify` refuses every verb but `enroll`/`enrolled` from a peer that
  is not approved locally (`ERR not-approved`), so the channel carries one
  sentence and nothing else;
- `enrolled` additionally demands a `joined/<peer slug>` marker, written only
  when *we* dialled that machine and consumed by `fleet_handle_enrolled`.

The marker is armed only while a callback is actually owed. A bound-code join
is answered `approved` on the spot, so no `enrolled` is coming; arming it
there would leave a one-shot capability nobody was going to spend, valid for
the life of the machine. `fleet_record_reply` disarms in that case, which also
clears a marker left over from an earlier attempt at the same peer.
`fleet_revoke`/`fleet_deauthorize` withdraw the inbound grant either way.

## Approval is validated before it is committed

`fleet_approve` checks the key fingerprint, transport and host key against the
record *where it still lives*. An approval that fails therefore leaves the
pending request intact, so the operator can go verify the fingerprint and
re-run with `--host-fp`, or `deny` it. (Committing first meant a refusal
silently destroyed the request.)

A supplied host line is authority over host verification, so it is parsed,
not copied: `fleet_host_line` keeps at most one line and only in the shape
`<host> <keytype> <base64>`. This is what stops a marker line such as
`@cert-authority *`, which would otherwise let an enrolling peer act as a
certificate authority for every host the machine later ssh'd to — fleet
member or not. The filter runs at intake and again when `known_hosts` is
rebuilt, so a record written by an older build is also neutralised.

Rotation is handled, not deferred. An approved peer that legitimately
reinstalls its OS keeps its fleet identity key but breaks every host pin its
peers hold, and it cannot be dialled to fix it — so it dials out instead:
`agents fleet rehost --announce` sends the new host line over a message signed
by the identity key those peers already trust, and `fleet_handle_rehost` moves
the pin (`test-fleet.sh` section 22). Authentication rides the fleet signature,
never the ssh host key, so this is not trust-on-first-use: without the identity
key an attacker cannot move a pin. The operator can also re-pin locally with
`agents fleet rehost <peer> --host-fp <fp>` after checking the fingerprint
out of band.

### Every rejection has a live-ssh witness

The exec carrier (`--transport exec`, used by most of the suite) runs the same
`fleet_serve` the ssh carrier reaches, so it is honest about the fleet layer —
but it proves nothing about whether a real ssh hop can smuggle something past
that layer. Each of the five enrollment states in the acceptance wording is
therefore also exercised through the user-level `sshd` in `test-fleet.sh`
section 31, so no rejection path is carrier-only:

| state | live-ssh assertion (section 31) |
| --- | --- |
| unapproved | `the joiner's fleet key is not preinstalled on the server`, and the bootstrap join lands `pending` with no `n2-fleet:` grant |
| approved | `bootstrap hop enrolls over the operator's own access` → `approval installed the joiner's fleet key` |
| paired | `a bound code pairs over real ssh`, both sides recording `approved` in the one hop |
| wrong-identity | `a code bound to another peer is refused over real ssh`; the refusal names `wrong-identity`, the impersonator gains no roster entry, no `authorized_keys` grant, and no working transport afterwards |
| revoked | `revocation removed the inbound ssh grant` → `a revoked peer can no longer open the transport` |

The wrong-identity case deliberately hands the impersonator the *operator's*
bootstrap ssh key, so the ssh door really does open for it. What refuses it is
`fleet_verify`'s enroll branch comparing the fingerprint of the key carried in
the payload against the claimed `from`, then the bound code's own peer
binding — not the transport. Reachability is not authorization at either
layer, and this is the test that says so over real ssh rather than a pipe.

The replay in the same block also confirms the blast radius of a refused
attempt is zero: the peer the code was actually minted for is still `approved`
afterwards, so a failed impersonation cannot be used to knock a legitimate
member out of the roster.

## Discovery and revocation without a hub

Discovery is a pull, never a push. `fleet discover` asks every *approved* peer
for its roster (verb `roster`) and files each approved entry it does not
already know into `pending/`. Three properties make that safe to run on a
schedule:

* A neighbour's trust is not our trust. A discovered peer lands in `pending`
  and is unreachable until the operator runs `fleet approve`, so reachability
  plus a referral still never equals enrollment.
* The roster reply carries the peer's **public** key. `fleet_approve` refuses
  it unless `ssh-keygen -lf` of that key equals the peer id it was advertised
  under, so a lying introducer cannot bind a key it holds to someone else's id.
* Discovery carries identity, not a route. The operator supplies reachability
  (address/user, or `home` for the `exec` test carrier) when approving.

Revocation is local first and propagated second. `fleet revoke <id>` always
takes effect here: the peer directory is removed and the id is appended to
`revoked`, which `allowed_signers` and `known_hosts` are then regenerated
from, so a revoked key can neither sign to us nor be dialled by us.
`--propagate` additionally sends a signed `revoke` to the remaining approved
peers. The receiving side (`fleet_handle_revoke`) only accepts it from an
already-approved sender, refuses to revoke itself or the sender, and does
**not** re-broadcast — one hop per operator action, so a cycle in the peer
graph cannot loop. Propagation is therefore an accelerator for a roster the
other machines could also reach themselves, never the authority: a peer that
was offline during the fan-out keeps a stale approved record until it catches
up. Catching up is automatic rather than manual — `agents fleet reconcile`
pulls each approved neighbour's `revocations` list on reconnect and adopts
anything new, under the same trust rule as the push path (`test-fleet.sh`
section 21). The deliberate cost of having no hub is the delay, not an
operator errand.

The receiver is also honest about a revocation it could not fully carry out.
`fleet_revoke` always removes the roster entry and records the id, but if the
inbound `authorized_keys` grant survives the rewrite (read-only file, a
directory it cannot stage in) it returns non-zero; `fleet_handle_revoke` turns
that into `ERR revoked-grant-not-removed <peer> on <machine>`, so the hop shows
as `fail` in the `--propagate` output and the operator learns which machine
still has an open ssh door instead of being told the fleet is closed.
`fleet_reconcile` reports the same case as `revoked-grant-not-removed`. Both
paths are covered by `test-fleet.sh` section 35, including the retry that
succeeds once the file is writable.

Reporting it once is not enough on the pull path, because the second half of
the revocation is *local* work: once the id is on the `revoked` list, every
later pass short-circuits before it reaches `authorized_keys`, and the peer
would keep a working inbound ssh door forever while being refused at the fleet
layer. So a failed grant removal is written down in `fleet/revoke-pending`
(`fleet_revoke_pending_add`; `fleet_deny` records its failures there too).
`fleet_reconcile` retries that ledger first — before it talks to any neighbour,
since the grant is on this machine — printing `revoked-grant-removed <peer>
retry` when it finally closes, clearing the entry, and logging a
`revoke-cleanup` event. While anything remains stuck, `agents fleet reconcile`
prints `revoked-grant-not-removed <peer> pending` and **exits non-zero** with a
line naming the file to fix, matching the local `revoke` CLI's status. Section
23 covers the whole pull-path cycle: adopt-and-fail (non-zero), the surviving
grant, the durable roster removal, the retry that removes it, the cleared
ledger, the cut-off peer, and a settled third pass that is quiet and zero.

That ledger only fills if the failure is *detected*, and detecting it turns on
a distinction `grep` does not make for you: a non-zero `grep` means "no match"
(1) **or** "could not read the file" (2). Treating the second as the first is
how a revocation reports success over a grant that is still installed — an
unreadable `authorized_keys` looks exactly like one with nothing to remove.
`fleet_grant_state <authkeys> <peerid>` is the single place that reads a grant:
`0` present, `1` absent, `2` unreadable. `fleet_deauthorize` consults it before
the rewrite (unreadable → named failure, ledger entry) and again after it
(unreadable → the removal is *not* confirmed, so it fails), and the rewrite
itself refuses `grep -v` statuses above 1 rather than accepting an empty result
— accepting one would truncate `authorized_keys` and silently drop every other
peer's grant. The temp file is created by an explicit `: >` first, because a
redirection that cannot open its target yields a shell status indistinguishable
from `grep -v`'s legitimate "every line matched".

The unwritable and unreadable halves are tested separately because they fail at
different points. `test-fleet.sh` sections 33–36 make the file (or its
directory) unwritable; section 37 makes it unreadable with `chmod 000` while
leaving the directory writable, so only the reads can fail. Section 24 also
keeps a second peer's grant in the same file: if the failed read were taken for
an empty result, the rewrite would remove the bystander's grant too, so the
test asserts it survives the failure *and* the later successful retry. Flipping
`fleet_grant_state`'s `2` case back to `1` — the original bug — turns 8 of its
16 assertions red.

### Keeping the verb surface from drifting

`agents fleet` publishes its verbs in three shell completions, in `fleet_usage`
and in the dispatcher. `test-fleet.sh` reads the list **out of `cmd_fleet`**
with `awk` rather than repeating it, and asserts each verb is documented and
completable in zsh, bash and fish. A hard-coded list in the test drifts the
moment a verb is added and the check silently stops covering it — which is
exactly what happened to `route`, dispatched and documented but missing from
all three completions until this check was made self-updating.

### What "no required hub" is tested to mean

`test-fleet.sh` section 32 is the strict version of that claim. Four peers,
each a real `agents` process with its own HOME, key and roster: `m1` and `m2`
enroll through `orig`, discover each other through it, and then `orig`'s home
directory is **deleted** — not moved aside, not merely unreachable. Its
identity key, roster and invite state no longer exist anywhere. With the
originator destroyed, the surviving pair must still:

1. complete a signed round trip and read each other's roster (`ping`, `roster`);
2. report the dead machine as `offline` in `fleet status` without that being
   fatal to the listing;
3. mint a bound invite and enroll a **fourth** machine (`m3`) that `orig` never
   met, over the pairing door;
4. let the other survivor learn `m3` hub-free via `discover`, still only as
   `pending`, so growth without a hub does not become trust without approval;
5. shrink the fleet again — `revoke --propagate` from a survivor, after which
   `m3` is refused.

Nothing in that sequence consults the originator, and no peer holds a role the
others lack. Sections 6, 13 and 14 cover the softer case (originator offline,
then back); 29 covers the case where it never comes back.

## Interfaces the later tasks build on

* `fleet_call <peerid> <verb> <payload-file>` — signed request/response; the
  only sanctioned way to talk to a peer. Returns payload on stdout, `ERR …` on
  failure.
* `fleet_broadcast <verb> <payload-file>` — best-effort fan-out to every
  approved peer; prints one result line per peer, never fails the caller when a
  peer is offline (that is the disconnect path, not an error).
* `fleet_verb_handler <verb>` — `serve` dispatches verified requests to
  `fleet_handle_<verb>`; `sync` and `execution` add handlers without touching
  the transport.
* `fleet_discover` — pull-based peer discovery; writes `pending/` records only.
* `fleet_event <kind> <detail>` — appends to `events.log`; the notification
  fan-out in `execution` and the tray read from it.

## Provider auth portability (research for the `sync` task)

Evidence gathered by inspecting the installed binaries and the on-disk state
they actually write, on 2026-09-21, so the `sync` task does not restart it.
Commands are recorded so each claim is re-checkable. **No credential value was
read, and none appears here, in `events.log`, in fixtures, or in any fleet
message header** — only file names, permission bits, sizes and JSON *key*
names.

### claude — keychain-first, file only when the keychain is unavailable

Binary: `/Users/sethwebster/.local/share/claude/versions/2.1.278`
(Mach-O arm64, Bun standalone, version string `2.1.278`).

    strings -n 8 "$CL" | grep -aoE '(Claude Code-credentials|\.credentials\.json|security (add|find|delete)-generic-password|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|CLAUDE_CONFIG_DIR|refresh_token|expiresAt)' | sort | uniq -c

    215 refresh_token      140 CLAUDE_CODE_OAUTH_TOKEN    70 CLAUDE_CONFIG_DIR
    180 expiresAt          139 ANTHROPIC_API_KEY          11 .credentials.json
      4 security find-generic-password      2 security delete-generic-password

Longer-string extraction shows the write path is literally
`security add-generic-password -U -a <account> -s <service> -X <payload>`,
fed through `security -i` on stdin when the JSON payload is small enough and
falling back to argv when it "exceeds security -i stdin limit". Reads go
through `security find-generic-password -a … -w -s …`, and failures surface as
`Failed to read API key from macOS keychain:`. Deletion uses
`security delete-generic-password`. There is a `secureStorage` module with a
`READ_FAILED` sentinel and a cross-process write lock (`.storage-write`,
`retries: 10`, `stale: 15000`), i.e. the credential store is treated as shared
mutable state *on one machine* and has no notion of a second machine.

What this means for the fleet:

* The material is an OAuth token set with `refresh_token` and `expiresAt`, not
  a static key. Copying it produces a *snapshot*; whichever machine refreshes
  first can invalidate the others' copy. Any sync of this provider must be
  modelled as last-refresh-wins with a conflict, not as idempotent file
  replication.
* On a default install the secret is **not in `CLAUDE_CONFIG_DIR` at all** — it
  is in the login keychain, which the existing profile-isolation mechanism does
  not isolate and a file-level sync cannot see. A `.credentials.json` under the
  config dir exists only on the non-keychain path.
* `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY` are read from the
  environment. A long-lived token or API key handed to the fleet through the
  environment *is* portable; an interactive keychain session is not, by the
  same evidence. **Supported sync target: env-supplied token/API key.
  Explicitly unsupported: transplanting an interactive keychain session.**

### codex — file-based token set under `CODEX_HOME`

`~/.codex/auth.json`, mode `-rw-------`, 4227 bytes. Top-level keys (values not
read): `auth_mode` (str), `OPENAI_API_KEY` (null on this machine), `tokens`
(object), `last_refresh` (str). The presence of `last_refresh` alongside a
`tokens` object is the same refresh-race shape as claude: portable as a file,
but two machines refreshing independently diverge. `config.toml` (32321 bytes)
is adjacent and is *configuration*, not credentials — the `sync` task should
treat those two paths differently.

### gemini — file-based OAuth, but not process-isolable

`~/.gemini/oauth_creds.json`, mode `-rw-------`, 1805 bytes, keys:
`access_token`, `scope`, `token_type`, `id_token`, `expiry_date`,
`refresh_token`. Also `~/.gemini/google_accounts.json` (52 bytes, world
readable) which is account identity, not a secret. The blocker is not the file
format: per `vendors.sh` gemini is a `swap` tier vendor — it reads a source
constant rather than an env var, so it cannot be isolated per process. It
remains the weakest sync candidate and the `sync` task should mark it
unsupported unless it first changes the isolation tier.

### opencode — one file, several providers inside it

`~/.local/share/opencode/auth.json`, mode `-rw-------`, 3788 bytes, top-level
keys are provider names (`openai`, `google`, `xai`, `opencode`), each an
object. A separate `mcp-auth.json` (1983 bytes) holds MCP server credentials.
Because one file multiplexes several providers, whole-file replication couples
unrelated providers' refresh state; per-key merge is required, and a
machine-specific exception must be expressible at the provider key, not only at
the file.

**Correction, from the shipped binary (2026-09-21).** opencode was labelled
`supported` on the strength of "it keeps one auth.json". That label was wrong,
and the wrongness is not cosmetic. `strings` on the installed binary shows the
resolver:

```js
function Y7(){ let $=QV.homedir(), Z=process.env.XDG_DATA_HOME;
  if(Z) return c8.join(Z,"opencode","auth.json");
  return c8.join($,".local","share","opencode","auth.json") }
```

The credential is resolved from `XDG_DATA_HOME`. N2 profile isolation repoints
`XDG_CONFIG_HOME` (`vendors.sh:vendor_env`) and nothing else, so **opencode's
credentials are machine-wide and shared by every profile**, and they sit
entirely outside the slot the sync walks. Two consequences, both now encoded:

1. `sync_auth_support opencode` returns `unsupported` — not `partial`, which
   asserts that replication is implemented — and `sync_auth_reason` names the
   data path and the config-only isolation, so `fleet sync auth list` says where
   the token actually lives instead of implying replication happens.
   `fleet sync auth enable opencode` is **refused** with that reason and exits
   non-zero. An accepted opt-in that carried nothing would be a false
   affordance: indistinguishable, from the operator's side, from a sync that is
   quietly broken. The refusal also means `sync_secret_shareable opencode` is
   false even if an opt-in line were planted by hand.
2. Replicating that file would be *worse* than not replicating it: because the
   path is not profile-isolated, one machine's Work credential would land on
   the other machine's every profile. Carrying opencode auth safely requires
   isolating `XDG_DATA_HOME` first, which is a change to the isolation tier and
   therefore out of this task's remit. Recorded as an open item, not done.

Verified by test: `scripts/test-sync.sh` section 23 asserts the matrix prints
neither `opencode	supported` nor `opencode	partial`, does print
`opencode	unsupported`, that the opt-in is refused non-zero with the reason,
that a refused opt-in is not recorded, and names both
`.local/share/opencode/auth.json` and `XDG_CONFIG_HOME`.

### State writes are locked

`sync/state` holds the per-peer agreed base and is updated by read-modify-write.
A pass against peer B runs concurrently with a pass against peer A — which is
exactly what a reconnect looks like — and the second writer used to rebuild from
a snapshot predating the first, silently dropping its rows. A lost base is not a
lost optimisation: the next pass reads the address as never-agreed, i.e. a
tombstone, which surfaces as a spurious pull or a spurious conflict. `sync_base_set`
now takes an `mkdir` lock (the only atomic test-and-set POSIX sh can rely on),
breaking a stale lock by age rather than by pid because the previous writer may
be on the far side of a crash. Covered by section 24, which runs two passes at
once and asserts both peers' rows survive and the follow-up pass is quiet.

### grok, cursor

Env-isolated config dirs; auth material lives inside the dir. Not inspected in
this pass — **unverified**, and the `sync` task must not assume the codex shape
applies.

### Rule this hands to the `sync` task

A copied credentials file is evidence of *file* portability and nothing more.
Before any provider is advertised as supporting fleet auth sync, the `sync`
task must show an actual authenticated call succeeding on the receiving machine
from synced state, and must state the refresh-conflict behavior it observed.
Providers that fail that bar are listed as unsupported with the reason, not
omitted. Synthetic secrets only in tests; redaction asserted, not assumed.

## Nonce reservation is atomic, and a grant that fails is not an approval

Two defects found by review, both in the "looks fine sequentially" family:

**Replay protection was a check followed by a write.** `fleet_seen_nonce` read
`seen/<nonce>`, then created it. Sequentially that is correct and the suite
proved it. Concurrently it is not: the same captured envelope delivered to
sixteen receivers at once had every one of them read *absent* and accept —
measured at 3, 3 and 2 acceptances across three trials. The reservation is now
the `mkdir` of the nonce entry itself, which the kernel grants to exactly one
concurrent caller; every loser is told `ERR replay`. Covered by
*replay: 16 concurrent deliveries accepted exactly once* (and its companion
asserting all 15 losers name `replay`), which runs sixteen real receiver
processes against one shared root.

**`fleet_authorize` swallowed every write failure.** Each failure path ended in
`return 0`, so an approval could print success while the peer's inbound ssh
grant was never installed — a peer that can never reach this machine, with
nothing said about it. Every failure now names itself on stderr, records an
`authorize-failed` event, and propagates: `fleet_approve` keeps the (durable)
approval decision but exits non-zero telling the operator to re-run after
fixing the grant file, and `fleet_record_reply` does the same for the join
path. Covered by section 33, which approves with the grant file pointed at an
unwritable path, then re-approves against a writable one to show the refusal
was the write and not approval itself.

A third item from the same review was a test defect, not a product one:
the "impersonator is not in the server roster" assertion compared against an
empty expected substring, which every string contains, so it could never fail.
It is now an explicit `grep -qF` on the roster.

---

# Profile replication and managed utilities (the `sync` task)

Decisions recorded before implementation, in the same spirit as the transport
section: the contract first, so `execution` and `native-ui` can build against
it. This section is written by the `sync` task; the transport interfaces it
consumes (`fleet_call`, `fleet_broadcast`, `fleet_verb_handler`, `fleet_event`)
are unchanged.

## What a syncable thing is

The unit is a **resource**, addressed by four fields and never by absolute path:

    <class>|<profile>|<vendor>|<relpath>

* `class` — `settings`, `skills`, `mcp`, `auth`, `tools`, or `profile`. The class decides
  policy (what merges, what may be excepted, what is a secret), so it is part
  of the address rather than inferred from the path.
* `profile` — a profile name as `agents` already resolves it (`Default`
  included). Profiles are the existing product concept; the fleet does not
  invent a second one.
* `vendor` — one of `$N2_VENDORS`, or `-` for resources that are not
  vendor-scoped.
* `relpath` — path **relative to the vendor's slot dir** as returned by
  `config_dir <profile> <vendor>`. Relative addressing is what lets a resource
  created on a machine whose slot is an adopted symlink into
  `~/.claude-profiles/<Name>` land correctly on a machine where the same slot
  is an ordinary directory.

Absolute paths never cross the wire. A received `relpath` that is absolute,
contains a `..` component, or resolves outside the destination slot is refused
before anything is written, and the refusal is journaled.

### A profile is a resource in its own right

The manifest originally spoke only about files, which made a profile invisible
as a thing: a profile with no files in scope yet had no address at all and
could not replicate, and deleting a synced profile read as "no files changed",
so the directory — and the profile in `agents list` — stayed on every receiver.

A profile therefore carries an **existence record**: class `profile`, vendor
`-`, relpath `.n2-profile`, a fixed body. The body is fixed so the record is
byte-identical on every machine and can never itself become a conflict; only
its presence or absence carries meaning. `sync_profile_marker` writes it lazily
when a manifest is built, so a profile made before the fleet existed, or by any
other path, gets one without profile creation having to know sync exists.

A tombstone for the record means "this profile is gone from the fleet", and it
removes the profile's vendor slots with it. That is the only place sync removes
a tree, so it is fenced on both sides (`sync_profile_addressable`, then
`sync_profile_remove`):

* `Default` is never addressed. It exists on every machine by definition, so
  replicating it is inert and a tombstone for it could only be wrong.
* `fleet` is never addressed. This machine's own fleet state — its identity,
  roster and grants — lives under the profile root and therefore turns up in
  `all_profiles`. Advertising it would hand one machine's identity to every
  peer, and its tombstone would delete the receiver's fleet state.
* The name must pass `valid_profile_name`, so a traversal cannot arrive dressed
  as a profile.
* A profile that is **active** for any vendor on the receiver is not deleted
  out from under a running agent. The local CLI refuses the same deletion; sync
  reports the failure rather than converging on a lie.
* A real directory is removed only if it resolves (`cd .. && pwd -P`) to
  exactly `<realpath of profile root>/<name>`.
* An **adopted** profile directory is a symlink into `~/.claude-profiles/`.
  The link is this machine's local decision about where the contents live, so
  only the link is removed; the adopted target is left alone.

The receiver's gate is what matters, because `fleet send --verb sync-put` lets
any approved peer put a hand-built envelope on the wire. Section 54 of
`scripts/test-sync.sh` sends exactly that: signed tombstones naming `fleet`,
`Default`, `..`, `x/..` and `.n2-agents`, each refused, with the receiver's
fleet state and profile root intact afterwards — and a positive control in the
same shape with a real profile name, which is accepted, so the refusals are
about the name and not about the path being closed.

## What syncs, and what deliberately does not

Replicating a whole config dir would replicate session transcripts, caches and
machine-local history — large, private, and meaningless on another machine. The
included set is an allowlist per class, not an exclude list:

| class | included | excluded and why |
| --- | --- | --- |
| `settings` | the vendor's own settings/config files (`settings.json`, `config.toml`, …) and agent settings | `projects/`, `history*`, `statsig/`, `*.log`, caches — machine-local churn |
| `skills` | `skills/**` under the slot | — |
| `mcp` | the vendor's MCP server config | credentials referenced by it, which are class `auth` |
| `auth` | only providers the operator opted in per the matrix below | everything not opted in |
| `tools` | the fleet-managed utility manifest, not the binaries | arbitrary software on the machine |

`sessions/` and transcript layouts stay local: `agents transfer` already exists
for moving a session deliberately, and the `execution` task owns handoff.

## Versioning: a base digest, not a clock, and never last-writer-wins

Each machine keeps, per resource, the digest it last **agreed** with the fleet
(`base`) alongside the digest it currently has (`local`). On sync with a peer
holding `remote`:

| local vs base | remote vs base | outcome |
| --- | --- | --- |
| same | same | nothing to do |
| same | changed | fast-forward: apply remote, base := remote |
| changed | same | push: peer applies, base := local |
| changed | changed, equal digests | converged independently; base := local, no conflict |
| changed | changed, different | **conflict** — neither side applied |

That table is the whole merge rule, and it is deliberately incapable of
expressing "newest timestamp wins" or "the primary machine wins". Both are
forbidden by the issue. Timestamps are recorded for display only; no code
branches on them.

A deletion is a resource whose digest is the tombstone `-`. Delete-versus-edit
therefore lands in the "changed / changed / different" row and is a conflict,
which is the intended behavior: a deletion is never allowed to silently eat a
concurrent edit, and an edit is never allowed to silently resurrect a deletion.

Conflicts are durable and visible: both candidate payloads are preserved under
`$fleet_root/sync/conflicts/<id>/{local,remote,meta}`, `fleet status` and
`agents fleet sync` report the count, and the resource is **pinned** — further
sync passes neither apply nor re-report it until the operator runs
`agents fleet resolve <id> --take-local|--take-remote`. Pinning is what makes
repeated sync idempotent in the presence of an unresolved conflict; without it
every pass would re-copy and re-conflict.

### A candidate that could not be fetched is not a deletion

Pinning both payloads is only safe if the stored payload is honest about what
it is. The remote side of a conflict record therefore carries an explicit
disposition, written by the code that knows it rather than inferred later from
a missing file:

| `remote_state` | meaning | on disk |
| --- | --- | --- |
| `present` | the peer's bytes were fetched and hashed to the digest it advertised | `conflicts/<id>/remote` |
| `deleted` | the peer's manifest advertised the tombstone `-` | `conflicts/<id>/remote.deleted` |
| `unavailable` | the peer advertised content, but the fetch failed or did not match the advertised digest | `conflicts/<id>/remote.unavailable` |

The distinction is not cosmetic. Before it existed, a dropped `sync-get` was
recorded as a tombstone, and `resolve --take-remote` then *deleted* the local
file to honour a deletion the peer had never announced — the exact data loss
the conflict machinery exists to prevent. `resolve --take-remote` now refuses
(non-zero, pin kept, local file untouched) while the candidate is
`unavailable`, and the pin self-heals: a later pass that can reach the peer
re-fetches the candidate and upgrades it to `present`, after which the same
command lands the peer's real bytes. `fleet sync conflicts` prints the state in
an appended `remote:<state>` column, so an operator is never asked to choose
between two sides when only one of them is actually in hand.

`sync_fetch_candidate` is the single place that fetches a candidate, and it
believes what came back only if it hashes to the advertised digest. That also
removes an emptiness bug: a legitimately zero-byte remote used to read as
"nothing came back" through a `-s` test, so choosing the remote side deleted
the file instead of emptying it.

### A pin belongs to the peer that raised it

A conflict is a disagreement between *two named machines*, not a property of
the address. The record therefore stores the peer whose divergence produced it
(`conflicts/<id>/peer`), and that identity is load-bearing in two places:

- `sync_conflict_record` refuses to overwrite an existing pin that was raised
  by a different peer. A pin is a decision the operator has been asked to make
  about specific bytes; another machine's later pass may not substitute its own
  bytes into that question.
- `sync_pass_peer` does not refresh — or even fetch — a candidate for a pin it
  does not own. A non-owning peer's pass reports `pinned` and moves on.

Without that ownership, a third machine that had never diverged would replace
the stored candidate on its next pass simply by being visited: after alpha and
beta conflicted, syncing alpha with an unchanged gamma overwrote beta's
preserved edit with gamma's copy of the *pre-divergence* bytes, and
`resolve --take-remote` then landed those stale bytes as though they were the
peer's change. Anchored by "pin4: --remote lands the edit of the peer that
raised the conflict".

A fleet can of course be three ways apart, and that fact must not be hidden by
the pin. A diverging non-owner is recorded beside the decision rather than in
place of it — `sync_conflict_note_other` appends to `conflicts/<id>/others`,
deduplicated by peer — and `fleet sync show` prints one
`also_diverged=<peer>\t<digest>\t<state>` line per such machine. The operator
learns the third machine exists and still resolves the two-sided question that
was actually raised. Anchored by "pin4: gamma's divergence is reported beside
the pin, not as the candidate".

### A declared sender base retires only that sender's own pin

A sender declares the base it pushed from. When that declared base is exactly
what we hold on disk, the sender already weighed our bytes against its own, so
its candidate discards nothing it had not seen — that pass fast-forwards rather
than raising an inverted copy of a conflict the operator already settled.

That reasoning is about *the sender*, and the fast-forward is therefore scoped
to the pin the sender itself owns. A third machine whose base happens to equal
our current bytes has compared its copy with ours and said nothing at all about
the candidate a *different* peer is waiting on. Retiring that pin on its behalf
would answer a question the operator never answered and destroy the bytes the
pin was preserving. `sync_absorb_locked` reads `sync_conflict_owner` before
taking the branch: an unpinned resource still fast-forwards, an owned pin only
fast-forwards for its owner, and every other sender gets `pinned`. Anchored by
"sendbase: a third peer's fast-forward does not land through the pin" and its
positive control "sendbase: the pin's own owner may still fast-forward".

## Machine-specific exceptions

`$fleet_root/sync/exceptions` holds `class|profile|vendor|relpath-glob` lines
and is **machine-local by design** — an exception is a statement about *this*
machine, so it neither syncs nor changes the shared setup for anyone else.
An excepted resource is reported as `excepted`, never as `ok` and never as
`failed`, because the issue explicitly asks that an intentional difference be
distinguishable from a failed synchronization.

### A removal verb reports only what it removed

`fleet sync except rm <n>` and `fleet tools rm <name>` both rewrote their file
with `awk` and then printed success unconditionally, so a removal that matched
nothing still said `removed` / `unmanaged` and exited 0. Both failures point the
operator at the wrong belief, and in the more dangerous direction:

- A failed `except rm` leaves the exception standing while the operator believes
  the resource is back in sync scope — including when they are following the
  `resolve --local ... or remove the exception first` advice above.
- A failed `tools rm` leaves the tool fleet-managed while the operator believes
  they withdrew install authority; the manifest keeps installing it on every
  tick. Reachability is never authorization, and neither is a typo.

`except rm` now refuses anything that is not an existing line number from
`except list` (non-numeric, zero, and out-of-range are all hard refusals that
rewrite nothing), and `tools rm` refuses a name that no record carries. Tool
matching is on the record's first field alone, not on record validity, so an
invalid manifest line can still be withdrawn rather than becoming unremovable.

The boundary check exposed a third instance of a trap this document already
records for `sync_conflict_count`: `grep -c` prints `0` **and** exits 1 when it
matches nothing, so `$(grep -c . "$f" || echo 0)` yields two lines. Four sites
still carried it — `resources`, `agreed`, `exceptions` and `tools-retry` — and
each injected a bare, unlabelled `0` record into `fleet sync status` whenever
its file existed and counted zero. That is output the tray and `--porcelain`
consumers parse. All four now go through `sync_num`, which normalises a missing
or failed count to a single `0`.

Evidence: test section 47 (20 assertions). The negative control against the
pre-fix file reports 10 failures, including the stray status line and both
false-success refusals.

### A conflict id is an id, never a path

`sync resolve` finishes by removing the conflict directory: `rm -rf
"$(sync_conflict_dir)/$id"`. `sync show` reads `"$(sync_conflict_dir)/$id/meta"`.
Both took the id straight from the command line, so an id containing `/` or
`..` was a delete primitive and a file-read primitive aimed wherever the
operator -- or a script wrapping the CLI, or a tray action passing through an
id it did not itself produce -- happened to point. The only gate was `[ -d ]`
plus a `meta` file carrying an `addr=` line, which is a shape an unrelated
directory can easily have. Verified before the fix: `agents fleet sync resolve
../../../../<dir> --local` printed `resolved`, exited 0, and deleted a
directory outside the conflict store entirely.

An id is only ever the value `sync_conflict_id` emits: twelve lowercase hex
characters. `sync_conflict_id_ok` enforces exactly that, and both `resolve` and
`show` call it before the id reaches a path expression. A well-formed id that
does not exist still fails as `no such conflict`, not as malformed, so a real
id is never rejected as garbage and the operator is not sent hunting.

### An exception that could never match is refused, not stored

`except add` validated the class and nothing else. An exception is compared
against an address field by field, with an *exact* string compare on class,
profile and vendor -- so a field that can never occur in an address matches
nothing, forever. Verified before the fix: `except add settings Work clade
settings.json` (one letter wrong in `claude`) appended the record, printed
`excepted` and exited 0, while `sync scope` still listed
`settings|Work|claude|settings.json` and the next pass would overwrite this
machine's copy with the fleet's. That is the exception feature reporting the
opposite of what it did, in the direction that loses the operator's data.

The `|` separator was the quieter version of the same lie: `except add settings
'a|b' claude settings.json` stored `settings|a|b|claude|settings.json`, which
reads back as profile `a`, vendor `b`, glob `claude|settings.json` -- a
different exception from the one echoed to the operator. A tab or newline in a
field corrupts the line-based store outright.

Two gates, both deliberately narrow:

- **vendor** is a closed set. `*`, `-` (the reserved fleet tools slot), or a
  member of `$N2_VENDORS`; anything else is refused and the error names the
  known set so the typo is fixable from the message.
- **profile** and **vendor** are shape-checked by `sync_except_name_ok`: no
  `/`, no `|`, no tab or newline, not `.` or `..`, not empty -- exactly the
  shapes `sync_scope_ok` already refuses in an address, so refusing them here
  removes only records that were inert by construction.
- the trailing **glob** keeps `|` (it is the last field, read back intact, and
  an addr relpath may legitimately contain one) and keeps `/` (`skills/*` is
  ordinary). Only tab, newline and empty are refused.

What is *not* refused matters as much: a profile this machine has never seen is
accepted. Excepting a profile before it arrives from the fleet is exactly what
a new machine does, and a gate that demanded the profile already exist would
break that in the name of catching a typo.

### An exception outranks a conflict pin made before it

A pin outlives the scope it was made in. The operator can add an exception (or
withdraw an auth opt-in) while a conflict sits unresolved; from that moment a
sync pass skips the address entirely, so nothing re-examines the pin and it
never clears itself. Before this was fixed, `sync resolve <id> --remote`
reached `sync_write` directly — the only path in the file that bypassed
`sync_scope_ok` — and happily wrote the peer's bytes over the exact resource
the operator had just declared this machine keeps to itself. That inverts the
feature: the exception exists to make an intentional difference durable.

So `sync_conflicts` prints a fifth column, `scope:in` or `scope:out`, for every
row (both states printed, so neither is an absence), and `resolve --remote`
refuses an out-of-scope address, keeps the pin, touches no file, and exits
non-zero. `--local` still works and is the documented way out: it writes
nothing, so clearing the pin does not contradict the exception. Removing the
exception restores `--remote`. The gate is `sync_scope_ok`, not `sync_excepted`
alone, so a withdrawn auth opt-in is covered by the same rule — a pinned `auth`
conflict cannot be used to land a credential the machine no longer opts into.
Verified by test section 46 (12 assertions); with the guard removed the section
reports 8 failures including the excepted local file reading `ALPHA X` instead
of `BETA X`, so the assertions are not vacuous.

## Adopted symlinks

A slot may be a symlink into `~/.claude-profiles/<Name>` (`cmd_adopt`). Sync
follows the slot symlink to read and write **contents**, and never transmits or
reproduces the link itself: the link is a local fact about how this machine
shares state with the older `claudes` tool. Symlinks *inside* a slot are not
followed for content and are not replicated; a resource whose real path escapes
the slot is refused as an unsafe path. This keeps replication from turning a
local convenience into a fleet-wide dependency on a path that may not exist.

## Auth: opt-in per provider, and honest about what is impossible

### The whole `mcp` class rides the same per-vendor opt-in

The content-aware gate below scans for credential *key assignments*, and an MCP
record routinely puts secrets where no key name appears: a bare `--api-key`
positional in `args`, a password inside a `postgresql://user:pass@host/db`
URL, a `Cookie` header, an arbitrarily named `env` entry such as `GH_PAT`.
Chasing those shapes one at a time is a losing race against config formats the
scanner does not own, so the `mcp` class is treated as credential material by
policy rather than by scan: it is gated on `sync_secret_shareable` exactly like
`auth`, in `sync_scope_ok` (this machine does not *offer* it) and in
`sync_write` (this machine does not *accept* it), so a sender that opts in
alone still places nothing. The opt-in is per vendor, not per machine.

This is a deliberate reduction in what syncs by default: before the change, a
credential-free `.mcp.json` replicated with no opt-in at all. Operators who
want MCP configuration to follow the profile run
`agents fleet sync auth enable <vendor>` on both machines, which is the same
switch that shares that vendor's credentials — the two are not separable today.
Anchored by section 73 of the sync suite; sections 1, 2, 5, 53, 64 and 65 were
rewritten to the new policy, with their over-broadness assertions now run with
the vendor opted in so they still measure the scanner rather than the class.

### A credential is not always in a file called `auth.json`

The same binary shows `apiKeyHelper` (103 occurrences), `awsAuthRefresh` (25)
and `ANTHROPIC_BASE_URL` (88) alongside the token names above, and it reads an
`env` block out of `settings.json`. So a live token can sit in a file whose
*path* classifies as `settings` — a class the per-provider auth opt-in does not
gate.

Making `sync_classify` content-aware was rejected: class is a pure function of
the path so that an address is stable, and a file whose address changed with
its contents would occupy two addresses, the abandoned one reading as a
deletion. The **gate** is content-aware instead. `sync_file_carries_secret`
matches credential *key assignments* in JSON or TOML/env form
(`SYNC_SECRET_KEYS`), and `sync_secret_shareable` then applies exactly the
`auth.json` opt-in to any non-auth file carrying one. It is enforced at three
points, because no single one covers every path:

* `sync_manifest` (sender) — the address never leaves the machine.
* `sync_scope_ok` (both sides) — inspects whichever local copy exists.
* `sync_write` (receiver) — checks the *arriving* payload, since a first pull
  has no local copy for `sync_scope_ok` to inspect.

The matcher only ever reads key names, never values, so the check cannot itself
leak. A held-back address is *reported* (`skipped	<addr>`) rather than silently
dropped: a resource that vanishes without explanation looks like a bug.

An environment-variable name is not the only way a credential is written down,
and the first version of `SYNC_SECRET_KEYS` assumed it was. A **remote** MCP
server is authenticated with an HTTP header whose name the protocol fixes, not
the vendor:

```json
{"mcpServers":{"s":{"url":"https://…","headers":{"Authorization":"Bearer <token>"}}}}
```

That file classifies as `mcp`, which at the time the auth opt-in did not gate
(it does now — see "The whole `mcp` class rides the same per-vendor opt-in"
above), and it contains none of the vendor key names — so a live bearer token replicated to
every peer byte-for-byte with auth sharing explicitly **off** on both machines.
The operator had refused to share credentials and shared one anyway.
`SYNC_SECRET_HEADER_KEYS` therefore covers the header and generic spellings,
matched **case-insensitively**, because HTTP header names are: `authorization`
and `Authorization` are one header.

#### The list grew five times, and each time a real bypass grew it

The first version of the list was the snake_case env-style spellings plus the
protocol headers. Every widening since came from probing
`sync_file_carries_secret` directly for a spelling the list did not have and
finding it `clean`, not from reading the list and imagining one. Each is held
down by its own section in `scripts/test-sync.sh`. Sections 66, 67 and 68 were
each additionally run against a byte-identical **revert** of the fix as well as
against the fix, so the recorded failure is the bypass itself and not a test
that would pass either way.

| spelling | what it looked like | why the list missed it | section |
| --- | --- | --- | --- |
| escaped JSON key | `"\u0041uthorization": "Bearer …"` | the key is not stored literally, so a grep over raw bytes reads it as an ordinary string. Fixed by matching the **decoded** text (`sync_json_unescape`, ASCII range only) | 64 |
| key split over a newline | `"access\n_token" : "…"` | JSON permits whitespace between a key and its `:`, and the raw-byte scan anchored on adjacency. Fixed by folding whitespace runs before matching (`sync_scan_fold`) | 65 |
| TOML literal key | `'OPENAI_API_KEY' = '…'` in a codex `config.toml` | the anchor allowed an optional *double* quote around the name. [TOML keys may be single-quoted literals](https://toml.io/en/v1.0.0#keys), so the name matched nothing. Fixed by widening both anchors to the quote class `["']` | 66 |
| camelCase | `{"claudeAiOauth":{"accessToken":…,"refreshToken":…}}` — the shape Claude Code itself stores — pasted into `settings.json` or `.mcp.json` | only `access_token` was listed. A bare `token`, the commonest key a remote MCP entry stores a bearer under, was missing for the same reason | 67 |
| hyphenated | `{"headers":{"api-key":"…"}}`, `x-goog-api-key` | hyphen is the separator two providers actually use in their authentication header — Azure OpenAI reads `api-key`, Google's generative API reads `x-goog-api-key`. Neither ends in a listed name: `key` is not listed and cannot be, because `"key":` is an ordinary map key in half the files that sync | 68 |

The hyphenated names are listed explicitly rather than derived by rewriting `-`
to `_`, which would have broken the `X-Api-Key` alternative they share a
character class with. `access-token`, `refresh-token` and `client-secret` need
no entry: they end in `token` / `secret`, which the anchor then reads as the
assignment it is.

The common shape of all four: a file class the auth opt-in did **not** gate
(`settings`, `mcp`) carrying a credential under a name the list did not
enumerate. `mcp` has since been moved behind the opt-in, so the class that is
still ungated and still relies wholly on the enumeration is `settings`. The gate is an enumeration, so it is only ever as good as the
enumeration — a new provider with a new header name is the next bypass, and the
honest statement of the limit is that this catches *known* credential
spellings, not all of them. What bounds the damage is that the enumeration is
checked at three points and the tier table below claims no provider as
`supported`.

The anchor — key name, optional closing quote (either kind), then `:` or `=` —
is what keeps the broader names from over-reading, and it is load-bearing now
that names as generic as `token`, `secret` and `password` are in the list.
`"authorizationRequired": true`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS: "8192"`,
`{"maxTokens":8192}`, `{"passwordless":true}`, `{"key":"cmd+k"}`,
`{"secretName":"prod"}`, `{"apiKeyless":true}`, an array member
`{"fields":["api-key","secret"]}`, and prose that merely mentions an api-key all
put a letter, a comma or a space where the anchor needs a quote or an
assignment, so none of them match. All still replicate. Each widening carries an
over-broadness guard in its own section, and the remaining cases were checked
by probing `sync_file_carries_secret` directly for a `clean` result.

The gate remains an opt-in and not a ban: opting the vendor in on both sides
shares the credentialed file, and the receiver enforces its own opt-in
independently, so a sender opting in alone does not place the file.

Class `auth` is off unless the operator opts a provider in. The tiers follow the
binary evidence recorded above, not hopefulness — and **no provider is tiered
`supported`**. The rule this section hands the `sync` task sets the bar for that
word at an authenticated call succeeding on the receiving machine from synced
state; development is not permitted to make that call against real credentials,
so the bar is unmet for every provider and none claims it. `partial` means the
file material is portable and replication is implemented and tested with
synthetic secrets; it does **not** mean sign-in was demonstrated. A provider
whose credential lives outside the isolated slot is `unsupported`, not
`partial` — an opt-in that would carry nothing is refused, because a false
affordance reads as a sync bug rather than as a stated limit.

| provider | tier | what actually happens, and what is not shown |
| --- | --- | --- |
| claude | **partial** | only env-supplied token/API key material is file-visible and therefore replicable, wherever it sits; it is gated by the auth opt-in through the content-aware check above. The interactive credential lives in the login keychain, which profile isolation does not isolate and file sync cannot see — transplanting an interactive session is **explicitly unsupported** |
| codex | **partial** | `auth.json` carries `tokens` + `last_refresh`, so the file is portable and two independent refreshes are raised as a conflict rather than clobbering (section 10). **Not shown:** that a transplanted token is accepted by the provider on the receiving machine. File portability is not sign-in |
| opencode | **unsupported** | the shipped binary resolves the credential from `XDG_DATA_HOME`, while profile isolation repoints only `XDG_CONFIG_HOME`, so the token is machine-wide and sits entirely outside the slot the sync walks. That is structural, not partial: nothing under the synced slot carries it, so an opt-in would be inert and is **refused** rather than accepted and silently ignored. Per-provider-key merge *would* be the right shape for that file (it multiplexes providers, so whole-file replication would couple unrelated refresh state), but carrying the file safely first requires isolating `XDG_DATA_HOME` — a change to the isolation tier, recorded as an open item |
| gemini | **unsupported** | `swap`-tier isolation: the config dir is a source constant, so it cannot be isolated per process |
| grok, cursor | **unverified** | not inspected; absence of evidence is reported as unverified rather than assumed to match codex |

Unsupported and unverified providers are *listed with the reason*, not omitted.
A refresh that happens on two machines is a conflict, not a silent overwrite.
Secret values never enter `events.log`, fixtures, or any message header; tests
use synthetic material and assert redaction rather than assuming it.

## Managed utilities

`$fleet_root/tools/manifest` lists only what the operator explicitly designated
(`agents fleet tools add <name> [--version <v>]`). Nothing else is ever
installed or updated — a tool that appears on a peer's manifest but not in the
local operator's authorization is reported, not executed.

A designation needs two commands, and both are refused when missing.
`--install` is the authorization. `--check` is how every later pass reads the
installed version, and it is equally mandatory: with no check command
`sync_tool_state` can only ever answer `install`, so the installer re-runs on
every tick and even a successful install is reported `failed`, because the
post-install re-check can never reach `ok`. `sync_tool_line_ok` enforces the
same rule on a record that arrives already written — a replicated or
hand-edited line with an empty check field is `invalid` in `tools list`,
`tools status` and `tools apply`, and `tools install <name>` refuses it, so an
unverifiable record never executes an installer. Verified by test section 14
(`tools: a tool with no check command cannot be designated`, `tools: an
uncheckable manifest line is listed invalid`, `tools: apply refuses it
loudly`, `tools: the invalid record installed nothing`); removing either guard
fails seven assertions, including the one proving the installer would have run.

Pending work applies immediately when it can. A manifest entry declares whether
its update is `safe` (can apply while agent tasks run) or `disruptive`; only
`disruptive` entries defer, and they defer against real task state rather than
a blanket rule. The hook is `fleet_tasks_active` — the `sync` task ships a
conservative implementation reading `$fleet_root/tasks/`, which the `execution`
task replaces with the live task table. Deferred work is recorded and retried
on the next pass, so "deferred" never silently means "dropped".

## Defects the replication tests found (kept as regression anchors)

Three bugs in this module were found by execution, not by reading, and each one
now has a named assertion in `scripts/test-sync.sh`:

1. **A global merge base deleted files on the originator.** A peer that had
   never seen a resource read its absence as a deletion, so enrolling a fresh
   machine proposed deleting the enroller's own skills. The base is now keyed
   per `(peer, address)`; `sync_base`/`sync_base_set` take a peer.
   Anchor: *"except: gamma still takes the skill"*.

2. **`tools install <anything>` passed the authorization gate.**
   `sync_tool_line` ended in `... | tail -1`, so the pipeline's exit status was
   `tail`'s — always zero — and `sync_tool_managed` therefore said yes for every
   name, including one the operator never designated. The function now captures
   the match and fails on an empty result.
   Anchor: *"tools: an unlisted tool is refused"*.

3. **A symlink planted inside a slot carried outside bytes to a peer.**
   `sync_path_contained` resolves the *parent directory*, which a symlinked file
   passes. `sync_link_contained` resolves the link target itself and is applied
   both when building the advertised manifest and when serving `sync-get`, so
   the escape is refused on the wire and not merely hidden from the listing.
   Anchor: *"escape: the outside file's bytes never reach the peer"*.

## Managed utilities: the authorization and deferral contract

* **A manifest is a fleet fact; the command inside it is not fleet authority.**
  Designating a tool on one machine must never execute a shell command on
  another one. A record that arrives from a peer carrying an install or check
  command this operator has not approved reports `pending-approval` and runs
  nothing — under `tools apply`, under `tools install <name>`, and in
  `tools status`/`tools list`. `agents fleet tools approve <name>` records the
  approval, keyed on a digest of the stored install and check fields, and only
  then does it run. `tools add` on this machine *is* that approval: typing the
  command locally is the operator's word. `tools rm` forgets it, so a later
  re-designation from any machine is a fresh decision. A version bump that
  keeps the approved commands applies by itself, with the deferral rules below
  unchanged; a *changed* install or check command changes the key and waits for
  its own approval. Approval is permission to run, not permission to interrupt:
  an approved `--disruptive` update still defers while work is active. Anchored
  by section 72 of the sync suite and by section 25's replacement assertions.
* `--install` **is** the authorization. A tool with no installer cannot be
  designated, and `tools install` refuses any name absent from the manifest —
  reachability is never permission.
* An update that is not marked `--disruptive` applies immediately, including
  while tasks are running. This is the agreed behavior: updates do not wait for
  the fleet to go idle.
* A `--disruptive` update while `$fleet_root/tasks/active` is non-empty is
  **deferred**: recorded in `tools/deferred`, journalled as `tool-deferred` with
  the active-task count, reported to the operator, and retried on the next
  apply. Active work is never interrupted to force an update through, and the
  update is never silently dropped.
* **An active-task record must name its owner, or it is believed forever.**
  `tasks/active` is the deferral gate, and emptiness was the only signal. A
  worker killed mid-task leaves its record behind, so every `--disruptive`
  update defers on every subsequent pass while the operator keeps reading
  "deferred, retried on the next apply" for a retry that can never succeed —
  the fleet drifts silently, which is the exact failure the deferral rule
  exists to avoid. `sync_tasks_reap` (called from `sync_tasks_active`) reads a
  `pid <n>` line from each record and, when `ps -p` says that owner is gone,
  renames the record in place to `.stale-<name>`: `ls -1` no longer lists it so
  it leaves the active count, and the bytes the execution task wrote survive
  for reconciliation instead of being deleted. A `task-record-stale` event is
  journalled.
  **The rule is deliberately one-sided.** A record that declares no pid, or one
  that cannot be parsed, is counted as ACTIVE. Liveness we cannot prove is
  never treated as permission to interrupt somebody's work, so the only way to
  be reaped is to say who you are and be provably gone. Honest limit: `ps -p`
  cannot see a recycled pid, so such a record reads as alive and is kept one
  more pass — erring toward deferring an update, never toward running one
  against live work. **Interface for the `execution` task:** write `pid <n>`
  as a line of the active-task record. Anchored by section 60, "stale-task: a
  live owner still defers the disruptive update", "stale-task: a record with no
  declared owner is still active" and "stale-task: an abandoned record does not
  defer the update forever".

* An installer that exits 0 without reaching the requested version is reported
  as `failed`, not as success — that asymmetry is how a fleet silently drifts.
* **`tools apply` reports failure in its exit status.** It printed
  `failed <tool>` on stdout and exited `0`, so `agents fleet tools apply ||
  alert` never alerted and any automation that only reads exit codes — the tray,
  a launchd wrapper, CI — recorded a drifting fleet as healthy. Any tool that
  could not reach its designated version (`failed`, from either a non-zero
  installer or an installer that lies), and any manifest record that can never
  apply (`invalid`), now makes the batch exit `1`. A **deferral is not a
  failure**: holding a `--disruptive` update back while a task runs is the
  agreed behavior succeeding, and it is retried on the next tick, so it stays
  exit `0`. The per-tool lines are unchanged — only the status is new.
  The arrival hook in `fleet_handle_sync_put` wraps the call in `|| true`: a
  failing installer must not abort the handler under `set -e` and leave the
  sender staring at a protocol error for a manifest that actually landed. The
  two pipeline callers (`sync_pass_peer`, `sync_tick`) already take `sed`'s
  status, so a tool failure does not abort a sync pass either. Anchored by
  "apply-rc: and the batch exits non-zero", "apply-rc: a deferral is NOT a
  failure" and "apply-rc: withdrawing the broken tool restores a zero exit".

* **A tool option may not swallow the next flag as its value.** `tools add x
  --check c --install --disruptive` stored an installer whose command was
  literally the string `--disruptive`, printed `managed`, and exited `0`. Two
  things are wrong at once: the tool can never install, and the
  `--disruptive` flag — the *only* marker that holds an update back while a
  task is running — was silently dropped, so a genuinely disruptive update
  would have been free to run against active work. That inverts the
  managed-tools contract by way of a typo. A missing value at the end of the
  line was the louder version of the same bug: a raw `$2: unbound variable`
  instead of a usage message. `--version`, `--check` and `--install` now
  require a value, and that value may not itself begin with `--`; no version
  string and no runnable command does. The gate is deliberately narrow — a
  dashed version (`2.0-rc1`) and flags *inside* a quoted command
  (`sh -c "true --flag"`) are ordinary and pass, and an explicitly empty
  `--version ''` still means "any version". Anchored by "optval: --install
  cannot take the following flag as its value", "optval: and the disruptive
  flag reaches field five" and "optval: a dashed version and a flag inside a
  quoted command are fine".

* **The same rule, on the `sync` half of the command surface.** `cmd_fleet_sync`
  read every option value as a bare `$2`, so the whole family was present
  there too, and one case was worse than anything in `tools add`:
  `sync tick --interval abc` **exited `0`**. `sync_tick` quietly substituted
  the default for a value it could not parse, so a wrapper, a cron entry or a
  timer that asked for a cadence was told the cadence was in force when it was
  not — and `--interval 300s`, the realistic typo, is exactly that case. The
  tell that this was an oversight rather than a decision: `sync auto` and
  `sync service install` both reject the identical value. The swallowing
  variant hit `--peer` and `--rounds`: `sync now --peer --dry-run` consumed the
  `--dry-run` and then reported `peer is not approved: --dry-run`, and
  `sync auto --interval --rounds 1` consumed the `--rounds` and blamed the bare
  `1` — an argument the operator had written correctly. `--peer`, `--interval`
  and `--rounds` now go through `sync_needval`, which requires a value and
  refuses one beginning with `--` (no peer id, interval or round count does),
  and `tick` validates its interval with `sync_seconds_ok` like its two
  siblings instead of falling back. Anchored by "syncopt: a non-numeric
  interval is refused, not defaulted", "syncopt: --interval does not swallow
  --rounds", "syncopt: and it no longer blames the innocent argument" and the
  four over-broadness guards in section 52.

### Four more defects review found, and the tests that now hold them down

Each of these passed the earlier suite and still lost data or leaked bytes. The
named assertion is the anchor; the rule it encodes is stated with it.

1. **A peer's exception read as a deletion.** A machine-local exception is a
   statement about *that* machine. But an excepted resource simply vanished
   from the responder's manifest, and absence is how a tombstone is spelled —
   so the originator deleted its own file. The manifest now carries a distinct
   `!` marker (`SYNC_EXCEPTED`): the responder *announces* an exception rather
   than hiding it, and the initiator reports `excepted` and leaves the agreed
   base untouched, because nothing was exchanged. Everything else out of scope
   (bad class, unsafe path, auth not opted in) stays unmentioned. Anchored by
   "except-vs-delete: alpha still has its own file" and its repeated-pass twin.

2. **A rejected push pinned an empty conflict.** When the receiver answered a
   put with `conflict`, the sender recorded a conflict with no candidates, so a
   later `resolve --local` restored nothing — it deleted the edit it existed to
   preserve. The sender now fetches the peer's bytes and names its own local
   path before pinning, exactly as the initiator-detected path does. Anchored
   by "rejected-push: the local candidate holds alpha's real bytes" and
   "rejected-push: choosing local keeps the local edit".

3. **A symlinked *directory* walked straight past the file-level check.**
   `find -L` descends *through* a directory link, so the file it emits is not
   itself a symlink and `sync_link_contained` never sees it. The manifest walk
   now also resolves each file's parent against the slot, and `sync_push_one`
   re-checks both before reading a single byte — the read path is guarded, not
   only the advertised address. Anchored by "dirlink: the address is never
   advertised" and "dirlink: the outside bytes never reach the peer".

4. **`tools install <name>` ignored active work.** `tools apply` deferred a
   disruptive update while a task was live; naming the tool explicitly bypassed
   that. Naming a tool is authorization to install it, not permission to
   interrupt running work, so the single-tool path now obeys the same rule:
   defer, journal, report the active count, and apply on the next call once the
   fleet is idle. Anchored by "named install: nothing was installed" and
   "named install: it installs once the fleet is idle".

5. **A local edit inside the apply window was overwritten.** A pass reads the
   local digest from its manifest snapshot, then spends a whole peer round trip
   fetching the remote body before it writes. An edit landing in that gap was
   lost twice over: the body case overwrote it with the remote bytes and
   reported `pulled`, and the remote-tombstone case truncated the file to
   nothing and reported `deleted` — in both, zero conflicts, so the operator
   was never told. The decision is now re-checked against the bytes on disk at
   the moment of the write (`sync_pull_still_current`), and a moved file is
   re-decided from its current contents (`sync_pull_raced`): either the local
   edit happens to equal the remote, which is convergence and advances the
   base, or it does not, which pins a conflict with the local path and the
   peer's candidate. Neither answer writes over the new bytes. The base digest
   alone cannot close this: it records what was agreed, not what is on disk.
   Anchored by section 43, "no lost update across the apply window" — "the edit
   that landed during the fetch is still on disk", "the pass reports a conflict,
   not a silent pull", and the tombstone twin "a remote deletion does not take
   an edit that landed after the read". The push direction needs no such guard
   and deliberately did not get one: `sync_push_one` re-reads the file but
   advertises the snapshot digest, and `fleet_handle_sync_put` recomputes the
   digest of the decoded body and answers `ERR sync-digest-mismatch`, so a
   racing local edit fails closed at the receiver instead of landing on a stale
   base.

### The sub-verb completions are held to the fleet-level standard

`test-sync.sh` section 45 reads the `sync` and `tools` verbs out of their usage
text and asserts each one is completable — the same self-updating shape
`test-fleet.sh` uses for the top-level verbs. It originally executed bash's
completion function and gave zsh and fish only a `zsh -n` parse check, which
cannot see a missing verb. zsh and fish publish their sub-verb lists as literal
text, so the check now reads that text as well: a verb added to `sync help` but
not to `_values 'sync verb'` or fish's `-a` list fails here. Dropping `auto`
from either list turns exactly that assertion red while both parse checks stay
green, which is why the parse check alone was not coverage. The literal read
needs neither shell installed — drift in a list this host cannot execute is
still drift on the host that can.

### The automatic trigger (`sync tick` / `sync auto`)

Replication is not something the operator has to remember, so `sync_tick` is
the one automatic entry point. For each approved peer it pings, records
`state=online|offline` and `last_pass` under `fleet/sync/seen/<peer>`, and runs
a pass when the peer is *newly* reachable (the reconnect trigger) or when
`last_pass` is older than the interval (the ongoing trigger). A peer that is
neither is reported `fresh` and left alone, so a timer does not turn into a
busy loop over the fleet.

`agents fleet sync tick [--interval s]` is one round; `agents fleet sync auto
[--interval s] [--rounds n]` repeats it in the foreground, which is a debugging
tool rather than the mechanism — it dies with its terminal. `agents fleet
reconcile` runs a round with interval 0 — being away
is precisely the case where every reachable peer is due — and `--no-sync`
exists for the revocation-only case.

An offline peer is only recorded, never treated as agreement: the agreed base
is untouched, so the pass after it returns replays the missed change.

### The installed timer (`sync service`)

A verb that exists is not a verb that runs. `agents fleet sync service install
[--interval s]` writes a launchd **user agent** to
`~/Library/LaunchAgents/com.n2agents.fleet-sync.plist` and bootstraps it into
`gui/<uid>`. That is what makes ongoing replication actually ongoing: a user
agent survives logout and reboot, and it runs whether or not the tray app is
open — which matters because the CLI is the behaviour authority and the tray is
one of its clients, not the scheduler.

The plist is deliberately explicit about three things that launchd would
otherwise get wrong:

| plist key | value | why |
| --- | --- | --- |
| `ProgramArguments` | `/bin/sh <resolved agents path> fleet sync tick --interval s` | the symlink-resolved entry point, so an installed shim on `PATH` does not decide which copy runs |
| `EnvironmentVariables.HOME` | the installing `HOME` | profile roots hang off `$HOME`; a job with launchd's idea of `HOME` would sync the wrong machine's slots |
| `EnvironmentVariables.PATH` | the `PATH` in force at install time | launchd hands a job a near-empty environment, and this job shells out to `ssh` and `ssh-keygen` |

`StartInterval` carries the same interval the tick is passed, `RunAtLoad` makes
login a reconnect trigger, and stdout/stderr go to `fleet/sync/service.log`.
Intervals below 30s are refused — the round would spend more time starting than
syncing. Reinstalling boots the old job out first, so there is exactly one job
and exactly one plist. `service status` reports the plist path, the interval it
actually contains, whether launchd has it loaded, and the timestamp of the last
`sync-tick` or `sync-service` journal entry, so "installed" and "running" are
distinguishable rather than assumed.

Nothing secret is written into the plist: it is ordinary world-readable user
config, and the only paths in it are the entry point, `$HOME` and the log.

`N2_FLEET_LAUNCH_DIR` and `N2_FLEET_LAUNCHCTL` redirect the directory and the
`launchctl` binary. They exist so the suite can install against a fixture and a
recording stub, exercising the real plist writer and the real load/unload path
without touching the operator's login session; with neither set, this installs
for real.

### The managed-tool manifest is a replicated resource

The manifest replicates under the reserved address `tools|-|-|manifest`
(profile and vendor are `-` because a designation is a fleet fact, not a
per-profile one). It goes through the same merge table, the same exceptions
and the same conflict pinning as a skill or a settings file, so two machines
that independently designate tools produce a visible conflict rather than a
silent winner.

When a pass *pulls* the manifest, the receiving machine applies it immediately
through `sync_tools_apply`. Authorization is unchanged: the manifest is still
the only authorization, `tools install <name>` still refuses a name that is not
in it, and the active-task deferral still holds, so an arriving manifest cannot
interrupt running work.

### A manifest record has exactly five fields, and the operator's shell is data

A manifest line is `name|version|check|install|flags`, and the deferral rule
reads the disruptive flag out of field 5 by exact comparison. Fields 2-4 hold
operator-supplied text — an installer command is an arbitrary shell pipeline —
so writing them raw let that text choose its own field boundaries. A perfectly
legitimate designation such as `--install 'curl … | sh'` pushed `disruptive`
into field 6, the exact comparison failed, and a tool the operator had marked
disruptive ran *during active work*. The authorization check passed; only the
deferral was lost, which is the worse half to lose silently.

Fields 2-4 are therefore percent-escaped on write by `sync_tool_enc`
(`%` → `%25`, `|` → `%7C`, newline → `%0A`) and decoded on read by
`sync_tool_dec`. The encoding is total and reversible, so the round trip is
lossless: `tools list` prints the operator's command back verbatim, and the
installer executed is the one that was designated. Anchored by "pipe: the
pipelined disruptive installer is deferred, not run" and "pipe: the
round-tripped install command is the operator's command".

Escaping protects records this machine wrote. A record can also *arrive* — the
manifest is a replicated resource, and the file is editable by hand — so shape
is validated rather than assumed. `sync_tool_line_ok` requires exactly five
fields, a non-empty name, and a field 5 that is empty or literally
`disruptive`; `sync_tool_line`, `tools apply`, `tools list`, `tools status` and
`tools install` all refuse a record that fails it. A malformed line reports
`invalid` and is never executed — a mangled record is not authorization, and it
is not silently reinterpreted as a differently-shaped one. Anchored by "pipe: a
malformed manifest record is refused" and "pipe: a malformed record is not
authorization".

### Reconciliation is part of every tick, not only of a deferred backlog

Designating a tool is the authorization; installing it is the tick's job. The
tick used to call `sync_tools_apply` only when the deferred journal was
non-empty, which meant `tools add` on an idle machine installed nothing until
a human ran `tools apply`, and a tool that was deleted or broken after the
fact stayed broken forever. Every tick now reconciles the whole designated
set: satisfied tools report `ok` and are not reinstalled, missing or
version-mismatched tools are installed, and nothing outside the manifest is
ever touched. The deferral rule is unchanged and still lives inside
`sync_tools_apply`, so making reconciliation unconditional did not make it
capable of interrupting a live task — a disruptive update on a busy machine is
still journalled and applied on a later tick once the fleet is idle.

## Running the suites

`scripts/test-sync.sh` costs roughly 300s end-to-end, which is longer than some
runners allow for a single foreground command. It is therefore resumable, not
only truncatable:

```sh
N2_SYNC_BASE=/tmp/fx N2_SYNC_KEEP=1 N2_SYNC_STOP_AFTER=30 sh scripts/test-sync.sh
N2_SYNC_BASE=/tmp/fx N2_SYNC_START_AT=31                  sh scripts/test-sync.sh
```

`N2_SYNC_BASE` fixes the fixture root, `N2_SYNC_KEEP` leaves it behind, and
`N2_SYNC_START_AT` re-execs a trimmed copy of the file — the same preamble,
then the named section onward — against that fixture. Sections build forward on
fixture state, so they cannot be skipped in place; the preamble is written to be
re-enterable, and records the three machine ids in `$base/.ids` so a resumed
section compares against the identities the earlier sections enrolled. A split
run and a contiguous run of the same range produce the same assertion count:
1-3 (12 ok) plus 4-8 (18 ok) equals a single 1-8 run (30 ok), 0 failed in all.


`scripts/test-fleet.sh` is the fleet verification command, and it now runs both
suites: its own transport sections, then `scripts/test-sync.sh` in a separate
process with its own fixture. Only the child's verdict folds into the parent
tally — the two suites keep independent counts because they have independent
fixtures, and a merged count would hide which half regressed.

```sh
sh scripts/test-fleet.sh                      # transport + replication
N2_FLEET_SUITES=transport sh scripts/test-fleet.sh   # transport alone
sh scripts/test-sync.sh                       # replication alone (~4 min)
N2_SYNC_STOP_AFTER=12 sh scripts/test-sync.sh # sections 1-12, with a tally
```

`N2_SYNC_STOP_AFTER=<n>` exists because the replication suite runs longer than
some automation windows, and a log that stops mid-section is indistinguishable
from a hang. A bounded run ends at a section boundary and prints a tally that
names its own bound (`50 passed, 0 failed (sections 1-12 of 63; stopped by
N2_SYNC_STOP_AFTER)`), so a partial pass can never be read as a full one.

The bound is a prefix, not a sample. Sections only ever build forward on fixture
state — a later section may depend on what an earlier one wrote, never the
reverse — so sections 1..n are exactly the suite with the tail removed. That is
also why `N2_SYNC_START_AT` is not a way to sample the middle of the suite on its
own: it requires the fixture an earlier prefix run left behind (`N2_SYNC_BASE` +
`N2_SYNC_KEEP`), and refuses with exit 2 — printing the two commands that would
have produced it — when `$base/.ids` is absent. Resuming is therefore always
"continue this fixture forward", never "run section n against nothing".

### `fleet tools` help answers before the identity check

`cmd_fleet_tools` ran `sync_need` before its verb `case`, so on a machine that
had not run `agents fleet init` every invocation — including `--help` and a
mistyped verb — died with "no fleet identity yet" instead of printing usage.
That is precisely the machine whose operator needs the help. `fleet sync` never
had the bug: it calls `sync_need` per verb, so its `help` and unknown-verb arms
are reachable without an identity. The verb gate now runs first for `tools`
too: `help` prints usage and returns 0, an unknown verb prints the verb list
and exits non-zero, and every real verb still requires an identity. Section 55
of `scripts/test-sync.sh` holds all three down.

### An auth opt-in must name a vendor that exists

`sync_auth_support` answers `unverified` for any provider it has not inspected,
and an unknown vendor is indistinguishable from an uninspected one. So
`agents fleet sync auth enable clade` exited 0, appended `clade` to the opt-in
file and printed `auth-optin clade unverified`. Because `auth list` iterates
`$N2_VENDORS`, the bogus line never appeared again: the operator read "enabled"
for a provider whose auth was in fact still not shared, with nothing in the UI
to contradict it. This is the same class as the `except add` typo — a record
stored that can never match, reported as if it took effect.

The revoking direction is the one with teeth. `auth disable clade` printed
`auth-optout clade` and exited 0 while `claude` stayed opted in and kept
replicating credential material on every pass. An operator withdrawing consent
to share credentials must not be told it happened when it did not.

Both arms now gate on `vendor_known` before doing anything, and the error names
the real vendors. The gate is a gate, not a wall: a real partially-portable
vendor still opts in and out, and an unsupported vendor is still refused for its
own documented reason (`sync_auth_reason`) rather than for the name. Section 56
of `scripts/test-sync.sh` holds all of that down, including the negative control
that the correctly spelt vendor round-trips.

### A grant that could not be stored is not a grant

`agents fleet tools add` is how the operator designates a utility as
fleet-managed — it is the authorization that later passes act on. Both writes
behind it were unchecked: the dedupe rewrite (`awk ... > "$t"; mv "$t" "$f"`)
and the append. When the manifest could not be written — a read-only directory,
a full disk, a stale root-owned file — the command still printed
`managed <tool> <version>` and exited 0 with nothing on disk.

That is the worst shape for this surface. The operator reads "managed" and stops
watching the tool; no later `tools apply` or reconnect pass will ever install or
update it, and `tools list` shows no trace of the attempt, so the grant is
invisible rather than merely absent. Nothing in the fleet reports the gap.

`add` now rewrites through a temp file that must survive, refuses if the append
fails, and reads the record back out of the manifest before reporting `managed`.
Every failure path names the tool and says plainly that it is *not* managed.
The guard is a guard and not a wall: once the manifest is writable the identical
grant lands, re-adding an existing name still replaces rather than duplicates,
and `tools rm` still withdraws.

Covered by section 57 of `scripts/test-sync.sh`. Against the pre-fix binary that
section fails exactly two assertions — the false `managed` line and its exit
status — while the nine surrounding controls pass, so the test is pinned to the
defect rather than to the shape of the fix.

### A conflict that could not be cleared is not a resolution

`rm -rf` on a directory the process cannot unlink is not a no-op. It deletes
the contents it *can* reach and leaves the directory standing. `sync resolve`
ended with exactly that call and never looked at its result, which produced the
worst available outcome: for `--remote` the peer's bytes were already written
and the base already advanced, `sync-resolved` was already in the event log,
and the command printed `resolved` and exited 0 — while the pin survived, so
every later pass refused to sync that address. The pin also survived *without
its meta*, having lost the `addr` line the rm did manage to delete, so no later
`resolve` could settle it either: the address was stuck permanently, and the
only signal was a conflict the operator could no longer act on.

Clearing a pin is therefore staged, and staged first. `sync_conflict_stage`
renames the record to a dot-prefixed sibling before anything is written; the
`*` glob in `sync_conflicts` and the exact-id test in `sync_conflict_pinned`
both look past that name, so the pin is atomically gone from every view or
still entirely present. A failed rename refuses the resolution outright, which
costs nothing because nothing has happened yet. Every failure path inside the
resolution — out of scope, unavailable peer candidate, a refused write, a bad
choice word — puts the record back with `sync_conflict_unstage`. The same
staging guards `sync_conflict_drop`; when it cannot clear a pin it returns
non-zero without emitting the event, and the pinned-resource test immediately
below its caller then keeps refusing the write, which is the safe direction.

This is the third defect of one family found on this surface, after `auth
enable` and `tools add`: a command that performs a write, never checks it, and
reports the outcome it intended rather than the one it achieved.

### The last four defects: an interrupted resolution, a wedged backlog, a withdrawn update, and a deletion that destroyed unagreed bytes

**An interrupted resolution leaves the pin, not a hidden orphan** (section 59).
Staging a pin renames it to `.resolving-<id>.<pid>` before the caller commits,
and both read paths skip dot-prefixed names — which is exactly what makes the
rename atomic, and exactly what makes a crash in that window invisible. Kill the
process between the rename and the commit and the conflict is neither resolved
nor listed: `sync conflicts` stops asking about it, the address stays pinned
against future writes, and the bytes become litter with no name an operator can
type. `sync_conflicts` therefore recovers as it reads. A staged record whose
owning pid is dead is unstaged back to its original id before the listing is
produced, so the operator sees the conflict again, unchanged. Recovery is
one-sided on purpose: a staged record whose owner is *still running* is left
alone, because that is a resolution in progress and not wreckage.

Honest limit, shared with the task sweep below: liveness is `ps -p`, so a
recycled pid belonging to an unrelated process reads as alive and defers
recovery to a later sweep. That errs toward leaving a staged record in place and
never toward clearing a live one, and the next pass re-detects the divergence
regardless.

**An abandoned task record stops deferring forever** (section 60).
A `--disruptive` update is held back while `tasks/active` is non-empty, which is
the whole point of the deferral contract — but the record is created by the
worker and removed by the worker, so a worker killed mid-task leaves its record
behind permanently. The failure is quiet and indefinite: every disruptive update
defers, and the operator keeps reading "retried on the next apply" from a tick
that will never apply anything. Reconciliation now reaps a record whose named
owner is dead. It is deliberately one-sided in the other direction from the
above: a record that names *nobody* is treated as active work, because the
alternative is reaping a task whose ownership this machine simply cannot see and
interrupting it — the one outcome the interview never authorized.

**Withdrawing a tool grant withdraws its pending update** (section 61).
`tools install` appends to the deferred list and only `tools apply` rebuilds it,
so on a machine whose tick is not running, `tools rm` removed the manifest
record and left the deferred entry standing. `tools deferred` then named a tool
that is no longer fleet-managed, and the tick kept printing a retry count for an
update `apply` would never perform, because `apply` walks the manifest. That is
worse than cosmetic: the authorization boundary is the manifest, and a pending
action outliving the grant that authorized it is precisely what "no blanket
permission" forbids. `tools rm` now drops the tool's deferred entry with the
record.

**A profile deletion never destroys what was not agreed** (section 62).
A tombstone for a profile's existence record is a recursive `rm` of the whole
profile, and it was performed on the strength of the tombstone alone. A peer
deleting a profile therefore destroyed, on every other machine: an edit made
locally that the deleting peer never saw, an address under an explicit
machine-specific exception, an unresolved conflict's bytes, and any file the
fleet does not replicate at all — machine-only data and withheld credentials.
Replication is allowed to converge; it is not allowed to delete what nobody
agreed to lose. `sync_profile_blockers` now walks the subtree *before* anything
is unlinked and reports each such file by reason (`unsynced`, `excepted`,
`conflict`, `local-only`); a withheld credential is reported as `unsynced` like
anything else, since naming it by class would disclose that it exists. A
non-empty list makes `sync_write` return 4 — "blocked, nothing removed",
distinct from 1 (failed) and 3 (the disk moved) — and the appliers turn that
into a visible conflict carrying `remote:deleted`. The operator resolves it the
normal way, and `--remote` calls back with `force`, which is the only path that
skips the gate.

The regression that fix caused is worth recording next to it. `find -L` follows
the symlink of an *adopted* profile, so the adopted target's contents — never
agreed with the deleting peer, because they came from outside the fleet's
storage — read as `unsynced` and blocked the deletion. Every adopted profile the
fleet ever deleted would have wedged. The symlink branch in
`sync_profile_remove` therefore runs *before* the blocker gate: removing an
adopted profile unlinks one symlink and destroys no bytes, so a gate that exists
solely to prevent data loss has nothing to weigh. The adopted target is left
standing, which is the same rule adopted profiles follow everywhere else here.
Section 54 caught this, which is the argument for running the existing suite
against a fix rather than only the tests written for it.

## Running the sync suite

`scripts/test-sync.sh` is the behavioural suite for profile replication,
conflicts, credential propagation and managed tools. It is 75 sections and
~540 assertions, and `scripts/test-fleet.sh` invokes it after the transport
sections, so the top-level command is:

    sh scripts/test-fleet.sh          # transport + sync
    sh scripts/test-sync.sh           # sync only
    N2_FLEET_SUITES=transport sh scripts/test-fleet.sh   # transport only

### Runtime

The sync suite takes **roughly 350-450 seconds** on an M-series Mac. The cost
is real work, not padding: the sections build a fleet forward across several
peers, each a separate `agents` process under its own HOME, and every
assertion is a real CLI invocation against real on-disk state. The carrier is
`exec`, not ssh -- the sync suite exercises replication, conflict and tool
behaviour over local peer processes, and the live-sshd transport coverage
lives in `scripts/test-fleet.sh` (run it with `N2_FLEET_REQUIRE_LIVE_SSH=1` to
make a skipped ssh section a hard failure). It is not
uniform — sections 1-12 run at about 2.4s each, sections 13-38 at about 6.4s,
and the tail is heavier still. Extrapolating the total from an early sample
therefore understates it by roughly 2.5x. Budget the full runtime; a caller
that caps the run below it will see a truncated log with no final tally, which
looks like a hang and is not one.

### Resuming

Sections build forward against one evolving fixture, so a section cannot run
against a fixture that has not reached it. Two variables make a long run
resumable across invocations:

    N2_SYNC_BASE=<dir>        put the fixture somewhere durable
    N2_SYNC_KEEP=1            do not delete the fixture at exit
    N2_SYNC_STOP_AFTER=<n>    stop cleanly after section <n> and print a tally
    N2_SYNC_START_AT=<n>      resume at section <n> against an existing fixture

For example, to run 1-34 and then the remainder against the same fixture:

    N2_SYNC_BASE=/tmp/n2s N2_SYNC_KEEP=1 N2_SYNC_STOP_AFTER=34 sh scripts/test-sync.sh
    N2_SYNC_BASE=/tmp/n2s N2_SYNC_KEEP=1 N2_SYNC_START_AT=35  sh scripts/test-sync.sh

`N2_SYNC_START_AT` refuses to run when `N2_SYNC_BASE` holds no fixture, and
prints the two commands that would build one, so a resumed run cannot silently
grade itself against an empty tree. A resumed chain over one fixture covers the
same states as a single invocation, but only an uninterrupted run prints a
single 1-75 tally; prefer one run when the caller can afford the wall clock.

## Residual limitations of the hardened trust boundary

Three things the sync hardening deliberately does not do, recorded so a later
reader does not mistake them for oversights.

**Approval is per command, not per tool lineage.** `tools approve <name>`
records the exact install and check commands it saw. A peer that later edits
either string produces a new pending approval, which is the point — but it also
means a purely cosmetic edit (a reordered flag, a changed mirror URL) costs the
operator another approval on every machine. There is no similarity heuristic,
and adding one would be the same trust decision made by guesswork.

**The `mcp` class is gated wholesale, not field by field.** MCP entries carry
secrets in shapes the key-name scanner cannot see — `--api-key` in `args`, a
`postgresql://user:pass@host` URL, a `Cookie` header, `GH_PAT` in `env` — so the
whole class rides on the same per-vendor `sync_secret_shareable` opt-in as
`auth`. A vendor whose MCP config is genuinely secret-free therefore still needs
the opt-in to replicate its MCP entries at all. Splitting the class into a
public half and a secret half would reintroduce the scanner as the boundary,
which is precisely what this decision removed.

**A declared base retires only its own sender's pin.** An operator holding
conflicts from two peers must answer both; a third peer arriving with a matching
base clears nothing on the other peers' behalf. This is strictly more prompting
than a global fast-forward would produce, and it is the conservative direction:
the alternative destroys bytes a pin was preserving on a question the operator
never answered.

Command approval and execution use the same captured manifest record, including
when a peer replaces the manifest during an apply. Local `tools add` approves
the command arguments supplied by the operator, rather than rereading a record
that a peer could replace after the manifest lock is released. Section 75 tests
manifest replacement between installer capture and approval checking.

### Worker verification checkpoint, 2026-09-22

The unchanged preamble and isolated sections 72–75 of `scripts/test-sync.sh`
passed together against a fresh fixture: 43 assertions passed, zero failed.
This subset covers command approval, changed check commands, version bumps,
active-task deferral, MCP opt-in, conflict ownership and manifest replacement.
It does not substitute for the complete suite or live SSH verification.

`./scripts/test.sh` had exited 1 during Swift typechecking under the restricted
worker sandbox: the compiler reported `sandbox-exec: sandbox_apply: Operation
not permitted` and could not load `SwiftUIMacros.StateMacro` from
`swift-plugin-server`. That was an environment restriction, not a code defect.
Rerun with Swift compiler macro execution permitted, `./scripts/test.sh` exits 0
("All tests passed"), including the `swift build -c release --product
N2AgentsTray` step. Residual limitation: any environment that denies
`sandbox_apply` to `swift-plugin-server` cannot build the tray and will fail
`./scripts/test.sh` for that reason alone.
Shell syntax validation and `git diff --check` passed.

The restricted worker sandbox also denies `ps`, including `ps -p` for its own
shell. Sections 59 and 60 rely on that command to distinguish live owners from
dead owners. Running sections 53-60 under this restriction produced 85 passing
assertions and seven failures: live conflict resolution was recovered as if
abandoned, and live task records were reaped. These results cannot verify the
normal process-liveness behavior. Run these tests with process inspection
permitted. The runtime currently treats a failed `ps` lookup as a dead owner;
environments that prohibit process inspection are therefore unsupported for
conflict recovery and managed-tool task deferral.

Rerunning from the saved section-52 fixture with process inspection permitted
passed all 92 assertions in sections 53-60, exit 0:

    N2_SYNC_BASE=/tmp/n2-fix N2_SYNC_KEEP=1 N2_SYNC_START_AT=53 N2_SYNC_STOP_AFTER=60 sh scripts/test-sync.sh

The fixture is now stopped after section 60. This checkpoint also reran
`./scripts/test.sh` with compiler macro execution permitted; it exited 0 with
`All tests passed`.

The next bounded runs, also with process inspection permitted, exited 0:

    N2_SYNC_BASE=/tmp/n2-fix N2_SYNC_KEEP=1 N2_SYNC_START_AT=61 N2_SYNC_STOP_AFTER=65 sh scripts/test-sync.sh
    N2_SYNC_BASE=/tmp/n2-fix N2_SYNC_KEEP=1 N2_SYNC_START_AT=66 N2_SYNC_STOP_AFTER=68 sh scripts/test-sync.sh

Sections 61-65 passed 57 assertions, and sections 66-68 passed 21 assertions.
These cover withdrawn tool grants, deletion conflicts preserving local data,
and credential keys with escaped, multiline, TOML, camelCase and hyphenated
spellings. The final bounded run, with process inspection permitted, exited 0:

    N2_SYNC_BASE=/tmp/n2-fix N2_SYNC_KEEP=1 N2_SYNC_START_AT=69 N2_SYNC_STOP_AFTER=75 sh scripts/test-sync.sh

Sections 69-75 passed all 63 assertions. The log is
`/tmp/n2-sync-hardening-69-75-permitted.log`. These checks cover tool exceptions,
missing vendor folders, file modes, local command approval, MCP opt-in,
sender-owned conflict retirement and approval during manifest replacement.
The saved fixture has now consumed all 75 sections; do not reuse it to rerun
the tail, even though its `.through` file still says 68. The final tally does
not update that marker.

`./scripts/test.sh` also exited 0 with compiler macro execution permitted,
reporting `All tests passed`; its log is
`/tmp/n2-sync-hardening-regression-53.log`. The full required
`N2_FLEET_REQUIRE_LIVE_SSH=1 ./scripts/test-fleet.sh` remains unverified here.
These bounded results do not satisfy that completion gate.

A fresh worker preflight on 2026-09-22 confirmed two sandbox restrictions:
`ps -p $$ -o pid=` returned `operation not permitted`, and Python's
`socket.bind(('127.0.0.1', 0))` returned `EPERM`. No SSH daemon or background
verification job was launched. Shell syntax checks and `git diff --check`
passed. The controller must own the full run in an environment that permits
process inspection, Swift compiler macros, and loopback SSH.

Run the following from the candidate workspace. Clearing every sync test
override prevents a saved fixture, alternate source tree, or partial section
range from producing an incomplete gate result:

```sh
(
	unset N2_FLEET_SUITES N2_FLEET_KEEP
	unset N2_SYNC_BASE N2_SYNC_KEEP N2_SYNC_START_AT N2_SYNC_STOP_AFTER
	unset N2_SYNC_REPO N2_SYNC_TRIMMED N2_SYNC_SECTIONS
	./scripts/test.sh && N2_FLEET_REQUIRE_LIVE_SSH=1 ./scripts/test-fleet.sh
)
```

Both commands must exit 0 before marking sync hardening implemented.

## Dispatch, handoff and the task lifecycle (fleet-exec.sh)

Dispatcher agent policy is configured with `agents fleet task preferences set
<agent>...`, inspected with `preferences show`, and cleared with `preferences
reset`. With no configured policy all supported agents are candidates. The
explicit list filters eligibility before completion-time ranking; its order has
no ranking effect, and a pin cannot override an exclusion. Invalid updates keep
the previous policy. This setting is local to the dispatching machine, stored
atomically at `fleet/tools/agents.allowed` and replicates as the sync address
`tools|-|-|agents.allowed`, sharing the reserved fleet-level slot with the
managed-tool manifest but addressed separately so one can be excepted without
the other. Absent means no restriction. A machine holds itself out with the
ordinary exception `agents fleet sync except add tools - - agents.allowed`,
which is machine-local like every other exception.
`scripts/test-exec-preferences.sh` checks the planner with synthetic capability
reports, including pin refusal and ordering. It does not verify provider login.


### What a task is

A task is a directory under `fleet/tasks/<id>`: `meta` (key=value — role, state,
peer, machine, vendor, label, eta, created, and `retry_of`/`retried_as` when
cross-linked), the request, the optional context, the optional workspace
archive, and `out/`. The origin and the worker each keep their own record for
the same id, which is what makes reconciliation after an outage a comparison
rather than a guess.

### Eligibility, then speed — in that order

`exec_plan` filters before it ranks, and says why it excluded each candidate:

1. Capability: `--requires` entries are matched against the peer's advertised
   capabilities. A missing requirement is an exclusion, never a penalty.
2. Agent access: a candidate that cannot run the pinned or preferred vendor is
   out. Unknown auth state is an exclusion unless `--allow-unknown-auth`.
3. Reachability: an offline peer is excluded and named as offline.

Only survivors are ranked, by expected completion = queue depth + workspace
transfer + environment preparation + execution estimate. Missing data is
reported as unknown rather than silently scored as zero; `--plan` prints the
ranked table and dispatches nothing.

Pins compose: `--machine` alone, `--agent` alone, or both. A pin narrows the
candidate set and is never overridden by a faster candidate — if the pinned
combination is ineligible the dispatch fails loudly instead of substituting.

### Handoff

`--workspace` archives the working tree as it actually is: staged, unstaged,
untracked and deleted files all cross the wire, because remote work is not
restricted to committed state. `exec_workspace_path` refuses `..` components;
a refused transfer leaves the source tree untouched. `--context` / `--context-file`
carries the task, constraints, decisions, progress and next steps so the
receiving agent does not repeat discovery.

### Notifications

Completion and disconnection are `fleet_event` records *and* a fan-out:
`exec notify` broadcasts to every approved peer, each of which appends to its
own notice journal (`agents fleet task notices`, the in-app feed) and calls the
native notifier. Fan-out uses `fleet_broadcast`, so an offline peer is a line
in the report and never an error.

`N2_FLEET_NOTIFY`, when set, is run as a command for every fan-out event with
`N2_NOTIFY_KIND` and `N2_NOTIFY_TASK` in its environment. Unset, the runtime
falls back to the native path (`terminal-notifier`, else `osascript -e
'display notification'`). This is the seam the tray uses, and the seam a
headless test uses to observe desktop delivery without a desktop session —
`scripts/test-exec.sh` points it at a per-peer `banner.log`, so "the banner
fired on beta" and "on gamma" are two separate files rather than one ambiguous
marker.

### Outputs stay put

Nothing copies an output anywhere on completion. The worker writes to its own
`out/`, the origin is *told* it finished, and that is all. Distribution is
`agents fleet task distribute <src> --name <n> --machine <p> | --all` — push,
explicit, one named payload at a time. A traversing `--name` is refused, and
distribution writes only what it names, leaving unrelated content at the
destination intact.

### Disconnect and wait

`reconcile` is the only lifecycle verb that touches an unreachable worker, and
it reports `unreachable` rather than re-dispatching: an outage never mints a
task. The worker keeps running its copy while the link is down; when the link
returns, reconcile reads the worker's own record and adopts its outcome. Only
`retry` mints a new task, only when the operator asks, and the new task carries
its own id cross-linked to the original in both directions — the original keeps
its own outcome.

### Managed updates and active work

`sync`'s deferral asks `exec_tasks_active` whether this machine is running a
task. A disruptive update defers while a task is running and applies on the
next tick after it ends; a non-disruptive one applies immediately, running task
or not. Nothing in this path kills or interrupts a task.

"Running" is a liveness fact, not a status field a crashed worker could leave
behind: each active task writes a record under the active dir naming the pid
that owns the work, and `sync_tasks_reap` files any record whose pid no longer
answers `ps -p` as stale before the count is taken. That makes the pid the
load-bearing value, and the first version of it was wrong. `exec_run_local`
recorded `$$`, but it is itself invoked with `&` (fleet-exec.sh) and `$$` is
not re-set in a subshell, so the record named the short-lived request handler,
which was already gone by the next tick. Reap filed every live task as stale,
the active count read zero, and a `--disruptive` update would have applied
straight through running work. The command subshell is now backgrounded and
`$!` — the worker's own pid — is what the record carries.

The record is opened *before* the command is launched, carrying only its task
id and no pid. Reap's rule for a record that declares no owner is to leave it
active, so the launch window counts as busy: the race resolves toward deferring
an update, never toward running one against live work.

### Task CLI surface

    agents fleet task run <command…>          dispatch; prints "<id>\t<state>\t<machine>"
        --workspace <dir>                     send the tree, dirty files and all
        --context <text> | --context-file <f> what the receiver needs to not rediscover
        --requires a,b                        task requirements vs. capabilities
        --machine <p> --agent <v>             pins; either, both, or neither
        --label <s>                           operator-facing name
        --allow-unknown-auth                  proceed when auth state is unknown
        --plan                                show the ranked plan, dispatch nothing
    agents fleet task list [--porcelain]
    agents fleet task show <id>
    agents fleet task reconcile [<id>]        re-ask workers after an outage
    agents fleet task retry <id> [pins]       explicit; mints a NEW cross-linked id
    agents fleet task fetch <id> [--output n]
    agents fleet task distribute <src> --name <n> --machine <p> | --all
    agents fleet task notices                 the local notice journal

### Running the exec suite

    sh scripts/test-exec.sh          # 13 sections; includes estimate-order checks

`scripts/test-fleet.sh` — the declared fleet verification command — runs this
suite after the replication suite, so nothing here depends on someone
remembering a third command. `N2_FLEET_SUITES=transport` runs the transport
sections alone.

Every peer is a real `agents` process under its own HOME inside an mktemp
fixture; nothing touches a real fleet or reaches the network. Sections:
eligibility refusal; plan honesty; the three pin combinations; dirty-workspace
transfer and execution; completion fan-out in-app and on the desktop; outputs
staying put; explicit targeted distribution and traversal refusal;
disconnect-and-wait; explicit retry identity; dispatch surviving the
destruction of the originating machine; and the deferral rule reading live task
state — a `--disruptive` managed update held off while a real dispatched task
runs, the installer's absence checked against the filesystem rather than
stdout, and the same installer landing once the work ends so the negative is
not vacuous.

Sections 12 and 13 cover required tools and ranking order. A tool on PATH can
satisfy a requirement without a managed designation. A missing managed tool
adds preparation time without running its installer during planning. Ranking
tests invert execution history and transfer speed to check both orderings.
The statistics reader uses only the mean from a `mean count` record; the
sample count must not change the estimated seconds. The unequal-count ranking
regression was added after the last full execution-suite run and still needs
that run. Focused reader checks cover a mean with a count, a malformed mean,
and a single-field bandwidth value.

### Open execution gaps found during source inspection

The execution assignment is not complete. Dispatch now persists the selected
worker before sending a request and attempts delivery to that worker only.
A failed transport call or malformed acknowledgment leaves an `unreachable`
task with the original ID and destination for reconciliation. Even an explicit
refusal is conservatively treated as uncertain until inspected; the operator
can request a new retry. No fallback worker starts automatically. Completion
received before acknowledgment is preserved.

`scripts/test-exec-delivery.sh` injects a lost acknowledgment after acceptance,
a malformed acknowledgment, completion before acknowledgment, and normal
delivery. All four focused scenarios pass, including reconciliation to
completion without a second delivery. This is transport-boundary fault
injection, not proof of live SSH delivery. The script runs at the beginning of
`scripts/test-exec.sh`; the full process suite still needs a controller run
against this change.

`task run` keeps explicit shell-command behavior. `task run --prompt` instead
sends the request and continuation context to the selected agent on stdin.
The initial prompt adapters support Claude (`claude --print`) and Codex
(`codex exec -`), checked against installed CLI help on 2026-09-22. They use
the active provider profile and its existing isolation variable. Missing
profile slots and unsupported adapters fail closed; prompt planning excludes
unsupported providers. No permission-bypass flags are supplied. Provider
permissions and workspace trust can therefore still prevent unattended work.
This is not evidence of a successful live provider session.

Task bundles and retained requests carry the execution mode, including explicit
retries. Multiline prompts remain intact. The default notification label is
"Fleet task", so request contents are not automatically copied into notices.
`scripts/test-exec-prompt.sh` checks arguments, stdin, profile isolation,
unsupported adapters, missing profiles and nonzero exits using synthetic CLI
executables. It does not authenticate to a provider.

Required tools travel in the bundle and are rechecked before launch. The
worker uses the managed-installer lock and existing designation checks. Failed
or deferred preparation fails the task with rc 125 without launching its
command. No retry starts automatically. Other provider prompt adapters,
shared preference propagation and full execution-suite verification remain
open before claiming the dispatch acceptance criterion.

The focused test scripts/test-exec-prepare.sh uses an isolated HOME and real
controlled shell installers to cover missing tools, updates, active-task
deferral, installer failure, unmanaged PATH checks, malformed requirements,
and bundle inclusion. Its active marker deliberately omits a PID, exercising
the conservative active-state rule without relying on sandbox process access.
The full process suite still requires a controller run.
