import SwiftUI

/// "3:20 PM" today, "Fri 3:20 PM" further out — a weekly window resets days away.
// A weekday names a day only within the week: a monthly reset gets its date.
func clockTime(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
    if date.timeIntervalSinceNow > 6 * 86400 { return date.formatted(.dateTime.month(.abbreviated).day()) }
    return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

// One closed status vocabulary for every surface that shows a slot: strip,
// row, hero, toast and menu bar icon. No view decides a slot's status on its
// own; each asks for it here and draws what it is given.
enum SlotStatus: Equatable {
    case ready(left: Int)          // 20...100 left
    case low(left: Int)            // 1...19 left
    case out(back: Date?)          // nothing left, or the provider refuses work
    case unmetered                 // the lab has no usage API
    case checkFailed               // the last reading failed or is stale: nothing is known
    case signedOut                 // no usable credentials
    case checking                  // a reading is on its way and nothing is known yet

    /// What a slot is, from its lab, its login and its reading. A shared-login
    /// slot is passed Default's reading (PanelModel.effectiveUsage).
    static func of(_ usage: Usage?, vendor: Vendor, signedIn: Bool?, checking: Bool, now: Date = Date()) -> SlotStatus {
        if signedIn == false { return .signedOut }
        guard vendor.hasUsageAPI else { return .unmetered }
        guard let usage else { return checking ? .checking : .checkFailed }
        switch usage.note {
        case .ok:
            guard let binding = usage.binding else { return .checkFailed }
            let left = 100 - binding.percent
            return left >= 20 ? .ready(left: left) : left > 0 ? .low(left: left) : .out(back: binding.resets)
        case .restricted:
            guard usage.isFresh(at: now) else { return .checkFailed }
            return .out(back: usage.maxedUntil)
        case .noUsageAPI:
            return .unmetered
        // The tray's own mark for an ok reading gone stale; the CLI never sends it.
        case .expired:
            return .checkFailed
        // A 429 from the usage probe: the reading failed, not the allowance.
        case .rateLimited, .fetchError:
            return .checkFailed
        // Rejected (401/403) or expired credentials, or none at all.
        case .staleToken, .noToken:
            return .signedOut
        // Resolved by effectiveUsage before this is called; reaching here
        // means Default's row is missing too.
        case .sharedLogin:
            return checking ? .checking : .checkFailed
        // Open question Q2: no copy yet, so these read as a failed check with
        // the raw note shown under Diagnostics.
        case .credentialOverride, .credentialStoreUnavailable, .ownerUnavailable, .migrationPending:
            return .checkFailed
        }
    }

    /// Remaining allowance, only where it is known. Nothing else shows a percentage.
    var left: Int? {
        switch self {
        case .ready(let left), .low(let left): return left
        case .out, .unmetered, .checkFailed, .signedOut, .checking: return nil
        }
    }

    var ink: Color {
        switch self {
        case .ready(let left): return left >= 50 ? Ink.green : Ink.yellow
        case .low, .out: return Ink.amber
        case .unmetered, .checking: return Ink.secondary
        case .checkFailed: return Ink.yellow
        case .signedOut: return Ink.red
        }
    }

    /// The ink as a ring or bar track: tinted where the state itself is the news.
    var track: Color {
        switch self {
        case .out: return Ink.Tone.amber.wash(0.35)
        case .checkFailed: return Ink.Tone.yellow.wash(0.35)
        case .signedOut: return Ink.Tone.red.wash(0.35)
        case .ready, .low, .unmetered, .checking: return Ink.track
        }
    }

    /// The logo tile under a slot: neutral while there is capacity to read,
    /// washed in the status ink when the state itself is the news.
    var tileFill: Color {
        switch self {
        case .ready, .low, .checking: return Ink.tile
        case .out: return Ink.Tone.amber.wash(0.16)
        case .unmetered: return Ink.Tone.neutral.wash(0.06)
        case .checkFailed: return Ink.Tone.yellow.wash(0.14)
        case .signedOut: return Ink.Tone.red.wash(0.14)
        }
    }

    /// The logo on that tile: the status ink on a tinted tile, neutral otherwise.
    var logoInk: Color {
        switch self {
        case .ready, .low, .checking: return Ink.logo
        case .out, .checkFailed, .signedOut: return ink
        case .unmetered: return Ink.secondary
        }
    }

    /// The label a row shows beside its ring.
    var label: String {
        switch self {
        case .ready(let left), .low(let left):
            return String(localized: "\(Self.percent(left)) left", comment: "Profile page row: allowance remaining")
        case .out: return String(localized: "Back", comment: "Profile page row: out of allowance, followed by the day it returns")
        case .unmetered: return String(localized: "Not metered", comment: "Profile page row: the lab reports no usage")
        case .checkFailed: return String(localized: "Check failed", comment: "Profile page row: the last usage check failed")
        case .signedOut: return String(localized: "Signed out", comment: "Profile page row: no usable login")
        case .checking: return String(localized: "Checking…", comment: "Profile page row: a usage check is running")
        }
    }

    /// The value a capacity-strip segment shows beside its logo.
    var stripValue: String {
        switch self {
        case .ready(let left), .low(let left): return Self.percent(left)
        case .out(let back):
            return back.map(Self.day) ?? String(localized: "out", comment: "Capacity strip: out of allowance, return unknown")
        case .unmetered: return "—"
        case .checkFailed: return "?"
        case .signedOut: return String(localized: "off", comment: "Capacity strip: signed out")
        case .checking: return "…"
        }
    }

    /// The Provider page's headline.
    func headline(monthly: Bool) -> String {
        switch self {
        case .ready(100):
            return String(localized: "Full allowance left", comment: "Provider hero: nothing used")
        case .ready(let left), .low(let left):
            return monthly ? String(localized: "\(Self.percent(left)) left this month", comment: "Provider hero: monthly allowance left")
                           : String(localized: "\(Self.percent(left)) left this week", comment: "Provider hero: weekly allowance left")
        case .out(let back?):
            return String(localized: "Out until \(back.formatted(.dateTime.weekday(.wide)))", comment: "Provider hero: out until a weekday")
        case .out(nil):
            return String(localized: "Out of allowance", comment: "Provider hero: out, return unknown")
        case .unmetered: return String(localized: "Usage isn’t metered", comment: "Provider hero: lab reports no usage")
        case .checkFailed: return String(localized: "Couldn’t read usage", comment: "Provider hero: the check failed")
        case .signedOut: return String(localized: "Not signed in", comment: "Provider hero: no login")
        case .checking: return String(localized: "Checking usage…", comment: "Provider hero: a check is running")
        }
    }

    /// The one sentence under the headline; nil when it would have to say "unknown".
    func sub(provider: String, resets: Date?, monthly: Bool) -> String? {
        switch self {
        case .ready, .low:
            guard let resets else { return nil }
            return monthly ? String(localized: "Monthly · resets \(resets.formatted(.dateTime.month(.abbreviated).day()))", comment: "Provider hero: monthly reset date")
                           : String(localized: "Resets \(clockTime(resets))", comment: "Provider hero: when the window resets")
        case .out(let back):
            guard let back else { return nil }
            return String(localized: "Back \(back.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) at \(back.formatted(.dateTime.hour().minute()))",
                          comment: "Provider hero: the date and time allowance returns")
        case .unmetered:
            return String(localized: "\(provider) doesn’t report quota. Start freely.", comment: "Provider hero: unmetered lab")
        case .checkFailed:
            return String(localized: "The last check failed. You can still start a session.", comment: "Provider hero: failed check")
        case .signedOut:
            return String(localized: "Sign in to start sessions and read usage.", comment: "Provider hero: signed out")
        case .checking:
            return nil
        }
    }

    /// Up to three tags under the hero: the window, what's used, and why
    /// nothing is known. "Used" appears here and in Diagnostics, nowhere else.
    func chips(_ usage: Usage?, monthly: Bool) -> [(symbol: String, text: String)] {
        var chips: [(String, String)] = []
        let window = monthly ? String(localized: "Monthly window", comment: "Provider chip") : String(localized: "7-day window", comment: "Provider chip")
        switch self {
        case .ready(let left), .low(let left):
            chips.append(("clock", window))
            if left < 100 {
                chips.append(("gauge.with.needle", String(localized: "\(Self.percent(100 - left)) used", comment: "Provider chip: allowance used")))
            }
        case .out:
            if usage?.note == .restricted {
                chips.append(("gauge.with.needle", String(localized: "Restricted", comment: "Provider chip: the provider refuses work")))
            } else {
                chips.append(("clock", window))
            }
        case .unmetered: chips.append(("info.circle", String(localized: "No quota API", comment: "Provider chip")))
        case .checkFailed: chips.append(("info.circle", String(localized: "Check failed", comment: "Provider chip")))
        case .signedOut: chips.append(("info.circle", String(localized: "No credentials", comment: "Provider chip")))
        case .checking: break
        }
        // Credits only when the CLI reports a zero balance (open question Q6).
        if usage?.creditNotes.contains(where: { $0.split(separator: " ").last.flatMap { Double($0) } == 0 }) == true {
            chips.append(("bolt", String(localized: "0 credits", comment: "Provider chip: no credit balance")))
        }
        return Array(chips.prefix(3))
    }

    /// The badge on the hero tile, for states whose shape is a glyph.
    var badge: String? {
        switch self {
        case .out: return "hourglass"
        case .checkFailed: return "exclamationmark"
        case .signedOut: return "xmark"
        case .ready, .low, .unmetered, .checking: return nil
        }
    }

    static func percent(_ value: Int) -> String {
        (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// "Fri" within the week, "Oct 21" beyond it.
    static func day(_ date: Date) -> String {
        date.timeIntervalSinceNow > 6 * 86400 ? date.formatted(.dateTime.month(.abbreviated).day())
                                              : date.formatted(.dateTime.weekday(.abbreviated))
    }
}

extension LogoTile {
    init(vendor: Vendor, status: SlotStatus) {
        self.init(vendor: vendor, fill: status.tileFill, ink: status.logoInk)
    }
}

extension PanelModel {
    /// A slot's status and the reset its row names: the binding window's for a
    /// reading, the return for a slot that's out.
    func status(_ profile: String, _ vendor: Vendor) -> (status: SlotStatus, resets: Date?) {
        let usage = effectiveUsage(profile, vendor.id)
        let status = SlotStatus.of(usage, vendor: vendor, signedIn: data?.snapshot.signedIn[profile]?[vendor.id],
                                   checking: usageLoading)
        switch status {
        case .ready, .low: return (status, usage?.binding?.resets)
        case .out(let back): return (status, back)
        case .unmetered, .checkFailed, .signedOut, .checking: return (status, nil)
        }
    }
}

/// The raw facts behind a slot's status, only those present.
enum Diagnostics {
    static func facts(_ usage: Usage?, shared: Bool) -> [(key: String, value: String)] {
        guard let u = usage else { return [] }
        var facts: [(String, String)] = []
        if let hash = u.accountHash {
            facts.append((String(localized: "Account", comment: "Diagnostics key"), "\(hash.prefix(4))…\(hash.suffix(5))"))
        }
        if u.hasObservationTime {
            facts.append((String(localized: "Observed", comment: "Diagnostics key"),
                          u.fetchedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())))
        }
        var signal = [u.note.rawValue] + u.restrictionReasons
        if shared { signal.append(String(localized: "Shared login (Default)", comment: "Diagnostics: slot uses Default's login")) }
        facts.append((String(localized: "Signal", comment: "Diagnostics key"), signal.joined(separator: " · ")))
        if let window = u.windows?.max(by: { $0.percent < $1.percent }) {
            facts.append((String(localized: "Window", comment: "Diagnostics key"), window.label))
            facts.append((String(localized: "Used", comment: "Diagnostics key"),
                          (window.percent / 100).formatted(.percent.precision(.fractionLength(1)))))
            if let resets = window.resets {
                facts.append((String(localized: "Resets", comment: "Diagnostics key"),
                              resets.formatted(.dateTime.month(.abbreviated).day().hour().minute())))
            }
        }
        if !u.creditNotes.isEmpty {
            facts.append((String(localized: "Credits", comment: "Diagnostics key"), u.creditNotes.joined(separator: "; ")))
        }
        return facts
    }
}

/// A lab with room to start in instead of one that's out or low. Only a
/// fresh, ready reading qualifies — never unmetered, failed, stale, checking
/// or signed out — so a suggestion never advertises capacity nobody measured.
struct Suggestion: Equatable {
    let profile: String
    let vendor: String
    let left: Int
    let resets: Date?
    /// Found in the same profile, so its card needn't name the profile.
    let sameProfile: Bool

    struct Slot {
        let profile: String
        let vendor: String
        let status: SlotStatus
        let resets: Date?
    }

    /// Same profile first, most left, soonest reset breaking ties; failing
    /// that, the fleet's next best if it qualifies; failing that, none.
    static func pick(for profile: String, vendor: String, among slots: [Slot],
                     nextBest: (profile: String, vendor: String)?) -> Suggestion? {
        func ready(_ s: Slot) -> Int? { if case .ready(let left) = s.status { return left }; return nil }
        let candidates = slots.filter { ready($0) != nil && !($0.profile == profile && $0.vendor == vendor) }
        let mine = candidates.filter { $0.profile == profile }.sorted { a, b in
            let (la, lb) = (ready(a)!, ready(b)!)
            if la != lb { return la > lb }
            return (a.resets ?? .distantFuture) < (b.resets ?? .distantFuture)
        }
        if let best = mine.first {
            return Suggestion(profile: best.profile, vendor: best.vendor, left: ready(best)!, resets: best.resets, sameProfile: true)
        }
        if let next = nextBest, let slot = candidates.first(where: { $0.profile == next.profile && $0.vendor == next.vendor }) {
            return Suggestion(profile: slot.profile, vendor: slot.vendor, left: ready(slot)!, resets: slot.resets, sameProfile: false)
        }
        return nil
    }
}

extension PanelModel {
    /// The suggestion for an out or low slot's page, nil for any other state.
    func suggestion(for profile: String, _ vendor: Vendor) -> Suggestion? {
        switch status(profile, vendor).status {
        case .out, .low: break
        default: return nil
        }
        guard let data else { return nil }
        let slots = data.profiles.flatMap { p in
            data.slotted(p).map { v -> Suggestion.Slot in
                let (s, r) = status(p.name, v)
                return .init(profile: p.name, vendor: v.id, status: s, resets: r)
            }
        }
        var best: (String, String)?
        if case .slot(let p, let v, _)? = nextBest { best = (p, v) }
        return Suggestion.pick(for: profile, vendor: vendor.id, among: slots, nextBest: best)
    }

    /// Switch: go to the suggested lab's page. It opens nothing and binds no
    /// account — the page's Start does that, as a new session.
    func switchTo(_ s: Suggestion) {
        let target = PanelRoute.provider(profile: s.profile, vendor: s.vendor)
        withAnimation(Motion.nav(reduce: Motion.reduced)) {
            if s.sameProfile, !path.isEmpty {
                path[path.count - 1] = target
            } else {
                path = [.profile(s.profile), target]
            }
        }
    }
}

/// One line that says where a profile stands, first match wins: anything
/// signed out, anything out, anything low, anything unread.
struct ProfileNote: Equatable {
    enum Tone { case red, amber, plain }
    let text: String
    let tone: Tone

    var ink: Color {
        switch tone {
        case .red: return Ink.red
        case .amber: return Ink.amber
        case .plain: return Ink.secondary
        }
    }

    static func of(_ statuses: [SlotStatus], pending: Int = 0) -> ProfileNote {
        func count(_ match: (SlotStatus) -> Bool) -> Int { statuses.filter(match).count }
        let signedOut = count { $0 == .signedOut } + pending
        let out = count { if case .out = $0 { return true }; return false }
        let low = count { if case .low = $0 { return true }; return false }
        let unchecked = count { $0 == .checkFailed }
        if signedOut > 0 {
            return .init(text: String(localized: "\(signedOut) signed out", comment: "Profile note: labs with no login"), tone: .red)
        }
        if out > 0 {
            return .init(text: unchecked > 0
                         ? String(localized: "\(out) out · \(unchecked) check failed", comment: "Profile note: labs out of allowance, labs whose check failed")
                         : String(localized: "\(out) out", comment: "Profile note: labs out of allowance"), tone: .amber)
        }
        if low > 0 {
            return .init(text: String(localized: "\(low) running low", comment: "Profile note: labs under 20% left"), tone: .amber)
        }
        if unchecked > 0 {
            return .init(text: String(localized: "\(unchecked) check failed", comment: "Profile note: labs whose usage check failed"), tone: .amber)
        }
        if statuses.contains(.checking) {
            return .init(text: String(localized: "Checking…", comment: "Profile note: usage checks running"), tone: .plain)
        }
        return .init(text: String(localized: "All ready", comment: "Profile note: every lab can start work"), tone: .plain)
    }
}

/// The Fleet header's three counts, summed over every slot the cards show.
struct FleetTally: Equatable {
    var ready = 0      // ready, low and unmetered: can start work
    var out = 0
    var attention = 0  // a failed check or a sign-out to fix

    init(_ statuses: [SlotStatus]) {
        for s in statuses {
            switch s {
            case .ready, .low, .unmetered: ready += 1
            case .out: out += 1
            case .checkFailed, .signedOut: attention += 1
            case .checking: break
            }
        }
    }
}

extension PanelModel {
    func statuses(_ profile: Profile) -> [SlotStatus] {
        (data?.slotted(profile) ?? []).map { status(profile.name, $0).status }
    }

    func note(_ profile: Profile) -> ProfileNote {
        let slotted = Set(data?.slotted(profile).map(\.id) ?? [])
        let signedOut = Set((data?.slotted(profile) ?? []).filter { status(profile.name, $0).status == .signedOut }.map(\.id))
        // Labs whose setup never finished count as signed out, once.
        let pending = Set(pendingSetups[profile.name] ?? []).intersection(slotted).subtracting(signedOut).count
        return ProfileNote.of(statuses(profile), pending: pending)
    }

    var tally: FleetTally { FleetTally((data?.profiles ?? []).flatMap(statuses)) }
}

// The ring every surface draws for a slot: remaining allowance as an arc from
// twelve o'clock, clockwise, or a shape that says why there is none.
struct StatusRing: View {
    let status: SlotStatus
    var diameter: CGFloat = 18
    var stroke: CGFloat = 2.5
    /// The small ring carries its state's glyph inside; bigger rings hold a logo.
    var glyph = true
    /// How much of the arc is drawn, for rings that draw in (0...1).
    var drawn: CGFloat = 1

    var body: some View {
        ZStack {
            switch status {
            case .unmetered:
                Circle().inset(by: stroke / 2)
                    .stroke(Ink.secondary.opacity(0.6),
                            style: StrokeStyle(lineWidth: stroke * 0.8, dash: [stroke * 0.8, stroke * 1.28]))
            case .checking:
                Circle().inset(by: stroke / 2).stroke(Ink.track, lineWidth: stroke)
                Spinner(stroke: stroke)
            default:
                Circle().inset(by: stroke / 2).stroke(status.track, lineWidth: stroke)
            }
            // At 0% no arc: a round cap alone would draw a dot.
            if let left = status.left, left > 0 {
                Circle().inset(by: stroke / 2)
                    .trim(from: 0, to: CGFloat(left) / 100 * drawn)
                    .stroke(status.ink, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if glyph { inner }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var inner: some View {
        let size = diameter * 0.44
        switch status {
        case .out:
            ClockHands().stroke(status.ink, style: StrokeStyle(lineWidth: stroke * 0.72, lineCap: .round))
                .frame(width: size, height: size)
        case .signedOut:
            Cross().stroke(status.ink, style: StrokeStyle(lineWidth: stroke * 0.72, lineCap: .round))
                .frame(width: size * 0.9, height: size * 0.9)
        case .checkFailed:
            Bang().stroke(status.ink, style: StrokeStyle(lineWidth: stroke * 0.72, lineCap: .round))
                .frame(width: size, height: size)
        case .ready, .low, .unmetered, .checking:
            EmptyView()
        }
    }
}

private struct ClockHands: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX + r.width * 0.36, y: r.midY + r.height * 0.24))
        return p
    }
}

private struct Cross: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        return p
    }
}

// "!": a stroke and a dot, the failed check's mark.
private struct Bang: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.58))
        p.move(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY - 0.01))
        return p
    }
}

// A quarter arc going round while a reading is on its way; still under Reduce Motion.
private struct Spinner: View {
    let stroke: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowOnScreen) private var onScreen

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || !onScreen)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            Circle().inset(by: stroke / 2)
                .trim(from: 0, to: 0.25)
                .stroke(Ink.secondary, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? -90 : turn * 360 - 90))
        }
    }
}

// The capacity strip's 3 pt bar: remaining allowance in the status ink. With
// nothing known it stays a bare track, never a full bar.
struct StatusBar: View {
    let status: SlotStatus

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(status.track)
                if let left = status.left {
                    Capsule().fill(status.ink).frame(width: g.size.width * CGFloat(left) / 100)
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}
