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
    var fetchedAt = Date()

    /// Quota left in whichever window is tighter — the one that stops you first.
    var remaining: Int? {
        guard note == .ok, let f = fiveHour else { return nil }
        return 100 - max(f, sevenDay ?? 0)
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
                               note: note)
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

    /// Lowest 5h wins, ties to 7d — the CLI's pick_best, run over rows already
    /// fetched so the button names its pick before anything is launched. Nil
    /// while any profile is unreadable: a guess would look like an answer.
    var best: (name: String, fiveHour: Int)? {
        guard let data, let v = data.quotaVendor else { return nil }
        let slotted = data.profiles.filter { $0.slots[v.id] != nil }
        guard slotted.count >= 2 else { return nil }
        var rows: [(String, Int, Int)] = []
        for p in slotted {
            guard let u = usage[p.name], u.note == .ok, let f = u.fiveHour else { return nil }
            rows.append((p.name, f, u.sevenDay ?? 101))
        }
        let pick = rows.min { ($0.1, $0.2) < ($1.1, $1.2) }!
        return (pick.0, pick.1)
    }

    /// True when some slotted profile's quota can't be read, which is why
    /// `best` is hidden.
    var rankingBlocked: Bool {
        guard let data, let v = data.quotaVendor else { return false }
        let slotted = data.profiles.filter { $0.slots[v.id] != nil }
        return slotted.count >= 2 && slotted.contains { usage[$0.name].map { $0.note != .ok } ?? false }
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
