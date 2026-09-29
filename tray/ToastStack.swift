import AppKit
import SwiftUI

// Every live usage warning, in one window under the menu bar icon: newest on
// top, the two before it peeking beneath at the front card's height, more
// counted but hidden. Hovering fans the stack out at full heights and holds
// every timer; leaving folds it back.

/// The live toasts and their timers. A toast that leaves on its own keeps
/// counting only while the stack isn't hovered.
final class ToastFeed: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let warning: UsageWarning
        /// The remaining allowance last announced for this slot: the ring sweeps from it.
        let from: Int
        /// Seconds left before it leaves on its own, nil if it stays.
        var remaining: TimeInterval?
        var deadline: Date?
    }

    static let limit = 4

    /// Oldest first.
    @Published private(set) var items: [Item] = []
    @Published private(set) var hovered = false
    /// Told when a toast leaves, by timer or by hand.
    var onDismiss: ((Item) -> Void)?
    private var timers: [UUID: DispatchWorkItem] = [:]

    func add(_ warning: UsageWarning, from: Int) {
        // A fifth drops the oldest that would leave anyway, else the oldest.
        if items.count >= Self.limit, let drop = items.first(where: { $0.remaining != nil }) ?? items.first {
            dismiss(drop.id)
        }
        var item = Item(warning: warning, from: from, remaining: warning.tier.autoDismiss)
        if !hovered, let seconds = item.remaining { item.deadline = Date().addingTimeInterval(seconds) }
        withAnimation(Motion.toastIn(reduce: Motion.reduced)) { items.append(item) }
        schedule(item)
    }

    func dismiss(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        withAnimation(Motion.toastOut(reduce: Motion.reduced)) { _ = items.remove(at: index) }
        onDismiss?(item)
    }

    func dismissAll() {
        for item in items { dismiss(item.id) }
    }

    func hover(_ on: Bool) {
        guard on != hovered else { return }
        withAnimation(Motion.nav(reduce: Motion.reduced)) { hovered = on }
        let now = Date()
        for i in items.indices where items[i].remaining != nil {
            if on {
                // Hold: bank what's left and stop the clock.
                items[i].remaining = max(0, items[i].deadline?.timeIntervalSince(now) ?? items[i].remaining!)
                items[i].deadline = nil
                timers.removeValue(forKey: items[i].id)?.cancel()
            } else {
                items[i].deadline = now.addingTimeInterval(items[i].remaining!)
                schedule(items[i])
            }
        }
    }

    private func schedule(_ item: Item) {
        guard let deadline = item.deadline else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss(item.id) }
        timers[item.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: work)
    }
}

struct ToastStack: View {
    @ObservedObject var feed: ToastFeed
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let open: (UsageWarning) -> Void
    @State private var heights: [UUID: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Newest first.
    private var live: [ToastFeed.Item] { feed.items.reversed() }

    var body: some View {
        let cards = live
        // Until a new card has measured itself, the stack keeps the last front's height.
        let front = cards.first.flatMap { heights[$0.id] } ?? cards.dropFirst().first.flatMap { heights[$0.id] } ?? 0
        let fanned = feed.hovered
        // Each card's top: stacked 12 apart when folded, at full heights 10 apart when fanned.
        let tops: [CGFloat] = cards.indices.map { d in
            fanned ? cards.prefix(d).reduce(0) { $0 + (heights[$1.id] ?? front) + 10 } : CGFloat(min(d, 2)) * 12
        }
        let height = cards.isEmpty ? 0 : fanned ? (tops.last ?? 0) + (heights[cards.last!.id] ?? front)
                                                : front + CGFloat(min(cards.count - 1, 2)) * 12
        ZStack(alignment: .top) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { d, item in
                let behind = !fanned && d > 0
                card(item, depth: d)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { heights[item.id] = $0 }
                    .opacity(behind ? 0 : 1)
                    .frame(height: behind ? front : nil, alignment: .top)
                    .background(CardSurface(tier: item.warning.tier))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .scaleEffect(fanned || reduceMotion ? 1 : 1 - CGFloat(min(d, 2)) * 0.05, anchor: .top)
                    .offset(y: tops[d])
                    .opacity(fanned ? 1 : d > 2 ? 0 : [1, 0.8, 0.5][d])
                    .zIndex(Double(-d))
                    .allowsHitTesting(fanned || d == 0)
                    .accessibilityHidden(!fanned && d > 0)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .modifier(active: Travel(scale: 0.32, y: -38, blur: 8, shown: false),
                                             identity: Travel(scale: 1, y: 0, blur: 0, shown: true)),
                        removal: .modifier(active: Travel(scale: 0.3, y: -72, blur: 0, shown: false),
                                           identity: Travel(scale: 1, y: 0, blur: 0, shown: true))))
            }
        }
        .frame(width: 360, height: height, alignment: .top)
        .animation(Motion.nav(reduce: reduceMotion), value: fanned)
        .onHover { feed.hover($0) }
        // Room for each card's shadow inside the window.
        .padding(.horizontal, 24).padding(.bottom, 40)
    }

    private func card(_ item: ToastFeed.Item, depth: Int) -> some View {
        Group {
            if let vendor = model.data?.snapshot.vendor(item.warning.vendor) {
                UsageToastCard(warning: item.warning, vendor: vendor, model: model, actions: actions, from: item.from,
                               drain: item.remaining.map { total in DrainClock(feed: feed, id: item.id, total: total) },
                               open: { feed.dismiss(item.id); open(item.warning) },
                               close: { feed.dismiss(item.id) })
            }
        }
    }
}

