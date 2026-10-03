import Foundation

// The fleet half of the panel's state. Every type here parses one CLI verb's
// output — the CLI is the behavior authority, so nothing in the app decides
// fleet policy. Unknown enum values are dropped the way Usage.Note drops them:
// a newer CLI may add states, and an older app must not crash or invent one.

/// One row of `agents fleet peers`:
/// `peerid \t machine \t transport \t state \t reachability`.
struct FleetPeer: Identifiable, Equatable {
    /// The durable enrollment decision, recorded locally.
    enum State: String {
        case approved, pending, denied, revoked
    }

    /// What the last probe saw. `self` is this machine; `approved` appears when
    /// `peers --no-probe` echoes the state instead of dialling.
    enum Reach: String {
        case online, offline, `self`, approved, pending, denied, revoked
    }

    let id: String          // the peer's ed25519 fingerprint — the identity
    let machine: String
    let transport: String   // tailscale | ssh | exec | self
    let state: State
    let reach: Reach

    var isSelf: Bool { reach == .`self` }
    /// Only an approved peer that answered is a dispatch destination.
    var isOnline: Bool { reach == .online || reach == .`self` }
    var canDispatch: Bool { state == .approved && isOnline }

    static func parse(_ text: String) -> [FleetPeer] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let state = State(rawValue: f[3]), let reach = Reach(rawValue: f[4])
            else { return nil }
            return FleetPeer(id: f[0], machine: f[1], transport: f[2], state: state, reach: reach)
        }
    }
}

/// One row of `agents fleet pending`:
/// `peerid \t machine \t transport \t requested_at`. A machine that reached us
/// but has not been approved — reachability is never enrollment.
struct FleetPending: Identifiable, Equatable {
    let id: String
    let machine: String
    let transport: String
    let requestedAt: Date?

    static func parse(_ text: String) -> [FleetPending] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, !f[0].isEmpty else { return nil }
            return FleetPending(id: f[0], machine: f[1],
                                transport: f.count > 2 ? f[2] : "",
                                requestedAt: f.count > 3 ? TimeInterval(f[3]).map(Date.init(timeIntervalSince1970:)) : nil)
        }
    }
}

/// One `auth` row of `agents fleet sync status`:
/// `auth \t vendor \t support \t state`. The support word is the CLI's verdict
/// on that provider's credential portability — the app reports it, never
/// upgrades it, so an unsupported lab can't be made to look like it syncs.
struct FleetAuth: Identifiable, Equatable {
    enum Support: String {
        case full, partial, unverified, unsupported
    }

    let vendor: String
    let support: Support
    let enabled: Bool

    var id: String { vendor }

    /// What the row says when the user asks why a lab isn't syncing.
    var explanation: String {
        switch support {
        case .full:        return "Sign-in and reset propagate to machines sharing this profile."
        case .partial:     return "Some credential changes propagate; refresh and reset are not fully verified."
        case .unverified:  return "Credential portability has not been verified for this lab — sync is off by default."
        case .unsupported: return "This lab's credentials are machine-bound and are never synced."
        }
    }
}

/// `agents fleet sync status`: a self line, four counters, then the auth rows.
struct FleetSync: Equatable {
    var machine = ""
    var selfID = ""
    var resources = 0
    var agreed = 0
    var exceptions = 0
    var conflicts = 0
    var auth: [FleetAuth] = []

    /// Replication is settled when every resource agreed and nothing is held.
    var settled: Bool { conflicts == 0 && resources > 0 && agreed >= resources - exceptions }

    static func parse(_ text: String) -> FleetSync {
        var s = FleetSync()
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let key = f.first else { continue }
            switch key {
            case "self" where f.count >= 3:
                s.machine = f[1]; s.selfID = f[2]
            case "resources"  where f.count >= 2: s.resources = Int(f[1]) ?? 0
            case "agreed"     where f.count >= 2: s.agreed = Int(f[1]) ?? 0
            case "exceptions" where f.count >= 2: s.exceptions = Int(f[1]) ?? 0
            case "conflicts"  where f.count >= 2: s.conflicts = Int(f[1]) ?? 0
            case "auth" where f.count >= 4:
                guard let support = FleetAuth.Support(rawValue: f[2]) else { continue }
                s.auth.append(FleetAuth(vendor: f[1], support: support, enabled: f[3] == "on"))
            default: continue
            }
        }
        return s
    }
}

