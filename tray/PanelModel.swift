import Foundation
import CoreFoundation
import Combine

// State behind the menu bar panel. The app delegate is the only writer — it
// runs the CLI off the main thread and publishes results here — and the views
// only read it and call back through PanelActions.

/// One structured allowance observation from `agents best --json`.
struct Usage {
    enum Note: String {
        case ok
        case noToken = "no-token"
        case staleToken = "stale-token"
        case rateLimited = "rate-limited"
        case fetchError = "fetch-error"
        case restricted
        case credentialOverride = "credential-override"
        case credentialStoreUnavailable = "credential-store-unavailable"
        case ownerUnavailable = "owner-unavailable"
        case noUsageAPI = "no-usage-api"
        /// The lab has one login for the machine; Default's row carries it.
        case sharedLogin = "shared-login"
    }

    let fiveHour: Int?
    let sevenDay: Int?
    let resets: Date?       // when the 5h window resets
    var note: Note
    let sevenResets: Date?  // when the 7d window resets
    /// What the long window is for this lab ("7d", or Cursor's "mo").
    var longWindow = "7d"
    var fetchedAt = Date()
    struct Window {
        let scope: String
        let percent: Double
        let resets: Date?
        var durationSeconds: Double? = nil
        var label: String {
            switch scope {
            case "five_hour": return "5h"
            case "seven_day": return "7d"
            case "seven_day_opus": return "Opus · 7d"
            case "seven_day_sonnet": return "Sonnet · 7d"
            default:
                let name = scope.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ":", with: " · ")
                guard let durationSeconds, durationSeconds > 0 else { return name }
                let scale: (Double, String) = durationSeconds.truncatingRemainder(dividingBy: 86400) == 0 ? (86400, "d")
                    : durationSeconds.truncatingRemainder(dividingBy: 3600) == 0 ? (3600, "h")
                    : durationSeconds.truncatingRemainder(dividingBy: 60) == 0 ? (60, "m") : (1, "s")
                return name + " · " + String(format: "%.0f", durationSeconds / scale.0) + scale.1
            }
        }
    }
    /// nil denotes a legacy TSV row. An empty array is a structured missing reading.
    var windows: [Window]? = nil
    var restrictionResets: [Date?] = []
    var restrictionReasons: [String] = []
    var creditNotes: [String] = []
    var identityStatus = "unknown"
    var accountHash: String? = nil

    var accountSummary: String {
        if identityStatus == "verified", let accountHash {
            return "Usage account · \(accountHash.prefix(12))"
        }
        return "Usage account not verified"
    }
    var accountHelp: String {
        if identityStatus == "verified", let accountHash {
            return "Account confirmed for this usage observation: \(accountHash). Match this identifier across machines."
        }
        return "Account identity: \(identityStatus). Matching profile names do not establish the same account."
    }

    /// Expired observations cannot advertise capacity or select an account.
    static let maximumAge: TimeInterval = 15 * 60
    var hasObservationTime: Bool { fetchedAt != .distantPast }
    var isFresh: Bool {
        let age = Date().timeIntervalSince(fetchedAt)
        return age >= -300 && age <= Self.maximumAge
    }

    /// Used in whichever window is tighter — the one that stops you first.
    /// A plan may have only one of the two.
    var used: Int? {
        guard note == .ok, isFresh else { return nil }
        if let windows { return windows.map(\.percent).max().map { Int($0.rounded()) } }
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return max(fiveHour ?? 0, sevenDay ?? 0)
    }

    /// Local scheduling reserve, not the provider's exhaustion threshold.
    static let maxedAt = 95
    var maxed: Bool {
        guard isFresh else { return false }
        if note == .restricted { return true }
        guard note == .ok else { return false }
        if let windows { return windows.contains { $0.percent >= Double(Self.maxedAt) } }
        return (used ?? 0) >= Self.maxedAt
    }
    /// A provider rejection establishes no runnable capacity, without inventing
    /// a utilization percentage. Unknown or failed observations stay unknown.
    var availableRemaining: Int? {
        if maxed { return 0 }
        return used.map { 100 - $0 }
    }

    /// The window that binds — the one that stops you first — with its reset.
    /// Depth 2 shows this one; depth 3 shows both.
    var binding: (tag: String, percent: Int, resets: Date?)? {
        guard note == .ok, isFresh else { return nil }
        if let windows {
            return windows.max { $0.percent < $1.percent }.map { ($0.label, Int($0.percent.rounded()), $0.resets) }
        }
        let f = fiveHour ?? -1, d = sevenDay ?? -1
        guard f >= 0 || d >= 0 else { return nil }
        return f >= d ? ("5h", max(f, 0), resets) : (longWindow, max(d, 0), sevenResets)
    }

    /// When a maxed lab comes back: the latest reset among the maxed windows.
    var maxedUntil: Date? {
        guard maxed else { return nil }
        let evidence: [Date?]
        if let windows {
            evidence = windows.filter { $0.percent >= Double(Self.maxedAt) }.map(\.resets) + restrictionResets
        } else {
            evidence = [((fiveHour ?? 0) >= Self.maxedAt, resets), ((sevenDay ?? 0) >= Self.maxedAt, sevenResets)]
                .filter { $0.0 }.map { $0.1 }
        }
        guard !evidence.isEmpty, evidence.allSatisfy({ $0 != nil }) else { return nil }
        return evidence.compactMap { $0 }.max()
    }

    private static let resetFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    private static func percent(_ text: String) -> Int? {
        guard let value = Double(text), value.isFinite, value >= 0, value <= 100 else { return nil }
        return Int(value.rounded())
    }

    /// profile -> usage. Unknown notes are dropped: a newer CLI may add some.
    static func parse(_ text: String, longWindow: String = "7d") -> [String: Usage] {
        var rows: [String: Usage] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let note = Note(rawValue: f[4]) else { continue }
            rows[f[0]] = Usage(fiveHour: percent(f[1]),
                               sevenDay: percent(f[2]),
                               resets: resetFormat.date(from: f[3]),
                               note: note,
                               sevenResets: f.count > 5 ? resetFormat.date(from: f[5]) : nil,
                               longWindow: longWindow)
        }
        return rows
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func observationDate(_ value: Any?) -> Date? {
        if let value = number(value) { return Date(timeIntervalSince1970: value) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text) ?? resetFormat.date(from: text)
    }

    static func parseJSON(_ text: String, provider: String, longWindow: String = "7d") -> [String: Usage] {
        var rows: [String: Usage] = [:]
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  number(value["schemaVersion"]) == 1, value["provider"] as? String == provider,
                  let profile = value["profile"] as? String, !profile.isEmpty else { continue }
            var row = Usage(fiveHour: nil, sevenDay: nil, resets: nil, note: .fetchError,
                            sevenResets: nil, longWindow: longWindow,
                            fetchedAt: observationDate(value["observedAt"]) ?? .distantPast, windows: [])
            // Duplicate bindings cannot be resolved by accepting whichever row
            // happened to arrive last. Keep the whole binding unavailable.
            if rows[profile] != nil { rows[profile] = row; continue }
            guard let rawStatus = value["status"] as? String, let status = Note(rawValue: rawStatus) else {
                rows[profile] = row; continue
            }
            row.note = status
            if let identity = value["identity"] as? [String: Any],
               let state = identity["status"] as? String,
               ["verified", "login-only", "unknown", "conflicting", "unavailable"].contains(state) {
                row.identityStatus = state
                if state == "verified", let hash = identity["accountHash"] as? String,
                   hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) {
                    row.accountHash = hash
                } else if state == "verified" { row.identityStatus = "unavailable" }
            }
            if let credits = value["credits"] as? [String: [String: Any]] {
                for key in credits.keys.sorted() {
                    let credit = credits[key] ?? [:]
                    if key == "overage", let enabled = boolean(credit["is_enabled"]) {
                        row.creditNotes.append(enabled ? "Extra usage enabled" : "Extra usage disabled")
                        if enabled, boolean(credit["spend_limit_reached"]) == true {
                            row.creditNotes.append("Extra usage spending limit reached")
                        }
                    } else if boolean(credit["unlimited"]) == true {
                        row.creditNotes.append("\(key): unlimited credits")
                    } else if let balance = credit["balance"] as? String, balance.count <= 64 {
                        row.creditNotes.append("\(key): credit balance \(balance)")
                    }
                }
            }
            guard status == .ok || status == .restricted else { rows[profile] = row; continue }
            guard let windows = value["windows"] as? [[String: Any]],
                  let restrictions = value["restrictions"] as? [[String: Any]] else {
                row.note = .fetchError; rows[profile] = row; continue
            }
            var incomplete = false
            for window in windows {
                guard let scope = window["scope"] as? String, !scope.isEmpty,
                      let percent = number(window["usedPercent"]), (0...100).contains(percent) else {
                    incomplete = true; continue
                }
                row.windows?.append(Window(scope: scope, percent: percent, resets: observationDate(window["resetsAt"]), durationSeconds: number(window["durationSeconds"])))
            }
            // Other collectors expose their single/two measured windows in
            // display columns. Claude and Codex must supply full buckets.
            if windows.isEmpty, !["claude", "codex"].contains(provider), let display = value["display"] as? [String: Any] {
                for (key, reset, label) in [("shortUsed", "shortResets", "5h"), ("longUsed", "longResets", longWindow)] {
                    let raw = display[key]
                    if raw == nil || raw is NSNull || raw as? String == "-" { continue }
                    let percent = number(raw) ?? (raw as? String).flatMap(Double.init)
                    guard let percent, percent.isFinite, (0...100).contains(percent) else { incomplete = true; continue }
                    row.windows?.append(Window(scope: label, percent: percent, resets: observationDate(display[reset])))
                }
            }
            row.restrictionResets = restrictions.map { observationDate($0["resetsAt"]) }
            row.restrictionReasons = restrictions.map { restriction in
                let scope = restriction["scope"] as? String ?? "unknown"
                let reason = restriction["reason"] as? String ?? "provider restriction"
                return "\(scope): \(reason)"
            }
            if status == .restricted || !restrictions.isEmpty {
                row.note = .restricted
                if incomplete || restrictions.isEmpty { row.restrictionResets.append(nil) }
            } else if incomplete || row.windows?.isEmpty != false { row.note = .fetchError }
            rows[profile] = row
        }
        return rows
    }

    /// Keep the last observation for diagnosis, but retain the failed read's
    /// status. A failed refresh must never leave a healthy capacity gauge.
    static func merge(_ old: [String: Usage], _ new: [String: Usage]) -> [String: Usage] {
        new.mapValues { $0 }.merging(old) { fresh, previous in
            guard fresh.note == .rateLimited || fresh.note == .fetchError else { return fresh }
            var stale = previous
            stale.note = fresh.note
            return stale
        }.filter { new[$0.key] != nil }
    }

}

