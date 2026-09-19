import Foundation

// State behind the menu bar panel. The app delegate is the only writer — it
// runs the CLI off the main thread and publishes results here — and the views
// only read it and call back through PanelActions.

/// One row of `agents best --porcelain`.
struct Usage {
    enum Note: String {
        case ok
        case noToken = "no-token"
        case staleToken = "stale-token"
        case rateLimited = "rate-limited"
        case fetchError = "fetch-error"
        case noUsageAPI = "no-usage-api"
    }

    let fiveHour: Int?
    let sevenDay: Int?
    let resets: Date?       // when the 5h window resets
    let note: Note
    let sevenResets: Date?  // when the 7d window resets
    var fetchedAt = Date()

    /// Used in whichever window is tighter — the one that stops you first.
    var used: Int? {
        guard note == .ok, let f = fiveHour else { return nil }
        return max(f, sevenDay ?? 0)
    }

    /// 95%+ in either window. The endpoint reports utilisation and the last
    /// few points are unusable in practice, so this is out, not "nearly".
    static let maxedAt = 95
    var maxed: Bool { (used ?? 0) >= Self.maxedAt }

    /// When a maxed lab comes back: the latest reset among the maxed windows.
    var maxedUntil: Date? {
        guard maxed else { return nil }
        let windows = [((fiveHour ?? 0) >= Self.maxedAt, resets), ((sevenDay ?? 0) >= Self.maxedAt, sevenResets)]
        return windows.filter { $0.0 }.compactMap { $0.1 }.max()
    }

    private static let resetFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    /// profile -> usage. Unknown notes are dropped: a newer CLI may add some.
    static func parse(_ text: String) -> [String: Usage] {
        var rows: [String: Usage] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let note = Note(rawValue: f[4]) else { continue }
            rows[f[0]] = Usage(fiveHour: Double(f[1]).map { Int($0.rounded()) },
                               sevenDay: Double(f[2]).map { Int($0.rounded()) },
                               resets: resetFormat.date(from: f[3]),
                               note: note,
                               sevenResets: f.count > 5 ? resetFormat.date(from: f[5]) : nil)
        }
        return rows
    }

    /// A failed read doesn't erase a good one: the last numbers stay, dated by
    /// their own fetchedAt so the panel can say how old they are.
    static func merge(_ old: [String: Usage], _ new: [String: Usage]) -> [String: Usage] {
        new.mapValues { $0 }.merging(old) { fresh, previous in
            (fresh.note == .rateLimited || fresh.note == .fetchError) && previous.note == .ok ? previous : fresh
        }.filter { new[$0.key] != nil }
    }
}

/// Everything one refresh reads from disk and the CLI, published as a unit so
/// the panel never renders half of one refresh and half of another.
struct PanelData {
    let snapshot: Snapshot
    let profiles: [Profile]
    let desktopVersion: String?          // nil = Claude Desktop not found
    let staleClones: [String: String]    // profile -> clone version, where it differs from desktopVersion
    let sessions: [SessionInfo]
    let terminals: [String]              // installed terminal names, preferred first

    var desktopInstalled: Bool { desktopVersion != nil }
    /// The lab whose quota the panel can show (Claude alone, today).
    var quotaVendor: Vendor? { snapshot.installedVendors.first { $0.hasUsageAPI } }
}

struct Selection: Equatable {
    let profile: String
    let vendor: String
}

enum BestPick {
    case profile(String, used: Int)
    /// Every readable profile is maxed; the soonest one back, if known.
    case allMaxed(firstBack: Date?)
}

enum UpdateStatus: Equatable {
    case upToDate
    case available
    case failed(String)
}

final class PanelModel: ObservableObject {
    @Published var data: PanelData?
    /// Quota for data.quotaVendor, profile -> row. Empty until the first fetch lands.
    @Published var usage: [String: Usage] = [:]
    @Published var usageLoading = false
    /// A fetch has run 3 s with nothing to show: sweeps give way to a label,
    /// because motion that outlives its welcome reads as a hang.
    @Published var usageSlow = false
    /// Flips false → true on every open; the content rises into place off it.
    @Published var presented = true
    @Published var repatching: Set<String> = []
    @Published var selection: Selection?
    @Published var updateStatus: UpdateStatus?
    /// Profiles whose setup was left unfinished: profile -> the labs it set up.
    @Published var pendingSetups: [String: [String]] = [:]

    /// Lowest 5h wins, ties to 7d — the CLI's pick_best, run over rows already
    /// fetched so the button names its pick before anything is launched.
    /// Unreadable and maxed profiles are out of the running, not blockers.
    /// Nil until at least one reading is in.
    var best: BestPick? {
        guard let data, let v = data.quotaVendor else { return nil }
        let readable = data.profiles.filter { $0.slots[v.id] != nil }
            .compactMap { p in usage[p.name].flatMap { $0.note == .ok ? (p.name, $0) : nil } }
        guard !readable.isEmpty else { return nil }
        let open = readable.filter { !$0.1.maxed }
        guard let pick = open.min(by: { ($0.1.fiveHour ?? 0, $0.1.sevenDay ?? 0) < ($1.1.fiveHour ?? 0, $1.1.sevenDay ?? 0) }) else {
            return .allMaxed(firstBack: readable.compactMap { $0.1.maxedUntil }.min())
        }
        return .profile(pick.0, used: pick.1.fiveHour ?? 0)
    }
}

/// What the panel can ask the app to do. Everything with a side effect goes
/// through the delegate, which goes through the `agents` CLI.
protocol PanelActions: AnyObject {
    func openSession(profile: String, vendor: String, terminal: String?)
    func setActive(profile: String, vendor: String?)
    func copyCommand(profile: String, vendor: String)
    func openDesktop(profile: String)
    func transferSession(profile: String, vendor: String)
    func signIn(profile: String, vendor: String, confirm: Bool)
    func finishSetup(profile: String)
    func resumeSession(_ session: SessionInfo)
    func addVendor(profile: String)
    func revealData(profile: String)
    func deleteProfile(_ name: String)
    func newProfile()
    func rebuildClone(_ name: String)
    func showCloneDetails()
    func retryUsage()
    func locateClaude()
    func downloadClaude()
    func repatchAll()
    func setAutoRepatch(_ on: Bool)
    var autoRepatch: Bool { get }
    func setPreferredTerminal(_ name: String)
    func setUpdateChannel(_ channel: UpdateChannel)
    func checkForUpdates()
    func reportBug()
    func quit()
}
