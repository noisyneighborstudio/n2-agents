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