/// Everything one refresh reads from disk and the CLI, published as a unit so
/// the panel never renders half of one refresh and half of another.
struct PanelData {
    let snapshot: Snapshot
    let profiles: [Profile]
    let sessions: [SessionInfo]
    let terminals: [String]              // installed terminal names, preferred first
    /// Labs whose desktop app is installed.
    let desktops: Set<String>

    /// The labs this profile holds, in table order.
    func slotted(_ profile: Profile) -> [Vendor] {
        snapshot.installedVendors.filter { profile.slots[$0.id] != nil }
    }
    /// The labs whose quota the panel can show.
    var quotaVendors: [Vendor] { snapshot.installedVendors.filter(\.hasUsageAPI) }
    /// Whether this profile can open this lab's desktop app: any profile with
    /// a slot can, as its own instance of the installed app.
    func hasDesktop(_ vendor: Vendor, for profile: Profile) -> Bool {
        desktops.contains(vendor.id) && profile.slots[vendor.id] != nil
    }
}

/// Something whose quota has run low: overall, a profile, or one lab in one.
/// The id holds across refreshes, so each tier is announced once per dip.
struct LowQuota: Equatable {
    let id: String
    let title: String
    let left: Int

    var tier: StatusIcon.Tier { StatusIcon.Tier(remaining: left) }
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
    case usageUnavailable
}