/// One row of `agents fleet sync conflicts`:
/// `id \t address \t digest \t remote:<state> \t scope:<in|out>`.
/// A conflict is never resolved by the app on its own — the user picks, which
/// is the whole point of the row existing.
struct FleetConflict: Identifiable, Equatable {
    let id: String
    let address: String     // e.g. profile|Work|claude|settings — the resource
    let digest: String
    let remote: String      // present | absent
    let inScope: Bool

    /// `settings|Work|claude|settings.json` reads as "Claude Code settings.json in Work".
    var label: String { FleetWords.resource(address) }

    /// A deletion on one side and an edit on the other — worth saying out loud,
    /// because "keep mine" means something different when the other side is gone.
    var isDeletion: Bool { remote == "absent" }

    static func parse(_ text: String) -> [FleetConflict] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, !f[0].isEmpty else { return nil }
            let remote = f.count > 3 ? f[3].replacingOccurrences(of: "remote:", with: "") : ""
            let scope = f.count > 4 ? f[4].replacingOccurrences(of: "scope:", with: "") : "in"
            return FleetConflict(id: f[0], address: f[1], digest: f[2], remote: remote, inScope: scope == "in")
        }
    }
}

/// A fleet-managed utility. Two verbs describe one tool and the panel joins
/// them: `tools list` is the designation (pipe-separated, as the manifest is
/// stored) and `tools status` is what this machine actually has. A tool only
/// appears here because the user designated it — nothing else on the machine
/// is in scope, and the UI never offers to adopt one implicitly.
struct FleetTool: Identifiable, Equatable {
    /// The CLI's words, not ours. `unmanaged` means the manifest has no line
    /// for it; `invalid` means the line is there but malformed — which is a
    /// thing to show the user, not to quietly skip.
    enum State: String {
        case ok, install, update, unmanaged, invalid
        case pendingApproval = "pending-approval"
    }

    let id: String          // tool name
    let want: String        // designated version, or "" for "any version"
    let state: State
    /// The designation says applying this would interrupt running work, so a
    /// pending update waits for the task rather than killing it.
    let disruptive: Bool
    /// Held back on the last apply because a task was running.
    var deferred = false

    var needsWork: Bool { state == .install || state == .update }

    /// `tools list` rows: `name|version|check|install|flags|approval`, or `invalid|name`
    /// when the manifest line is malformed. The check and install commands are
    /// deliberately not surfaced — the panel shows what is managed, and the
    /// CLI alone decides what runs.
    static func parseList(_ text: String) -> [FleetTool] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let first = f.first, !first.isEmpty else { return nil }
            if first == "invalid" {
                guard f.count >= 2 else { return nil }
                return FleetTool(id: f[1], want: "", state: .invalid, disruptive: false)
            }
            return FleetTool(id: first, want: f.count > 1 ? f[1] : "", state: .unmanaged,
                             disruptive: f.count > 4 && f[4].contains("disruptive"))
        }
    }

    /// `tools status` / `tools deferred` rows: `name \t state`.
    static func parseStates(_ text: String) -> [String: State] {
        var out: [String: State] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, let state = State(rawValue: f[1]) else { continue }
            out[f[0]] = state
        }
        return out
    }

    /// The panel's view of one tool: designation joined to this machine's
    /// reality, with the deferred ones marked so a held update reads as held
    /// rather than as missing.
    static func join(list: String, status: String, deferred: String) -> [FleetTool] {
        let states = parseStates(status)
        let held = Set(parseStates(deferred).keys)
        return parseList(list).map { tool in
            var t = tool
            t = FleetTool(id: tool.id, want: tool.want,
                          state: states[tool.id] ?? tool.state,
                          disruptive: tool.disruptive,
                          deferred: held.contains(tool.id))
            return t
        }
    }
}

