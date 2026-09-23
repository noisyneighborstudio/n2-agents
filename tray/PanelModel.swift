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
    /// A plan may have only one of the two.
    var used: Int? {
        guard note == .ok, fiveHour != nil || sevenDay != nil else { return nil }
        return max(fiveHour ?? 0, sevenDay ?? 0)
    }

    /// 95%+ in either window. The endpoint reports utilisation and the last
    /// few points are unusable in practice, so this is out, not "nearly".
    static let maxedAt = 95
    var maxed: Bool { (used ?? 0) >= Self.maxedAt }

    /// The window that binds — the one that stops you first — with its reset.
    /// Depth 2 shows this one; depth 3 shows both.
    var binding: (tag: String, percent: Int, resets: Date?)? {
        guard note == .ok else { return nil }
        let f = fiveHour ?? -1, d = sevenDay ?? -1
        guard f >= 0 || d >= 0 else { return nil }
        return f >= d ? ("5h", max(f, 0), resets) : ("7d", max(d, 0), sevenResets)
    }

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
    /// Labs whose single, shared desktop app (desktop = launch) is installed.
    let launchDesktops: Set<String>

    var desktopInstalled: Bool { desktopVersion != nil }
    /// The labs this profile holds, in table order.
    func slotted(_ profile: Profile) -> [Vendor] {
        snapshot.installedVendors.filter { profile.slots[$0.id] != nil }
    }
    /// The labs whose quota the panel can show.
    var quotaVendors: [Vendor] { snapshot.installedVendors.filter(\.hasUsageAPI) }
    /// The lab whose desktop app is cloned per profile (Claude alone, today) —
    /// every desktop clone feature keys off this, never a lab's name.
    var cloneVendor: Vendor? { snapshot.installedVendors.first { $0.clonesDesktopApp } }

    /// Whether this profile has a desktop app to open for this lab: its own
    /// clone for a `clone` lab, the lab's one shared app for a `launch` lab.
    func hasDesktop(_ vendor: Vendor, for profile: Profile) -> Bool {
        vendor.clonesDesktopApp ? desktopInstalled && profile.hasApp : launchDesktops.contains(vendor.id)
    }
}

struct Selection: Equatable {
    let profile: String
    let vendor: String
}

enum NextBest {
    case slot(profile: String, vendor: String, used: Int?)
    /// Every signed-in slot is out of quota; the soonest one back, if known.
    case allMaxed(firstBack: Date?)
    case nothingSignedIn
}

/// Where a profile stands, as one closed vocabulary. The card's status slot
/// answers exactly one question — can I work here right now — so everything
/// that isn't capacity (a desktop app's process, a pending rebuild) lives
/// deeper or in the banner, never here.
enum ProfileState: Equatable {
    case ready
    case checking
    /// Some labs are out; `until` is the soonest one back.
    case labsOut(out: Int, of: Int, until: Date?)
    /// Nothing left to run at all.
    case allOut(until: Date?)
    case needsSignIn(Int)
    case notSignedIn
}

enum UpdateStatus: Equatable {
    case upToDate
    case available
    case failed(String)
}

final class PanelModel: ObservableObject {
    @Published var data: PanelData?
    /// Quota for data.quotaVendors, vendor -> profile -> row. A lab is
    /// missing until its first fetch lands.
    @Published var usage: [String: [String: Usage]] = [:]
    @Published var usageLoading = false
    /// A fetch has run 3 s with nothing to show: sweeps give way to a label,
    /// because motion that outlives its welcome reads as a hang.
    @Published var usageSlow = false
    /// Flips false → true on every open; the content rises into place off it.
    @Published var presented = true
    @Published var repatching: Set<String> = []
    /// The one profile showing its labs. One at a time keeps the panel's
    /// height bounded, which is what lets depth 3 open in place.
    @Published var expanded: String?
    /// The one slot showing its actions, inside the expanded profile.
    @Published var selection: Selection?
    @Published var updateStatus: UpdateStatus?
    /// Profiles whose setup was left unfinished: profile -> the labs it set up.
    @Published var pendingSetups: [String: [String]] = [:]
    /// Every session, for the standalone window; the panel itself keeps the
    /// two newest. Kept between opens, so the window never starts empty.
    @Published var allSessions: [SessionInfo] = []
    @Published var sessionsLoading = false