/// Where a profile stands, as one closed vocabulary. The card's status slot
/// answers exactly one question — can I work here right now — so everything
/// that isn't capacity (a desktop app's process, a pending rebuild) lives
/// deeper or in the banner, never here.
enum ProfileState: Equatable {
    case ready
    case checking
    case usageUnknown
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
    /// The only time a missing reading sweeps: a fetch in flight, under 3 s.
    /// With no fetch running nothing is on its way, so nothing moves.
    var usageSweeping: Bool { usageLoading && !usageSlow }
    /// Flips false → true on every open; the content rises into place off it.
    @Published var presented = true
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
    @Published var fleet: FleetData?
    @Published var allSessions: [SessionInfo] = []
    @Published var sessionsLoading = false

    /// A profile's status and its capacity, read together because they answer
    /// halves of the same question.
    ///
    /// The number is the highest measured utilization across this profile's
    /// slots. A provider rejection affects availability without inventing a
    /// utilization percentage. nextBest independently finds an available slot.
    /// Missing readings contribute no number.
    func reading(_ profile: Profile, _ data: PanelData) -> (state: ProfileState, used: Int?) {
        let slotted = data.snapshot.installedVendors.filter { profile.slots[$0.id] != nil }
        let metered = slotted.filter(\.hasUsageAPI)
        func signedIn(_ v: Vendor) -> Bool { data.snapshot.signedIn[profile.name]?[v.id] != false }
        func row(_ v: Vendor) -> Usage? { usage[v.id]?[profile.name] }

        let live = metered.filter(signedIn)
        let readable = live.compactMap { row($0) }.filter { $0.isFresh && ($0.note == .ok || $0.note == .restricted) }
        let values = readable.compactMap(\.used)
        let used = values.max()

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
        if live.contains(where: { row($0)?.used == nil }) { return (.usageUnknown, used) }
        return (.ready, used)
    }