/// One row of `agents fleet task list`:
/// `id \t state \t vendor \t rc \t label \t machine`.
struct FleetTask: Identifiable, Equatable {
    enum State: String {
        case queued, preparing, transferring, running, done, failed, disconnected, unknown
    }

    let id: String
    let state: State
    let vendor: String
    let rc: String
    let label: String
    let machine: String

    let role: String
    var canRetry: Bool { role == "dispatcher" }
    var canFetch: Bool { role == "dispatcher" }

    var isFinished: Bool { state == .done || state == .failed }
    /// The worker stopped answering. The fleet waits — it never retries on its
    /// own, because unreachable is not proof the work stopped.
    var isStranded: Bool { state == .disconnected }
    var succeeded: Bool { state == .done && (rc == "0" || rc.isEmpty) }

    static func parse(_ text: String) -> [FleetTask] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, !f[0].isEmpty else { return nil }
            return FleetTask(id: f[0],
                             state: ["completed": State.done, "unreachable": .disconnected, "accepted": .queued,
                                     "dispatching": .transferring, "dispatched": .queued][f[1]] ?? State(rawValue: f[1]) ?? .unknown,
                             vendor: f.count > 2 ? f[2] : "",
                             rc: f.count > 3 ? f[3] : "",
                             label: f.count > 4 ? f[4] : "",
                             machine: f.count > 5 ? f[5] : "",
                             role: f.count > 6 ? f[6] : "")
        }
    }
}

extension FleetTask {
    /// How a task reads everywhere it's shown: a symbol whose shape carries
    /// the state on its own, and one word. An unreachable worker is waiting,
    /// not failed.
    enum Look: Equatable { case waiting, moving, running, done, doneWithExit, failed, notAnswering, unknown }

    var look: Look {
        switch state {
        case .queued: return .waiting
        case .preparing, .transferring: return .moving
        case .running: return .running
        case .done: return succeeded ? .done : .doneWithExit
        case .failed: return .failed
        case .disconnected: return .notAnswering
        case .unknown: return .unknown
        }
    }

    var symbol: String {
        switch look {
        case .waiting: return "circle.dotted"
        case .moving: return "arrow.up.circle"
        case .running: return "play.circle"
        case .done: return "checkmark.circle.fill"
        case .doneWithExit: return "exclamationmark.circle"
        case .failed: return "xmark.circle.fill"
        case .notAnswering: return "wifi.slash"
        case .unknown: return "questionmark.circle"
        }
    }

    var word: String {
        switch look {
        case .waiting: return String(localized: "Queued", comment: "Task state")
        case .moving: return state == .preparing ? String(localized: "Preparing", comment: "Task state")
                                                 : String(localized: "Sending workspace", comment: "Task state")
        case .running: return String(localized: "Running", comment: "Task state")
        case .done: return String(localized: "Finished", comment: "Task state")
        case .doneWithExit: return String(localized: "Exited \(rc)", comment: "Task state: finished with a nonzero exit code")
        case .failed: return String(localized: "Failed", comment: "Task state")
        case .notAnswering: return String(localized: "Not answering", comment: "Task state: the worker stopped answering")
        case .unknown: return String(localized: "Unknown state", comment: "Task state")
        }
    }
}

/// One row of `agents fleet task notices`:
/// `epoch \t kind \t task \t machine \t text`. This feed is the durable half of
/// a fleet event; the desktop banner is fired beside it and may be missed, so
/// the panel reads the feed and never depends on a banner having landed.
struct FleetNotice: Identifiable, Equatable {
    enum Kind: String {
        case done, failed, disconnected, delivered, reconciled, started
    }

    let at: Date
    let kind: Kind
    let task: String
    let machine: String
    let text: String

