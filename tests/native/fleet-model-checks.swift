import Foundation

// Feeds the parsers the exact bytes the CLI produced in the live fixture.
let statusText = """
self\talpha\tSHA256:QaPiIaJuBo4eI12Uhd/N7xdnX1Z21DKpOWWnq5xUd0w
SHA256:QaPiIaJuBo4eI12Uhd/N7xdnX1Z21DKpOWWnq5xUd0w\talpha\tself\tapproved\tself
SHA256:zwYajpHfuNHbjoQvs1u5Et3NFmjK4iHiZ+u/0n4H/Pg\tbeta\texec\tapproved\tapproved
pending\tSHA256:abc\tgamma
"""
let syncText = """
self\talpha\tSHA256:QaPiIaJuBo4eI12Uhd/N7xdnX1Z21DKpOWWnq5xUd0w
resources\t1
agreed\t0
exceptions\t0
conflicts\t0
auth\tclaude\tpartial\toff
auth\tcodex\tpartial\toff
auth\tgrok\tunverified\toff
auth\tgemini\tunsupported\toff
auth\tcursor\tunverified\toff
auth\topencode\tunsupported\toff
"""
let conflictText = "5de976a97424\ttools|-|-|manifest\tSHA256:XIeYcI43WqZwPTaq/PNVCM0NFlJ9tJVLaN1eRmlThTU\tremote:present\tscope:in"

var failed = 0
func check(_ name: String, _ cond: Bool) {
    print((cond ? "ok " : "FAIL ") + name); if !cond { failed += 1 }
}

let d = FleetData.parseStatus(statusText)
check("status: initialized", d.initialized)
check("status: machine is alpha", d.machine == "alpha")
check("status: two peers parsed", d.peers.count == 2)
check("status: self row identified", d.peers[0].isSelf && d.peers[0].machine == "alpha")
check("status: pending row is not a peer", d.pending.count == 1 && d.pending[0].machine == "gamma")
check("status: self is a dispatch destination", d.destinations.contains { $0.isSelf })
check("status: uninitialized fleet stays uninitialized",
      !FleetData.parseStatus("fleet\tuninitialized").initialized)

let s = FleetSync.parse(syncText)
check("sync: counters read", s.resources == 1 && s.agreed == 0 && s.conflicts == 0)
check("sync: six auth rows", s.auth.count == 6)
check("sync: gemini reported unsupported", s.auth.first { $0.vendor == "gemini" }?.support == .unsupported)
check("sync: unsupported lab is not enabled", s.auth.first { $0.vendor == "gemini" }?.enabled == false)
check("sync: an unknown support word is dropped, not guessed",
      FleetSync.parse("auth\tnewlab\tmagic\ton").auth.isEmpty)

let c = FleetConflict.parse(conflictText)
check("conflict: parsed", c.count == 1)
check("conflict: address becomes a readable label", c[0].label == "tools · manifest")
check("conflict: remote:present is not a deletion", !c[0].isDeletion)
check("conflict: remote:absent reads as a deletion",
      FleetConflict.parse("id\ta|b\tdig\tremote:absent\tscope:in")[0].isDeletion)

check("notice: real feed line parses",
      FleetNotice.parse("1758500000\tcompleted\tt-abc\tbeta\tfinished rc=0").first?.machine == "beta")
check("notice: title names the machine",
      FleetNotice.parse("1758500000\tcompleted\tt-abc\tbeta\tx").first?.title == "Task finished on beta")
check("notice: unknown kind dropped", FleetNotice.parse("1758500000\tgossip\tt\tm\tx").isEmpty)

let t = FleetTask.parse("t-abc\tunreachable\tclaude\t\tbuild the thing\tbeta")
check("task: disconnected is stranded, not finished", t[0].isStranded && !t[0].isFinished)
check("task: done rc=0 succeeded",
      FleetTask.parse("t\tcompleted\tclaude\t0\tl\tm")[0].succeeded)
check("task: done rc=1 did not succeed",
      !FleetTask.parse("t\tcompleted\tclaude\t1\tl\tm")[0].succeeded)

// Exact bytes from `agents fleet tools list` / `status` in a live fixture.
let toolList = "ripgrep|14.1.0|echo 13.0.0|true||approved\njq||false|true|disruptive|approved"
check("tool: pending local approval remains visible", FleetTool.parseStates("jq\tpending-approval")["jq"] == .pendingApproval)
let toolStatus = "ripgrep\tupdate\njq\tinstall"
let joined = FleetTool.join(list: toolList, status: toolStatus, deferred: "jq\tinstall")
check("tool: both designations parsed", joined.count == 2)
check("tool: version mismatch reads as update", joined[0].id == "ripgrep" && joined[0].state == .update)
check("tool: missing tool reads as install", joined[1].id == "jq" && joined[1].state == .install)
check("tool: both need work", joined.allSatisfy { $0.needsWork })
check("tool: disruptive flag only on the tool that declared it",
      !joined[0].disruptive && joined[1].disruptive)
check("tool: a deferred tool is marked held, not missing",
      !joined[0].deferred && joined[1].deferred)
check("tool: an undesignated tool never appears", !joined.contains { $0.id == "curl" })
check("tool: a malformed manifest line is shown, not skipped",
      FleetTool.parseList("invalid|brokenone").first.map { $0.id == "brokenone" && $0.state == .invalid } == true)
check("tool: empty manifest stays empty", FleetTool.parseList("").isEmpty)
check("tool: an unknown state word is dropped", FleetTool.parseStates("x\tmagic").isEmpty)

