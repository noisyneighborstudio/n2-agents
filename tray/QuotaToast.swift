import AppKit
import SwiftUI

// A notice under the menu bar icon when a lab's allowance crosses 50, 25 or
// 10% left, or runs out: once per tier entered, the worst tier on a jump. It
// never takes focus. Half and quarter leave on their own; 10% and out stay
// until dismissed. Clicking one opens the panel on that lab's page.
final class QuotaToast {
    private let anchor: NSStatusBarButton
    private let model: PanelModel
    private weak var actions: PanelActions?
    private let open: (UsageWarning) -> Void
    private var window: GlassWindow?
    private var ladder = ToastLadder()
    private var expiry: DispatchWorkItem?

    init(anchor: NSStatusBarButton, model: PanelModel, actions: PanelActions,
         open: @escaping (UsageWarning) -> Void) {
        self.anchor = anchor
        self.model = model
        self.actions = actions
        self.open = open
    }

    /// Takes every slot at a tier now and announces what has gone a tier
    /// lower since last time. Quiet records it without showing: the open
    /// panel already says so.
    func update(quiet: Bool) {
        let (warnings, measured) = model.usageWarnings
        let fresh = ladder.update(warnings, measured: measured)
        guard !quiet, let worst = fresh.max(by: { $0.tier < $1.tier }) else { return }
        show(worst)
    }

    func dismiss() {
        expiry?.cancel()
        window?.dismiss()
    }

    private func show(_ warning: UsageWarning) {
        guard let actions, let data = model.data, let vendor = data.snapshot.vendor(warning.vendor) else { return }
        expiry?.cancel()
        window?.orderOut(nil)
        let card = UsageToastCard(warning: warning, vendor: vendor, model: model, actions: actions,
                                  open: { [weak self] in
                                      self?.dismiss()
                                      self?.open(warning)
                                  },
                                  close: { [weak self] in self?.dismiss() })
        let window = GlassWindow(rootView: card, behavior: .toast(anchor: anchor), cornerRadius: 18)
        self.window = window
        window.present()
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: card.announcement,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        if let seconds = warning.tier.autoDismiss {
            let expiry = DispatchWorkItem { [weak self] in self?.dismiss() }
            self.expiry = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: expiry)
        }
    }
}

struct UsageToastCard: View {
    let warning: UsageWarning
    let vendor: Vendor
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let open: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @State private var drained = false

    private var accent: Color {
        switch warning.tier {
        case .half: return Ink.info
        case .quarter: return Ink.yellow
        case .low, .out: return Ink.amber
        }
    }

    /// "Codex · 25% left", with the profile when more than one holds the lab.
    var title: String {
        let shared = (model.data?.profiles.filter { $0.slots[warning.vendor] != nil }.count ?? 0) > 1
        let lab = shared ? String(localized: "\(vendor.label) in \(warning.profile)", comment: "Toast: a lab in a named profile")
                         : vendor.label
        switch warning.tier {
        case .half: return String(localized: "\(lab) · half left", comment: "Toast title: 50% tier")
        case .quarter: return String(localized: "\(lab) · 25% left", comment: "Toast title: 25% tier")
        case .low: return String(localized: "\(lab) · 10% left", comment: "Toast title: 10% tier")
        case .out: return String(localized: "\(lab) is out", comment: "Toast title: out of allowance")
        }
    }

    /// One sentence, or none: the pace needs the window's length and reset,
    /// and a return time needs to be known.
    var sub: String? {
        let pace = Pace(warning.window)
        switch warning.tier {
        case .half, .quarter:
            return pace?.sentence ?? warning.window?.resets.map {
                String(localized: "Resets \(clockTime($0))", comment: "Toast: when the window resets")
            }
        case .low:
            return pace?.workLeft() ?? warning.window?.resets.map {
                String(localized: "Resets \(clockTime($0))", comment: "Toast: when the window resets")
            }
        case .out:
            guard case .out(let back?) = warning.status else { return nil }
            let countdown = Duration.seconds(max(0, back.timeIntervalSinceNow))
                .formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2))
            return String(localized: "Back \(SlotStatus.day(back)) at \(back.formatted(.dateTime.hour().minute())) · in \(countdown)",
                          comment: "Toast: the day and time allowance returns, and how long until then")
        }
    }

    var announcement: String { [title, sub].compactMap { $0 }.joined(separator: ". ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    StatusRing(status: warning.status, diameter: 44, stroke: 4, glyph: false)
                        .overlay {
                            // The tier's accent, over the status arc.
                            if warning.left > 0 {
                                Circle().inset(by: 2).trim(from: 0, to: CGFloat(warning.left) / 100)
                                    .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
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
            // Half leaves on its own: a 2 pt bar drains over its time.
            if let seconds = warning.tier.autoDismiss, warning.tier == .half {
                Rectangle().fill(accent.opacity(0.75)).frame(height: 2)
                    .scaleEffect(x: drained ? 0 : 1, anchor: .leading)
                    .onAppear { withAnimation(.linear(duration: seconds)) { drained = true } }
            }
        }
        .overlay {
            if warning.tier == .out {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Ink.Tone.amber.wash(dark: 0.45, light: 0.65), lineWidth: 1)
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
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(announcement)
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

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.track).frame(height: 6)
                    Capsule().fill(accent).frame(width: g.size.width * pace.used, height: 6)
                    RoundedRectangle(cornerRadius: 1).fill(Ink.tick).frame(width: 2, height: 12)
                        .padding(1.5).background(RoundedRectangle(cornerRadius: 2.5).fill(Ink.page))
                        .offset(x: g.size.width * pace.elapsed - 2.5)
                }
                .frame(height: 15)
            }
            .frame(height: 15)
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
