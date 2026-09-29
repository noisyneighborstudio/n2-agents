import SwiftUI

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

// The ring every surface draws for a slot: remaining allowance as an arc from
// twelve o'clock, clockwise, or a shape that says why there is none.
struct StatusRing: View {
    let status: SlotStatus
    var diameter: CGFloat = 18
    var stroke: CGFloat = 2.5
    /// The small ring carries its state's glyph inside; bigger rings hold a logo.
    var glyph = true

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
                    .trim(from: 0, to: CGFloat(left) / 100)
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