    /// Runnable headroom in each measured slot. Restrictions and the local
    /// scheduling reserve contribute zero; missing readings stay unknown.
    private var slotsLeft: [(profile: String, vendor: Vendor, left: Int)] {
        guard let data else { return [] }
        return data.profiles.flatMap { p in
            data.quotaVendors
                .filter { p.slots[$0.id] != nil && data.snapshot.signedIn[p.name]?[$0.id] != false }
                .compactMap { v in
                    usage[v.id]?[p.name].flatMap { u in u.availableRemaining.map { (p.name, v, $0) } }
                }
        }
    }

    /// Each profile's most constrained measured slot. Independent provider
    /// allowances cannot be averaged into capacity usable by a single task.
    private var profilesLeft: [(name: String, left: Int, slots: Int)] {
        let byProfile = Dictionary(grouping: slotsLeft, by: \.profile)
        return (data?.profiles ?? []).compactMap { p in
            byProfile[p.name].map { (p.name, $0.map(\.left).min() ?? 0, $0.count) }
        }
    }

    /// The icon warns about the most constrained measured slot. The next-agent
    /// action separately identifies a slot with capacity. Unknown is not zero.
    var remaining: Int? { slotsLeft.map(\.left).min() }

    /// Low is the icon's orange tier or worse: under 50% left.
    static let lowFrom = StatusIcon.Tier.orange

    /// Everything running low, broadest first: overall, each profile, each
    /// lab in a profile. A mean over a single slot is that slot again, so
    /// it's only listed once, as the slot.
    var lowQuota: [LowQuota] {
        let profiles = profilesLeft
        var all: [LowQuota] = []
        if profiles.count > 1, let overall = remaining {
            all.append(LowQuota(id: "*", title: "Lowest measured headroom", left: overall))
        }
        all += profiles.filter { $0.slots > 1 }.map { LowQuota(id: $0.name, title: $0.name, left: $0.left) }
        all += slotsLeft.map { LowQuota(id: "\($0.profile)/\($0.vendor.id)", title: "\($0.vendor.label) · \($0.profile)", left: $0.left) }
        return all.filter { $0.tier >= Self.lowFrom }
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
        var sawUnknown = false
        for i in slots.indices {
            let (profile, vendor) = slots[(after + 1 + i) % slots.count]
            guard snap.signedIn[profile]?[vendor.id] != false else { continue }
            guard vendor.hasUsageAPI else { return .slot(profile: profile, vendor: vendor.id, used: nil) }
            guard let rows = usage[vendor.id] else {
                if usageLoading { return nil }
                sawUnknown = true
                continue
            }
            guard var u = rows[profile] else { sawUnknown = true; continue }
            if u.note == .sharedLogin, let shared = rows["Default"] { u = shared }
            if u.maxed {
                sawMaxed = true
                if let back = u.maxedUntil { firstBack.append(back) }
                continue
            }
            guard u.note == .ok, u.used != nil else { sawUnknown = true; continue }
            return .slot(profile: profile, vendor: vendor.id, used: u.used)
        }
        if sawUnknown { return .usageUnavailable }
        return sawMaxed ? .allMaxed(firstBack: firstBack.min()) : .nothingSignedIn
    }
}

/// What the panel can ask the app to do. Everything with a side effect goes
/// through the delegate, which goes through the `agents` CLI.
protocol PanelActions: AnyObject {
    func openSession(profile: String, vendor: String, terminal: String?)
    func setActive(profile: String, vendor: String?)
    func copyCommand(profile: String, vendor: String)
    func copyPath(_ path: String)
    func openDesktop(profile: String, vendor: String)
    func signIn(profile: String, vendor: String, confirm: Bool)
    func finishSetup(profile: String)
    func resumeSession(_ session: SessionInfo)
    func moveSession(_ session: SessionInfo, to profile: String)
    func copyResumeCommand(_ session: SessionInfo)
    func showAllSessions()
    func closeSessions()
    func showSettings()
    func closeSettings()
    func installCLI() -> String
    func addVendor(profile: String)
    func deleteProfile(_ name: String)
    func newProfile()
    func retryUsage()
    func setPreferredTerminal(_ name: String)
    func setUpdateChannel(_ channel: UpdateChannel)
    var panelShortcut: String? { get }
    func setPanelShortcut()
    func checkForUpdates()
    func reportBug()
    func quit()
}
