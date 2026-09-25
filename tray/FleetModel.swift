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

    /// `profile|Work|claude|settings` reads as "Work · claude · settings".
    var label: String {
        address.split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init).filter { $0 != "-" && !$0.isEmpty }
            .joined(separator: " · ")
    }

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
                             state: State(rawValue: f[1]) ?? .unknown,
                             vendor: f.count > 2 ? f[2] : "",
                             rc: f.count > 3 ? f[3] : "",
                             label: f.count > 4 ? f[4] : "",
                             machine: f.count > 5 ? f[5] : "")
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

    static func parse(_ text: String) -> [FleetNotice] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let epoch = TimeInterval(f[0]), let kind = Kind(rawValue: f[1])
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
    var label: String {
        id.split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init).filter { $0 != "-" && !$0.isEmpty }
            .joined(separator: " · ")
    }

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

    var others: [FleetPeer] { peers.filter { !$0.isSelf } }
    var online: [FleetPeer] { others.filter { $0.isOnline } }
    /// Where a task could actually go, self included.
    var destinations: [FleetPeer] { peers.filter { $0.canDispatch } }
    var activeTasks: [FleetTask] { tasks.filter { !$0.isFinished } }
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