/// How far a half toast's time has run, for its draining bar; frozen while hovered.
struct DrainClock {
    let feed: ToastFeed
    let id: UUID
    let total: TimeInterval

    func fraction(at now: Date) -> CGFloat {
        guard let item = feed.items.first(where: { $0.id == id }), let remaining = item.remaining else { return 0 }
        let left = item.deadline.map { $0.timeIntervalSince(now) } ?? remaining
        return CGFloat(min(max(left / total, 0), 1))
    }
}

/// Arriving from the icon and leaving into it: scaled from the top centre,
/// lifted, blurred and faded.
private struct Travel: ViewModifier {
    let scale: CGFloat
    let y: CGFloat
    let blur: CGFloat
    let shown: Bool

    func body(content: Content) -> some View {
        content.scaleEffect(scale, anchor: .top).offset(y: y).blur(radius: blur).opacity(shown ? 1 : 0)
    }
}

/// A card's own glass, edge and shadow; the out card's edge breathes.
private struct CardSurface: View {
    let tier: UsageTier
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        CardGlass()
            .clipShape(shape)
            .overlay(shape.strokeBorder(Ink.toastEdge, lineWidth: 0.5))
            .overlay {
                if tier == .out {
                    // Dark: an amber glow and a 1 pt edge between two strengths.
                    // Light: no glow (muddy on pale glass), a 1.5 pt edge.
                    shape.strokeBorder(breathe ? Ink.outEdge.bright : Ink.outEdge.dim, lineWidth: 1)
                        .overlay(shape.inset(by: 1).strokeBorder(breathe ? Ink.outEdgeLight.bright : Ink.outEdgeLight.dim, lineWidth: 0.5))
                        .shadow(color: breathe ? Ink.outGlow.bright : Ink.outGlow.dim, radius: 12)
                }
            }
            .shadow(color: Ink.toastShadow, radius: 30, y: 20)
            .onAppear {
                guard tier == .out else { return }
                if reduceMotion { breathe = true } else {
                    withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
                }
            }
    }
}

/// Liquid Glass from macOS 26, the popover material before it: behind the
/// window, as the panel's own glass is.
private struct CardGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        return material
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// A ring that grows out of the menu bar icon and fades as a toast arrives,
/// in the tier's ink as the menu bar's own appearance resolves it.
enum IconPulse {
    static func fire(on button: NSStatusBarButton, tone: Ink.Tone, twice: Bool) {
        guard !Motion.reduced, let buttonWindow = button.window else { return }
        let icon = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let side = min(icon.width, icon.height)
        let color = Ink.isDark(button.effectiveAppearance) ? tone.dark : tone.light
        for i in 0..<(twice ? 2 : 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.22) { ring(around: icon, side: side, color: color) }
        }
    }

    private static func ring(around icon: NSRect, side: CGFloat, color: NSColor) {
        let extent = side * 2.8
        let frame = NSRect(x: icon.midX - extent / 2, y: icon.midY - extent / 2, width: extent, height: extent)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: (extent - side) / 2, y: (extent - side) / 2, width: side, height: side)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = color.cgColor
        ring.lineWidth = 1.5
        ring.opacity = 0
        view.layer?.addSublayer(ring)
        window.contentView = view
        window.orderFrontRegardless()
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.9
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { window.orderOut(nil) }
        ring.add(group, forKey: "pulse")
        CATransaction.commit()
    }
}