    /// Stable across refreshes so the notifier can tell a new event from a
    /// redraw of one it already announced.
    var id: String { "\(Int(at.timeIntervalSince1970))\t\(kind.rawValue)\t\(task)\t\(machine)" }

    /// What the desktop banner says. The machine is the subtitle, not the body.
    var title: String {
        switch kind {
        case .done:         return "Task finished on \(machine)"
        case .failed:       return "Task failed on \(machine)"
        case .disconnected: return "\(machine) disconnected"
        case .delivered:    return "Files arrived from \(machine)"
        case .reconciled:   return "Task reconciled on \(machine)"
        case .started:      return "Task started on \(machine)"
        }
    }

    /// One word for the event, for rows that already name the machine.
    var word: String {
        switch kind {
        case .done:         return "finished"
        case .failed:       return "failed"
        case .disconnected: return "not answering"
        case .delivered:    return "files arrived"
        case .reconciled:   return "checked in"
        case .started:      return "started"
        }
    }

    static func parse(_ text: String) -> [FleetNotice] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let epoch = TimeInterval(f[0]), let kind = Kind(rawValue: f[1] == "completed" ? "done" : f[1])
            else { return nil }
            return FleetNotice(at: Date(timeIntervalSince1970: epoch),
                               kind: kind, task: f[2], machine: f[3], text: f[4])
        }
    }
}

/// One row of `agents fleet sync except` — a deliberate, machine-local
/// difference. The panel shows these apart from conflicts on purpose: an
/// exception is a choice, a conflict is an unanswered question.
struct FleetException: Identifiable, Equatable {
    let id: String          // the resource address
    /// `sync except list` numbers its rows (`2:profile|Work|claude|*`) because
    /// `except rm` withdraws by that number. Both halves are kept: the address
    /// is what the panel shows, the number is how it withdraws.
    let index: Int
    var label: String { FleetWords.resource(id) }

    static func parse(_ text: String) -> [FleetException] {
        text.split(separator: "\n").enumerated().compactMap { n, line in
            let row = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init).first ?? ""
            guard !row.isEmpty else { return nil }
            // Take the CLI's own number rather than our position in the list,
            // so a row this parser skipped can never shift a withdrawal onto
            // the neighbouring exception.
            let head = row.prefix(while: { $0 != ":" })
            if let i = Int(head), row.count > head.count + 1 {
                return FleetException(id: String(row.dropFirst(head.count + 1)), index: i)
            }
            return FleetException(id: row, index: n + 1)
        }
    }
}

/// Everything one fleet refresh read, published as a unit for the same reason
/// PanelData is: the panel never shows half of one read beside half of another.
struct FleetData: Equatable {
    var readError: String? = nil
    var observedAt: Date? = nil
    /// `agents fleet status` says this when there is no identity yet. The panel
    /// offers to create one rather than pretending an empty fleet exists.
    var initialized = false
    var machine = ""
    var selfID = ""
    var peers: [FleetPeer] = []
    var pending: [FleetPending] = []
    var sync = FleetSync()
    var conflicts: [FleetConflict] = []
    var exceptions: [FleetException] = []
    var tools: [FleetTool] = []
    var tasks: [FleetTask] = []
    var notices: [FleetNotice] = []

    /// Reads in flight, reads answered at least once, and reads whose latest
    /// attempt failed. A section keeps its last values whatever these say.
    var loading: Set<FleetRead> = []
    var loaded: Set<FleetRead> = []
    var unavailable: Set<FleetRead> = []

    var others: [FleetPeer] { peers.filter { !$0.isSelf } }
    var online: [FleetPeer] { others.filter { $0.isOnline } }
    /// Sending work needs a current machine list; retrying needs a current task list.
    var machinesCurrent: Bool { current(.machines) }
    var tasksCurrent: Bool { current(.tasks) }
    /// Where a task could actually go, self included.
    var destinations: [FleetPeer] { machinesCurrent ? peers.filter { $0.canDispatch } : [] }

    private func current(_ read: FleetRead) -> Bool {
        readError == nil && loaded.contains(read) && !unavailable.contains(read)
    }

