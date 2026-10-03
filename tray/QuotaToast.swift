import AppKit
import SwiftUI

// A notice under the menu bar icon when a lab's allowance crosses 50, 25 or
// 10% left, or runs out: once per tier entered, the worst tier on a jump. It
// never takes focus. Half and quarter leave on their own; 10% and out stay
// until dismissed. Clicking one opens the panel on that lab's page.
final class QuotaToast {
    private let anchor: NSStatusBarButton
    private let model: PanelModel
    private let feed = ToastFeed()
    private var ladder = ToastLadder()
    private var window: GlassWindow?
    /// The remaining allowance last announced per slot: the next ring sweeps from it.
    private var lastLeft: [String: Int] = [:]

    init(anchor: NSStatusBarButton, model: PanelModel, actions: PanelActions,
         open: @escaping (UsageWarning) -> Void, dismissed: @escaping (UsageWarning) -> Void) {
        self.anchor = anchor
        self.model = model
        let stack = ToastStack(feed: feed, model: model, actions: actions, open: open)
        let window = GlassWindow(rootView: stack, behavior: .toast(anchor: anchor), clear: true)
        self.window = window
        feed.onDismiss = { [weak self, weak window] item in
            dismissed(item.warning)
            if self?.feed.items.isEmpty == true {
                // The last card leaves into the icon before the window goes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    if self?.feed.items.isEmpty == true { window?.dismiss() }
                }
            }
        }
    }

    /// Takes every slot at a tier now and announces what has gone a tier
    /// lower since last time. Quiet records it without showing: the open
    /// panel already says so.
    func update(quiet: Bool) {
        let (warnings, measured) = model.usageWarnings
        let fresh = ladder.update(warnings, measured: measured)
        for w in fresh {
            if !quiet { show(w) }
            lastLeft[w.id] = w.left
        }
    }

    func dismiss() {
        feed.dismissAll()
    }

    /// Debug (QA builds): one slot through the four tiers, 2.4 s apart.
    func playWeek() {
        guard let data = model.data, let p = data.profiles.first(where: { $0.name == data.snapshot.active }) ?? data.profiles.first,
              let v = data.slotted(p).first(where: \.hasUsageAPI) else { return }
        let week = 7 * 86400.0
        for (i, used) in [50.0, 75, 90, 100].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(i) * 2.4) { [weak self] in
                let window = Usage.Window(scope: "seven_day", percent: used, resets: Date().addingTimeInterval(week * 0.4),
                                          durationSeconds: week)
                let status: SlotStatus = used >= 100 ? .out(back: window.resets) : used > 80 ? .low(left: Int(100 - used)) : .ready(left: Int(100 - used))
                guard let tier = UsageTier(status) else { return }
                self?.show(UsageWarning(profile: p.name, vendor: v.id, status: status, tier: tier, window: window))
            }
        }
    }

    private func show(_ warning: UsageWarning) {
        guard let window else { return }
        feed.add(warning, from: lastLeft[warning.id] ?? 100)
        lastLeft[warning.id] = warning.left
        if !window.isShowing { window.present() }
        IconPulse.fire(on: anchor, tone: warning.tier.tone, twice: warning.tier == .out)
        let label = model.data?.snapshot.vendor(warning.vendor)?.label ?? warning.vendor
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: model.toastCopy(warning, label: label).announcement,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

extension PanelModel {
    func toastCopy(_ warning: UsageWarning, label: String) -> ToastCopy {
        let holders = data?.profiles.filter { $0.slots[warning.vendor] != nil }.count ?? 0
        return ToastCopy(warning, label: label, shared: holders > 1)
    }
}

extension UsageTier {
    /// The tier's accent, as a tone for surfaces outside SwiftUI (the icon pulse).
    var tone: Ink.Tone {
        switch self {
        case .half: return .info
        case .quarter: return .yellow
        case .low, .out: return .amber
        }
    }
}

struct UsageToastCard: View {
    let warning: UsageWarning
    let vendor: Vendor
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    /// The remaining allowance announced before this: the ring sweeps from it.
    var from: Int = 100
    /// A toast that leaves on its own drains a bar over its time.
    var drain: DrainClock? = nil
    let open: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @State private var swept: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color {
        switch warning.tier {
        case .half: return Ink.info
        case .quarter: return Ink.yellow
        case .low, .out: return Ink.amber
        }
    }

    private var copy: ToastCopy { model.toastCopy(warning, label: vendor.label) }
    private var title: String { copy.title }
    private var sub: String? { copy.sub }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    StatusRing(status: warning.status, diameter: 44, stroke: 4, glyph: false)
                        .overlay {
                            // The tier's accent, swept from what was left last time to now.
                            let to = swept ?? CGFloat(warning.left) / 100
                            if to > 0 {
                                Circle().inset(by: 2).trim(from: 0, to: to)
                                    .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                        }
                        .onAppear {
                            guard !reduceMotion, from != warning.left else { return }
                            swept = CGFloat(from) / 100
                            withAnimation(Motion.reveal.delay(-0.02)) { swept = CGFloat(warning.left) / 100 }
                        }
                    LogoTile(vendor: vendor).frame(width: 22, height: 22)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("now", comment: "Toast: when it was raised").font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                    }
                    if let sub {
                        Text(verbatim: sub).font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if warning.tier == .quarter || warning.tier == .low, let pace = Pace(warning.window) {
                PaceBar(pace: pace, accent: accent).padding(.leading, 56)
            }
            if warning.tier == .low || warning.tier == .out,
               let v = model.data?.snapshot.vendor(warning.vendor),
               let suggestion = model.suggestion(for: warning.profile, v) {
                suggestionRow(suggestion)
            }
            if warning.tier == .out {
                Button {
                    actions.openSession(profile: warning.profile, vendor: warning.vendor, terminal: nil)
                    close()
                } label: {
                    Label(String(localized: "Start anyway", comment: "Toast: start though out of allowance"), systemImage: "apple.terminal")
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(radius: 9, fill: Ink.chipFill, scale: 0.97))
                .padding(.leading, 56)
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
        .frame(width: 360, alignment: .leading)
        .overlay(alignment: .bottom) {
            // Half leaves on its own: a 2 pt bar drains over its time, held while hovered.
            if let drain, warning.tier == .half {
                TimelineView(.animation) { context in
                    Rectangle().fill(accent.opacity(0.75)).frame(height: 2)
                        .scaleEffect(x: drain.fraction(at: context.date), anchor: .leading)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            // Close: on hover, and always to VoiceOver.
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Ink.raised))
                    .overlay(Circle().strokeBorder(Ink.raisedEdge, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel(String(localized: "Dismiss", comment: "Toast: close it"))
            .offset(x: 4, y: 4)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture(perform: open)
        .background(AlwaysHover { hovering = $0 })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(copy.announcement)
    }

    private func suggestionRow(_ s: Suggestion) -> some View {
        let label = model.data?.snapshot.vendor(s.vendor)?.label ?? s.vendor
        return HStack(spacing: 8) {
            if let v = model.data?.snapshot.vendor(s.vendor) {
                LogoTile(vendor: v).frame(width: 22, height: 22)
            }
            (Text(verbatim: label).fontWeight(.semibold)
             + Text(verbatim: " · ")
             + Text("\(SlotStatus.percent(s.left)) left", comment: "Toast suggestion: allowance left").foregroundColor(Ink.secondary))
                .font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 6)
            Button {
                // In a toast, Switch starts the suggested lab: a new session, no rebinding.
                actions.openSession(profile: s.profile, vendor: s.vendor, terminal: nil)
                close()
            } label: {
                Text("Switch", comment: "Toast suggestion: start in the suggested lab")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Capsule().fill(Ink.chip))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle(radius: 13, scale: 0.97))
        }
        .padding(.leading, 8).padding(.trailing, 7)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 11).fill(Ink.Tone.chip.wash(dark: 0.14, light: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Ink.Tone.chip.wash(dark: 0.45, light: 0.32), lineWidth: 0.5))
        .padding(.leading, 56)
    }
}

/// Used against time: the bar is what's used, the tick is how much of the
/// window has gone. Ahead of the tick is ahead of pace.
private struct PaceBar: View {
    let pace: Pace
    let accent: Color
    @State private var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.track).frame(height: 6)
                    Capsule().fill(accent).frame(width: g.size.width * pace.used, height: 6)
                        .scaleEffect(x: filled ? 1 : 0, anchor: .leading)
                    RoundedRectangle(cornerRadius: 1).fill(Ink.tick).frame(width: 2, height: 12)
                        .padding(1.5).background(RoundedRectangle(cornerRadius: 2.5).fill(Ink.page))
                        .offset(x: g.size.width * pace.elapsed - 2.5)
                }
                .frame(height: 15)
            }
            .frame(height: 15)
            .onAppear { if reduceMotion { filled = true } else { withAnimation(Motion.reveal) { filled = true } } }
            HStack {
                Text("\(SlotStatus.percent(Int((pace.used * 100).rounded()))) used", comment: "Toast pace: allowance used")
                Spacer()
                let gone = SlotStatus.percent(Int((pace.elapsed * 100).rounded()))
                Text(pace.monthly ? "\(gone) of the month gone" : "\(gone) of the week gone", comment: "Toast pace: window elapsed")
            }
            .font(.system(size: 11)).foregroundStyle(Ink.secondary).monospacedDigit()
        }
    }
}