    /// A profile's status and its capacity, read together because they answer
    /// halves of the same question.
    ///
    /// The number is the mean of `used` across the slots that reported one:
    /// equal weighting is a rule that can be stated, and a profile with one lab
    /// maxed and six with room is genuinely usable — the mean says so while the
    /// strip below it shows where the hole is. Labs with no quota API and labs
    /// that aren't signed in contribute no number rather than a guessed one.
    func reading(_ profile: Profile, _ data: PanelData) -> (state: ProfileState, used: Int?) {
        let slotted = data.snapshot.installedVendors.filter { profile.slots[$0.id] != nil }
        let metered = slotted.filter(\.hasUsageAPI)
        func signedIn(_ v: Vendor) -> Bool { data.snapshot.signedIn[profile.name]?[v.id] != false }
        func row(_ v: Vendor) -> Usage? { usage[v.id]?[profile.name] }

        let live = metered.filter(signedIn)
        let readable = live.compactMap { row($0) }.filter { $0.note == .ok }
        let values = readable.compactMap(\.used)
        let used = values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())

        let out = readable.filter(\.maxed)
        let back = out.compactMap(\.maxedUntil).min()
        let signedOut = slotted.filter { !signedIn($0) }

        // No labs at all is nothing to run, not "Ready".
        if signedOut.count == slotted.count { return (.notSignedIn, nil) }
        if !live.isEmpty, live.allSatisfy({ row($0) == nil }) { return (.checking, nil) }
        if !live.isEmpty, out.count == live.count {
            // A lab with no quota API can still be opened, so it keeps the
            // profile out of the red even when every metered one is spent.
            let openable = slotted.contains { !$0.hasUsageAPI && signedIn($0) }
            return openable ? (.labsOut(out: out.count, of: slotted.count, until: back), used)
                            : (.allOut(until: back), used)
        }
        if !out.isEmpty { return (.labsOut(out: out.count, of: slotted.count, until: back), used) }
        if !signedOut.isEmpty { return (.needsSignIn(signedOut.count), used) }
        return (.ready, used)
    }

    /// The CLI's next_best, run over what's already read, so the button names
    /// its pick before anything starts: every slot in one rotation (profiles
    /// in order, labs in table order), starting after the last slot run, and
    /// the first that is signed in (or can't be checked) and — for a lab that
    /// reports quota — read cleanly and not maxed. No lab is favoured. Nil
    /// while the pick hangs on a quota reading that hasn't landed yet.
    var nextBest: NextBest? {
        guard let data else { return nil }
        let snap = data.snapshot
        let slots = data.profiles.flatMap { p in
            snap.installedVendors.filter { p.slots[$0.id] != nil }.map { (profile: p.name, vendor: $0) }
        }
        let after = snap.lastSlot.flatMap { last in
            slots.firstIndex { $0.profile == last.profile && $0.vendor.id == last.vendor }
        } ?? -1
        var firstBack: [Date] = []
        var sawMaxed = false
        for i in slots.indices {
            let (profile, vendor) = slots[(after + 1 + i) % slots.count]
            guard snap.signedIn[profile]?[vendor.id] != false else { continue }
            guard vendor.hasUsageAPI else { return .slot(profile: profile, vendor: vendor.id, used: nil) }
            guard let rows = usage[vendor.id] else {
                if usageLoading { return nil }
                continue
            }
            guard let u = rows[profile] else { continue }
            guard u.note == .ok else { continue }
            if u.maxed {
                sawMaxed = true
                if let back = u.maxedUntil { firstBack.append(back) }
                continue
            }
            return .slot(profile: profile, vendor: vendor.id, used: u.used)
        }
        return sawMaxed ? .allMaxed(firstBack: firstBack.min()) : .nothingSignedIn
    }
}

/// What the panel can ask the app to do. Everything with a side effect goes
/// through the delegate, which goes through the `agents` CLI.
protocol PanelActions: AnyObject {
    func openSession(profile: String, vendor: String, terminal: String?)
    func setActive(profile: String, vendor: String?)
    func copyCommand(profile: String, vendor: String)
    func openDesktop(profile: String, vendor: String)
    func signIn(profile: String, vendor: String, confirm: Bool)
    func finishSetup(profile: String)
    func resumeSession(_ session: SessionInfo)
    func moveSession(_ session: SessionInfo, to profile: String)
    func copyResumeCommand(_ session: SessionInfo)
    func showAllSessions()
    func closeSessions()
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
