import AppKit
import SwiftUI

// A notice under the menu bar icon when quota runs low — overall, for a
// profile, or for one lab in one. Each is announced as it enters a worse tier
// (orange under 50% left, red under 20%), once per tier until it recovers.
// It never takes focus, leaves on its own, and a click opens the panel.
final class QuotaToast {
    private let anchor: NSStatusBarButton
    private let open: () -> Void
    private var window: GlassWindow?
    /// id -> the worst tier already announced for it.
    private var announced: [String: StatusIcon.Tier] = [:]
    private var expiry: DispatchWorkItem?

    init(anchor: NSStatusBarButton, open: @escaping () -> Void) {
        self.anchor = anchor
        self.open = open
    }

    /// Takes everything low right now and announces what has gone a tier
    /// lower since last time. Quiet records it without showing: the open
    /// panel already says so.
    func update(_ low: [LowQuota], quiet: Bool) {
        let fresh = low.filter { $0.tier > announced[$0.id] ?? .amber }
        announced = Dictionary(uniqueKeysWithValues: low.map { ($0.id, $0.tier) })
        guard !fresh.isEmpty, !quiet else { return }
        show(fresh)
    }

    func dismiss() {
        expiry?.cancel()
        window?.dismiss()
    }

    private func show(_ items: [LowQuota]) {
        expiry?.cancel()
        window?.orderOut(nil)
        let view = QuotaToastView(items: items) { [weak self] in
            self?.dismiss()
            self?.open()
        }
        let window = GlassWindow(rootView: view, behavior: .toast(anchor: anchor), cornerRadius: 12)
        self.window = window
        window.present()
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: "N2 Agents usage warning: " + items.map { "\($0.title), \($0.left)% left" }.joined(separator: "; "),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        let expiry = DispatchWorkItem { [weak self] in self?.dismiss() }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: expiry)
    }
}

private struct QuotaToastView: View {
    let items: [LowQuota]
    let open: () -> Void

    // Laid out like a system notification: whose it is, then what.
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text("Usage warning").font(.system(size: 13, weight: .semibold))
                ForEach(items, id: \.id) { item in
                    HStack {
                        Text(verbatim: item.title).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 12)
                        Text(verbatim: "\(item.left)% left").font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(ink(item.tier))
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 290, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    /// Text-safe Ink, not the tier's glow colour: Ink has no orange, and
    /// amber is the nearest that holds 4.5:1.
    private func ink(_ tier: StatusIcon.Tier) -> Color { tier == .red ? Ink.red : Ink.amber }
}