    /// What a section says above its values while they are missing or stale.
    func state(_ read: FleetRead) -> String? {
        if unavailable.contains(read) {
            return "Couldn't read \(read.label)." + (loaded.contains(read) ? " Showing the last values." : "")
        }
        return loading.contains(read) && !loaded.contains(read) ? "Loading \(read.label)…" : nil
    }
    var activeTasks: [FleetTask] { tasks.filter { !$0.isFinished } }
    /// When a task last did something, from the activity feed.
    func lastSeen(_ task: FleetTask) -> Date? { notices.filter { $0.task == task.id }.map(\.at).max() }
    /// "1 running · 1 failed": what the Tasks header counts.
    var taskSummary: [(look: FleetTask.Look, count: Int)] {
        // Not answering has its own banner; an exit code is a finished task's detail.
        let order: [FleetTask.Look] = [.running, .moving, .waiting, .failed]
        return order.compactMap { look in
            let n = tasks.filter { $0.look == look }.count
            return n > 0 ? (look, n) : nil
        }
    }
    var needsAttention: Bool {
        !pending.isEmpty || sync.conflicts > 0 || tasks.contains(where: \.isStranded)
    }

    /// `agents fleet status` output: a `self` line, then peer rows, then
    /// `pending` rows. One verb answers "is there a fleet, and who is in it".
    static func parseStatus(_ text: String) -> FleetData {
        var d = FleetData()
        guard !text.hasPrefix("fleet\tuninitialized") else { return d }
        var peerLines: [String] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "self" where f.count >= 3:
                d.initialized = true; d.machine = f[1]; d.selfID = f[2]
            case "pending" where f.count >= 3:
                d.pending.append(FleetPending(id: f[1], machine: f[2], transport: "", requestedAt: nil))
            default:
                peerLines.append(String(line))
            }
        }
        d.peers = FleetPeer.parse(peerLines.joined(separator: "\n"))
        return d
    }
}

/// The panel's fleet reads after `status`. Each is its own CLI call and fills
/// its own part of FleetData the moment it answers, so one slow or failed verb
/// never holds back or blanks the rest.
enum FleetRead: String, CaseIterable {
    case machines, sync, conflicts, exceptions, tools, tasks, activity

    var label: String {
        switch self {
        case .machines: return "machines"
        case .sync: return "sync state"
        case .conflicts: return "conflicts"
        case .exceptions: return "sync exceptions"
        case .tools: return "shared tools"
        case .tasks: return "tasks"
        case .activity: return "task activity"
        }
    }

    /// Runs this read's verbs and returns how it changes FleetData, or nil when
    /// a verb fails, times out or answers something the panel can't understand.
    func read(_ run: ([String]) -> (status: Int32, output: String)) -> ((inout FleetData) -> Void)? {
        func out(_ args: [String]) -> String? {
            let r = run(["fleet"] + args)
            return r.status == 0 ? r.output : nil
        }
        switch self {
        case .machines:
            guard let text = out(["peers"]) else { return nil }
            let peers = FleetPeer.parse(text)
            return { $0.peers = peers }
        case .sync:
            guard let text = out(["sync", "status"]) else { return nil }
            let sync = FleetSync.parse(text)
            return { $0.sync = sync }
        case .conflicts:
            guard let text = out(["sync", "conflicts"]) else { return nil }
            let conflicts = FleetConflict.parse(text)
            return { $0.conflicts = conflicts }
        case .exceptions:
            guard let text = out(["sync", "except", "list"]) else { return nil }
            let exceptions = FleetException.parse(text)
            return { $0.exceptions = exceptions }
        case .tools:
            guard let list = out(["tools", "list"]), let status = out(["tools", "status"]),
                  let deferred = out(["tools", "deferred"]) else { return nil }
            let tools = FleetTool.join(list: list, status: status, deferred: deferred)
            return { $0.tools = tools }
        case .tasks:
            guard let text = out(["task", "list"]) else { return nil }
            let tasks = FleetTask.parse(text), lines = text.split(separator: "\n")
            guard lines.allSatisfy({ $0.split(separator: "\t", omittingEmptySubsequences: false).count >= 7 }),
                  tasks.count == lines.count, !tasks.contains(where: { $0.state == .unknown }) else { return nil }
            return { $0.tasks = tasks }
        case .activity:
            guard let text = out(["task", "notices"]) else { return nil }
            let notices = FleetNotice.parse(text)
            return { $0.notices = notices }
        }
    }
}

