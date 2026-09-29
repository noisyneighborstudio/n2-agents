import Foundation

// When a lab's allowance crosses 50, 25 and 10% left, and when it runs out,
// the panel says so once — the tier entered, never each step of a jump.

enum UsageTier: Int, Comparable {
    case half = 1    // 50% left or less
    case quarter     // 25% or less
    case low         // 10% or less
    case out         // nothing left, or the provider refuses work

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Only a fresh, measured status has a tier: unmetered, failed, stale,
    /// checking and signed-out slots never warn.
    init?(_ status: SlotStatus) {
        switch status {
        case .ready(let left), .low(let left):
            guard left <= 50 else { return nil }
            self = left <= 10 ? .low : left <= 25 ? .quarter : .half
        case .out: self = .out
        case .unmetered, .checkFailed, .signedOut, .checking: return nil
        }
    }

    /// Seconds a toast stays up on its own; nil stays until dismissed.
    var autoDismiss: TimeInterval? {
        switch self {
        case .half: return 5.2
        case .quarter: return 8
        case .low, .out: return nil
        }
    }
}

/// One slot's warning: which slot, how far down, and what it's measured against.
struct UsageWarning: Equatable {
    let profile: String
    let vendor: String
    let status: SlotStatus
    let tier: UsageTier
    /// The binding window, for the pace sentence.
    let window: Usage.Window?

    var id: String { "\(profile)|\(vendor)" }
    var left: Int { status.left ?? 0 }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.status == b.status && a.tier == b.tier }
}

/// What has been announced, per slot. A slot is announced when it enters a
/// worse tier than the last one announced; a multi-tier jump announces the
/// tier it lands in; a reading back above a tier lowers the record, so the
/// next dip is news again. A slot with no fresh reading keeps its record:
/// not knowing is not recovering.
struct ToastLadder {
    private(set) var announced: [String: UsageTier] = [:]

    /// `warnings`: every slot at a tier now. `measured`: every slot with a
    /// fresh reading, tiered or not. Returns what's newly worse.
    mutating func update(_ warnings: [UsageWarning], measured: Set<String>) -> [UsageWarning] {
        var fresh: [UsageWarning] = []
        let now = Dictionary(warnings.map { ($0.id, $0) }) { a, _ in a }
        for id in measured where now[id] == nil { announced[id] = nil }
        for w in warnings {
            if let last = announced[w.id], w.tier <= last {
                announced[w.id] = w.tier
            } else {
                fresh.append(w)
                announced[w.id] = w.tier
            }
        }
        return fresh
    }
}

/// How a window is being spent, from its length and reset; nil when either
/// is missing — never an estimate.
struct Pace: Equatable {
    /// Fraction of the window already gone, 0...1.
    let elapsed: Double
    /// Fraction of the allowance used, 0...1.
    let used: Double
    let resets: Date
    /// When the allowance runs out at the rate so far; nil if nothing is used.
    let exhausts: Date?
    /// A window longer than a week is spoken of as a month.
    let monthly: Bool

    init?(_ window: Usage.Window?, now: Date = Date()) {
        guard let window, let duration = window.durationSeconds, duration > 0, let resets = window.resets else { return nil }
        let elapsed = 1 - resets.timeIntervalSince(now) / duration
        guard elapsed > 0, elapsed <= 1 else { return nil }
        self.elapsed = elapsed
        used = min(max(window.percent / 100, 0), 1)
        self.resets = resets
        monthly = duration > 8 * 86400
        let start = resets.addingTimeInterval(-duration)
        exhausts = used > 0 ? now.addingTimeInterval((1 - used) / used * now.timeIntervalSince(start)) : nil
    }

    var lastsToReset: Bool { exhausts.map { $0 >= resets } ?? true }

    /// The half and quarter toasts' sentence.
    var sentence: String {
        guard let exhausts, !lastsToReset else {
            return String(localized: "At this pace it lasts until the reset, \(clockTime(resets)).", comment: "Toast: allowance outlasts the window")
        }
        return String(localized: "You’re ahead of pace. At this rate it runs out \(clockTime(exhausts)).", comment: "Toast: allowance runs out before the reset")
    }

    /// The 10% toast's sentence: the work left, in hours and minutes.
    func workLeft(now: Date = Date()) -> String {
        guard let exhausts, !lastsToReset else { return sentence }
        let left = Duration.seconds(max(60, exhausts.timeIntervalSince(now)))
        return String(localized: "About \(left.formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 1))) of work left at this pace.",
                      comment: "Toast: time until the allowance runs out")
    }
}

extension PanelModel {
    /// Every slot at a tier now, and every slot with a fresh reading.
    var usageWarnings: (warnings: [UsageWarning], measured: Set<String>) {
        guard let data else { return ([], []) }
        var warnings: [UsageWarning] = []
        var measured: Set<String> = []
        for p in data.profiles {
            for v in data.slotted(p) {
                let s = status(p.name, v).status
                let id = "\(p.name)|\(v.id)"
                switch s {
                case .ready, .low, .out: measured.insert(id)
                case .unmetered, .checkFailed, .signedOut, .checking: continue
                }
                guard let tier = UsageTier(s) else { continue }
                let window = effectiveUsage(p.name, v.id)?.windows?.max { $0.percent < $1.percent }
                warnings.append(UsageWarning(profile: p.name, vendor: v.id, status: s, tier: tier, window: window))
            }
        }
        return (warnings, measured)
    }
}