// --- exceptions -------------------------------------------------------------
// `sync except list` prefixes each row with the number `except rm` takes.
// Keeping that prefix in the address made the panel label read "1:profile".
let exceptions = FleetException.parse("""
1:profile|Work|claude|*
2:skills|-|-|review.md
""")
check("except: both rows parsed", exceptions.count == 2)
check("except: the row number is not part of the address",
      exceptions[0].id == "profile|Work|claude|*")
check("except: the label drops the empty fields", exceptions[1].label == "skills · review.md")
check("except: the CLI's own number is what a withdrawal uses",
      exceptions[0].index == 1 && exceptions[1].index == 2)
check("except: an unnumbered row still parses",
      FleetException.parse("profile|Work|claude|*").first?.id == "profile|Work|claude|*")
check("except: nothing excepted stays empty", FleetException.parse("").isEmpty)

// Dispatch pins. The CLI takes --machine and --agent independently, so all
// four combinations have to survive the panel: pinning one must not imply the
// other, and "let the fleet choose" must send nothing rather than a wildcard.
check("pins: neither pin sends no flag",
      FleetPins.flags(machine: nil, agent: nil).isEmpty)
check("pins: a machine pin alone",
      FleetPins.flags(machine: "seths-mac-mini", agent: nil) == ["--machine", "seths-mac-mini"])
check("pins: an agent pin alone",
      FleetPins.flags(machine: nil, agent: "claude") == ["--agent", "claude"])
check("pins: both pins, machine first",
      FleetPins.flags(machine: "seth-webster-m4", agent: "cursor")
        == ["--machine", "seth-webster-m4", "--agent", "cursor"])
check("pins: an empty choice is not a pin",
      FleetPins.flags(machine: "", agent: "").isEmpty)

// --- the announce-once gate -------------------------------------------------
// This is the rule that decides whether a finished task produces a desktop
// banner. It used to live inside AppDelegate.announce and infer "not read yet"
// from an empty seen-set, which swallowed the first completion of any launch
// that started with a quiet feed — a fresh enrollment, or simply no recent
// activity. hasRead is separate for exactly that case.
func notice(_ epoch: Int, _ kind: FleetNotice.Kind = .done, _ task: String = "t1") -> FleetNotice {
    FleetNotice(at: Date(timeIntervalSince1970: TimeInterval(epoch)),
                kind: kind, task: task, machine: "seth-webster-m4", text: "finished")
}

var quiet = FleetAnnouncer()
check("announce: an empty first read announces nothing", quiet.adopt([]).isEmpty)
check("announce: the first notice after an empty launch IS announced",
      quiet.adopt([notice(100)]).map { $0.id } == [notice(100).id])

var busy = FleetAnnouncer()
check("announce: a non-empty first read is adopted silently",
      busy.adopt([notice(1), notice(2, .failed)]).isEmpty)
check("announce: a redraw of the same feed says nothing again",
      busy.adopt([notice(1), notice(2, .failed)]).isEmpty)
check("announce: only the new notice is announced",
      busy.adopt([notice(1), notice(2, .failed), notice(3, .disconnected)]).map { $0.id }
        == [notice(3, .disconnected).id])
check("announce: a notice already announced never repeats",
      busy.adopt([notice(3, .disconnected)]).isEmpty)
check("announce: a feed that shrinks does not re-announce what is left",
      busy.adopt([notice(3, .disconnected)]).isEmpty)
check("announce: two new notices arrive in feed order",
      busy.adopt([notice(3, .disconnected), notice(4), notice(5, .delivered)]).map { $0.id }
        == [notice(4).id, notice(5, .delivered).id])

// Separate instances do not share state: one machine adopting a feed must not
// silence another.
var other = FleetAnnouncer()
check("announce: a second machine still announces its own first notice",
      { _ = other.adopt([]); return other.adopt([notice(4)]).count == 1 }())

// Exit status too, so the runner catches a regression even if it only reads $?.
let dispatch = FleetDispatchSpec(task: "Inspect $(touch NEVER)", prompt: true, workspace: "/tmp/work tree", contextFile: "/tmp/context", requirements: "git,node", machine: "beta", agent: "codex")
check("dispatch: prompt, workspace and context are explicit", dispatch.arguments.contains("--prompt") && dispatch.arguments.contains("/tmp/work tree") && dispatch.arguments.contains("/tmp/context"))
check("dispatch: shell text remains data", dispatch.task == "Inspect $(touch NEVER)")
check("dispatch: exclusions alone are not a candidate", !FleetDispatchSpec.hasCandidate("excluded:\nx\tpeer\tbeta\tcodex\tagent-not-installed"))
check("dispatch: a ranked plan has a candidate", FleetDispatchSpec.hasCandidate("rank\tpeer\tmachine\tagent\teta\tassumed\n1\tp\tbeta\tcodex\t1s\tnone"))

check("task: production unreachable is stranded",
      FleetTask.parse("t\tunreachable\tcodex\t\tl\tm\tdispatcher")[0].isStranded)
check("task: observer cannot retry or fetch",
      !FleetTask.parse("t\tcompleted\tcodex\t0\tl\tm\tobserver")[0].canFetch &&
      !FleetTask.parse("t\tunreachable\tcodex\t\tl\tm\tobserver")[0].canRetry)
check("task: dispatcher can retry and fetch",
      FleetTask.parse("t\tcompleted\tcodex\t0\tl\tm\tdispatcher")[0].canFetch &&
      FleetTask.parse("t\tunreachable\tcodex\t\tl\tm\tdispatcher")[0].canRetry)

print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