/// The dispatch pins, spelled the way `agents fleet task run` takes them.
/// Kept out of the AppKit sheet so all four combinations — neither, machine,
/// agent, both — can be checked without a window server. An empty or absent
/// choice contributes no flag, which is what "let the fleet choose" means:
/// the dispatcher still ranks, rather than being handed a wildcard.
enum FleetPins {
    static func flags(machine: String?, agent: String?) -> [String] {
        var f: [String] = []
        if let m = machine, !m.isEmpty { f += ["--machine", m] }
        if let a = agent, !a.isEmpty { f += ["--agent", a] }
        return f
    }
}

/// Which notices deserve a desktop banner, and which were already announced.
///
/// The feed is durable and re-read on every refresh, so without a seen-set the
/// app would re-announce finished work every few seconds. The first read after
/// launch is adopted silently — otherwise opening the app would fire a burst of
/// banners for work that finished while it was closed.
///
/// `hasRead` is a separate flag on purpose. An empty seen-set does not mean
/// "not read yet": a fresh enrollment, or any launch with no recent activity,
/// reads an empty feed. Conflating the two swallowed the first real completion.
struct FleetAnnouncer {
    private var seen: Set<String> = []
    private var hasRead = false

    /// Records `notices` and returns the ones a banner should be raised for,
    /// oldest first. Always call this, even when nothing will be announced —
    /// it is what marks the feed as read.
    mutating func adopt(_ notices: [FleetNotice]) -> [FleetNotice] {
        let fresh = notices.filter { !seen.contains($0.id) }
        let firstRead = !hasRead
        hasRead = true
        for n in notices { seen.insert(n.id) }
        return firstRead ? [] : fresh
    }
}

/// User input passed as argv to the authoritative fleet CLI.
struct FleetDispatchSpec {
    var task: String
    var prompt: Bool
    var workspace: String
    var contextFile: String
    var requirements: String
    var machine: String?
    var agent: String?

    var arguments: [String] {
        var args = ["fleet", "task", "run", "--label", Self.label(task)]
        if prompt { args.append("--prompt") }
        if !workspace.isEmpty { args += ["--workspace", workspace] }
        if !contextFile.isEmpty { args += ["--context", contextFile] }
        if !requirements.isEmpty { args += ["--requires", requirements] }
        return args + FleetPins.flags(machine: machine, agent: agent)
    }

    /// What the Tasks list calls the work: its first line, not one fixed word
    /// for everything sent from the panel.
    static func label(_ task: String) -> String {
        let line = task.split(whereSeparator: \.isNewline).first.map(String.init) ?? task
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }

    static func hasCandidate(_ plan: String) -> Bool {
        plan.split(separator: "\n").contains { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            return fields.count >= 6 && Int(fields[0]).map { $0 > 0 } == true
        }
    }
}

/// `fleet task run --plan`: the ranked machine and agent pairs the dispatcher
/// would choose between, and what it excluded and why. Shown before Send, so
/// the estimate is the CLI's, not a second one made here.
struct FleetPlan: Equatable {
    struct Candidate: Equatable {
        let rank: Int
        let machine: String
        let agent: String
        let eta: String
    }

    let candidates: [Candidate]
    let excluded: [String]

    static func parse(_ text: String) -> FleetPlan {
        var candidates: [Candidate] = []
        var excluded: [String] = []
        var inExcluded = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == "excluded:" { inExcluded = true; continue }
            if inExcluded {
                if !line.isEmpty { excluded.append(line) }
                continue
            }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, let rank = Int(f[0]), rank > 0 else { continue }
            candidates.append(Candidate(rank: rank, machine: f[2], agent: f[3], eta: f[4]))
        }
        return FleetPlan(candidates: candidates, excluded: excluded)
    }
}

/// The Send Work page's form and where it got to. It lives on the model, so
/// closing the panel mid-draft loses nothing.
struct WorkDraft: Equatable {
    enum State: Equatable { case editing, planning, planned(FleetPlan), sending, sent(String), failed(String) }

    var shell = false
    var task = ""
    var workspace = ""
    var contextFile = ""
    var requirements = ""
    var machine: String?
    var agent: String?
    var state: State = .editing

    /// What the CLI would be asked; nil until there is work to describe.
    var spec: FleetDispatchSpec? {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        func path(_ p: String) -> String {
            let t = p.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? "" : (t as NSString).expandingTildeInPath
        }
        return FleetDispatchSpec(task: text, prompt: !shell, workspace: path(workspace), contextFile: path(contextFile),
                                 requirements: requirements.trimmingCharacters(in: .whitespaces), machine: machine, agent: agent)
    }
}

/// The fleet CLI speaks ids, enums and tab-separated rows; this turns them into
/// what the panel says. Lab names come from the porcelain snapshot when one
/// has loaded (`labs` is refreshed with it) and fall back to the id.
enum FleetWords {
    static var labs: [String: String] = [:]

    static func lab(_ id: String) -> String { labs[id] ?? id }

    /// `category|profile|lab|path`, `-` for a part that doesn't apply and `*`
    /// for everything: "Claude Code settings.json in Work", "All Claude Code
    /// settings in Acme".
    static func resource(_ address: String) -> String {
        let f = address.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 4 else {
            return f.filter { $0 != "-" && !$0.isEmpty }.joined(separator: " · ")
        }
        let category = ["settings": "settings", "skills": "skills and instructions", "mcp": "MCP configuration",
                        "auth": "credentials", "profile": "profile", "tools": "tools"][f[0]] ?? f[0]
        let lab = f[2] == "-" || f[2].isEmpty ? nil : self.lab(f[2])
        let path = f[3...].joined(separator: "|")
        let what: String
        if path == "*" || path.isEmpty {
            what = "All " + [lab, category].compactMap { $0 }.joined(separator: " ")
        } else if let lab {
            what = "\(lab) \(path)"
        } else {
            what = category.prefix(1).uppercased() + category.dropFirst() + ": " + path
        }
        return f[1] == "-" || f[1].isEmpty ? what : "\(what) in \(f[1])"
    }

    /// "just now" under a minute (a stamp a moment ahead of this clock too,
    /// never "in 0 seconds"), then "4 minutes ago".
    static func ago(_ at: Date, now: Date) -> String {
        guard now.timeIntervalSince(at) >= 60 else { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .numeric
        return f.localizedString(for: at, relativeTo: now)
    }

    /// "Claude Code credentials · partly shareable": the support word is the CLI's.
    static func credentials(_ vendor: String, _ support: String) -> String {
        let word = ["full": nil, "partial": "partly shareable", "unverified": "unverified",
                    "unsupported": "not shareable"][support] ?? support
        return [lab(vendor) + " credentials", word].compactMap { $0 }.joined(separator: " · ")
    }

    /// `fleet sync service status` rows (`plist`, `loaded`, `log`, `last-event`)
    /// as one sentence: "Background sync is on · last ran 2 minutes ago."
    static func service(_ text: String, now: Date) -> String {
        var f: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if p.count == 2 { f[p[0]] = p[1] }
        }
        guard let loaded = f["loaded"] else { return text }
        var sentence = loaded == "yes" ? "Background sync is on" : "Background sync is off"
        if let last = f["last-event"], last != "never" {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let at = TimeInterval(last).map { Date(timeIntervalSince1970: $0) } ?? iso.date(from: last) ?? ISO8601DateFormatter().date(from: last)
            if let at { sentence += " · last ran \(ago(at, now: now))" }
        } else if loaded == "yes" {
            sentence += " · hasn’t run yet"
        }
        return sentence + "."
    }

    static func transport(_ id: String) -> String {
        ["tailscale": "Tailscale", "ssh": "SSH", "exec": "Local", "self": "This Mac"][id] ?? id
    }

    /// A plan's `excluded:` row, `x \t peer \t machine \t agent \t reason`:
    /// "studio: not approved yet".
    static func exclusion(_ line: String) -> String {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 5, f[0] == "x" else {
            return f.filter { !$0.isEmpty && $0 != "-" }.joined(separator: " · ")
        }
        let lab = f[3] == "-" ? "" : self.lab(f[3])
        let reason = f[4]
        func inside(_ word: String) -> String? {
            guard reason.hasPrefix(word + "("), reason.hasSuffix(")") else { return nil }
            return String(reason.dropFirst(word.count + 1).dropLast())
        }
        let why: String
        if let state = inside("not-approved") { why = state == "pending" ? "not approved yet" : "not approved (\(state))" }
        else if let missing = inside("missing-requirement") { why = "missing \(missing.replacingOccurrences(of: " ", with: ", "))" }
        else {
            why = ["unreachable": "not reachable",
                   "unsupported-prompt-adapter": "\(lab) can’t take agent tasks",
                   "agent-excluded-by-preference": "\(lab) is excluded by your preferences",
                   "agent-not-installed": "\(lab) isn’t installed",
                   "agent-auth-unknown": "\(lab) sign-in is unknown"][reason] ?? reason.replacingOccurrences(of: "-", with: " ")
        }
        return "\(f[2]): \(why)"
    }

    /// `fleet task run` answers `id \t machine \t agent \t eta \t assumed=…`:
    /// "Sent to mac-mini · Claude Code, about 90s. Follow it in Tasks."
    static func receipt(_ output: String) -> String {
        let f = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 4, !f[1].isEmpty else { return output }
        return "Sent to \(f[1]) · \(lab(f[2])), about \(f[3]). Follow it in Tasks."
    }

    /// `fleet task show`: `key \t value` lines, a blank line, then events
    /// `epoch \t kind \t detail`. The alert gets a title and plain sentences.
    static func taskSummary(_ output: String, id: String) -> (title: String, body: String) {
        var meta: [String: String] = [:]
        var events: [String] = []
        var inEvents = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty { inEvents = true; continue }
            let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if inEvents {
                let e = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard e.count >= 2 else { continue }
                let when = TimeInterval(e[0]).map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) } ?? e[0]
                let detail = e.count > 2 && !e[2].isEmpty ? " — \(e[2])" : ""
                events.append("\(when)  \(e[1].replacingOccurrences(of: "-", with: " "))\(detail)")
            } else if f.count == 2 {
                meta[f[0]] = f[1]
            }
        }
        guard !meta.isEmpty else { return ("Task \(id)", output) }
        let task = FleetTask.parse([id, meta["state"] ?? "", meta["vendor"] ?? "", meta["rc"] ?? "",
                                    meta["label"] ?? "", meta["machine"] ?? "", meta["role"] ?? ""].joined(separator: "\t")).first
        var lines: [String] = []
        let state = task.map { $0.word } ?? (meta["state"] ?? "")
        let place = [meta["machine"].map { "on \($0)" }, meta["vendor"].map { lab($0) }].compactMap { $0 }.joined(separator: " · ")
        lines.append([state, place].filter { !$0.isEmpty }.joined(separator: " "))
        if let rc = meta["rc"], rc != "0", !rc.isEmpty, task?.state != .running { lines.append("Exit code \(rc)") }
        if !events.isEmpty { lines.append(""); lines += events.suffix(8) }
        let title = meta["label"].flatMap { $0.isEmpty ? nil : $0 } ?? "Task \(id)"
        return (title, lines.joined(separator: "\n"))
    }
}
