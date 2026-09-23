import AppKit
import SwiftUI

// A borderless window on Liquid Glass. NSPopover and titled windows always
// paint their own frosted material under the content, so both of N2's
// surfaces — the menu bar panel and the setup window — are this instead: the
// glass is the window. Before macOS 26 there is no Liquid Glass, and the
// popover material stands in.
final class GlassWindow: NSPanel {
    enum Behavior {
        /// The menu bar panel: pinned under the status item, and gone on Esc,
        /// a click elsewhere, or another window taking focus — a popover's job.
        case transient(anchor: NSStatusBarButton)
        /// A notice under the status item: shown without taking focus or
        /// activating the app, and gone when its owner dismisses it.
        case toast(anchor: NSStatusBarButton)
        /// The setup window: floats above everything, including the terminal
        /// that takes focus mid-sign-in, until it is closed.
        case floating
    }

    private let content: NSView
    private let behavior: Behavior
    private var clickMonitor: Any?
    /// Holds the content at its full size, pinned top-centre and clipped, so
    /// the window can unfurl around it without the layout moving.
    private let stage = NSView()
    /// The glass itself. It fills the window at rest; while the content
    /// resizes, it animates inside a window already at the larger size.
    private var surface = NSView()
    private let cornerRadius: CGFloat
    private var unfurling = false
    private var dismissing = false
    /// Bumped by every present/dismiss, so a stale animation's completion
    /// can't hide a panel that was reopened mid-furl.
    private var generation = 0

    /// Shown, and not on its way out.
    var isShowing: Bool { isVisible && !dismissing }

    /// The SwiftUI content's ideal size, as SwiftUI itself last measured it.
    private let measured = MeasuredSize()

    init<Root: View>(rootView: Root, behavior: Behavior, cornerRadius: CGFloat = 16) {
        let measured = self.measured
        let hosting = NSHostingView(rootView: Measured(root: rootView) { measured.update($0) })
        // Intrinsic size gives the first measurement, before the view has a
        // frame to lay out in; SwiftUI's own reports take over from there.
        hosting.sizingOptions = [.intrinsicContentSize]
        content = hosting
        self.behavior = behavior
        self.cornerRadius = cornerRadius
        var style: NSWindow.StyleMask = [.borderless]
        // Clickable without pulling the app forward over what you're doing.
        if case .toast = behavior { style.insert(.nonactivatingPanel) }
        super.init(contentRect: .zero, styleMask: style, backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // The window server traces the shadow from the window's alpha, which
        // is why the glass sits in a rounded clip (see glass(around:)).
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        switch behavior {
        case .transient, .toast:
            level = .popUpMenu
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        case .floating:
            level = .floating
            isMovableByWindowBackground = true
        }
        stage.wantsLayer = true
        stage.layer?.masksToBounds = true
        content.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        stage.addSubview(content)
        surface = Self.glass(around: stage, cornerRadius: cornerRadius)
        surface.autoresizingMask = [.width, .height]
        let container = NSView()
        container.addSubview(surface)
        contentView = container
        // Follow the SwiftUI content's size, top edge held still so it grows
        // downward. Coalesced onto the next turn of the run loop: the size is
        // reported mid-layout, and resizing the window there would re-enter it.
        var pending = false
        measured.changed = { [weak self] in
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async {
                pending = false
                self?.fit(recenter: false)
            }
        }
    }

    private static func glass(around view: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = view
            // The glass's own backing layer is a plain rectangle, and the window
            // server shades whatever shape the window's alpha has: unclipped,
            // the shadow comes out square under the rounded corners.
            let clip = NSView()
            clip.wantsLayer = true
            clip.layer?.cornerRadius = cornerRadius
            clip.layer?.masksToBounds = true
            glass.autoresizingMask = [.width, .height]
            clip.addSubview(glass)
            return clip
        }
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.masksToBounds = true
        view.frame = material.bounds
        view.autoresizingMask = [.width, .height]
        material.addSubview(view)
        return material
    }

    override var canBecomeKey: Bool { true }

    /// Content fills the stage at rest; from here its autoresizing margins keep
    /// it top-centred while the frame animates.
    private func placeContent() {
        contentView?.layoutSubtreeIfNeeded()
        content.frame = stage.bounds
        // SwiftUI lays out at the new size now, not on its next pass: until
        // then its last frame sits in the resized view, offset by the change.
        content.layoutSubtreeIfNeeded()
        invalidateShadow()   // retrace it for the new size
    }

    // Opening unfurls from the top edge — from the menu bar icon, for the
    // panel: the glass starts narrow and header-high and opens down and out to
    // full size, 320 ms on the design's cubic-bezier(0.2, 0.8, 0.2, 1). Only
    // the frame moves; the content is already laid out and is revealed, not
    // squeezed. Reduce Motion gets a plain appearance.
    func present() {
        generation += 1          // strands any furl still running
        dismissing = false
        unfurling = false
        alphaValue = 1
        fit(recenter: !isVisible)
        let target = frame
        let toast: Bool
        if case .toast = behavior { toast = true } else { toast = false }
        if !toast { NSApp.activate(ignoringOtherApps: true) }
        let show = { toast ? self.orderFrontRegardless() : self.makeKeyAndOrderFront(nil) }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || target.isEmpty {
            show()
        } else {
            setFrame(furled(target), display: false)
            alphaValue = 0
            // The window server can't retrace a shadow every frame of a moving
            // window; it comes back, fitted to the glass, once the frame lands.
            hasShadow = false
            show()
            unfurling = true
            let generation = generation
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                animator().setFrame(target, display: true)
                animator().alphaValue = 1
            } completionHandler: { [weak self] in
                guard let self, self.generation == generation else { return }
                self.unfurling = false
                self.hasShadow = true
                self.fit(recenter: false)   // catch up with any resize held back mid-unfurl
            }
        }
        // A pointer surface: no control starts out keyboard-focused (and ringed).
        makeFirstResponder(nil)
        if case .transient = behavior, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    /// Where an unfurl starts and a furl ends: centred on the same top edge,
    /// 55% as wide and header-high.
    private func furled(_ full: NSRect) -> NSRect {
        let width = (full.width * 0.55).rounded(), height = min(44, full.height)
        return NSRect(x: full.midX - width / 2, y: full.maxY - height, width: width, height: height)
    }

    /// Transient and toast: furls back up and hides, ready to show again
    /// (160 ms). Floating: close for good.
    func dismiss() {
        guard isShowing else { return }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if case .floating = behavior {
            close()
            return
        }
        generation += 1
        let generation = generation
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            orderOut(nil)
            return
        }
        dismissing = true
        unfurling = true
        hasShadow = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(furled(frame), display: true)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.generation == generation else { return }
            self.orderOut(nil)
            self.dismissing = false
            self.unfurling = false
            self.alphaValue = 1
            self.hasShadow = true
        }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func resignKey() {
        super.resignKey()
        if case .transient = behavior { dismiss() }
    }

    private func fit(recenter: Bool) {
        guard !unfurling else { return }   // present()'s completion refits
        let size = measured.size == .zero ? content.intrinsicContentSize : measured.size
        guard size.width > 0, size.height > 0 else { return }
        switch behavior {
        case .transient(let button), .toast(let button):
            guard let buttonWindow = button.window else { return }
            let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            var x = anchor.midX - size.width / 2
            if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
                x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            }
            resize(to: NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height),
                   animated: !recenter)
        case .floating:
            if recenter || frame.size == .zero {
                setContentSize(size)
                center()
                placeContent()
            } else {
                let top = frame.maxY
                resize(to: NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height),
                       animated: true)
            }
        }
    }

    /// The SwiftUI content animates its own height (a card opening, 320 ms on
    /// the design curve), and the glass follows on the same clock. Nothing is
    /// resized mid-flight: an animated window frame is shown a beat before
    /// its content redraws, and a resizing glass view re-lays out its content
    /// on its own schedule — both read as the whole panel jumping. Instead the
    /// window, glass and content all take the larger of the two sizes at once,
    /// and a rounded mask, pinned top, animates between the two heights. A
    /// shrinking window drops to its size once the mask has.
    private func resize(to target: NSRect, animated: Bool) {
        guard animated, isVisible, frame.size != target.size, let clip = surface.layer,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setFrame(target, display: true)
            surface.frame = contentView?.bounds ?? .zero
            placeContent()
            return
        }
        generation += 1
        let generation = generation
        let from = frame.height, to = target.height
        let outer = to > from ? target : frame
        // Pinned to the top edge, which is y = 0 in a flipped layer.
        let flipped = clip.contentsAreFlipped()
        let path = { (h: CGFloat) in
            CGPath(roundedRect: CGRect(x: 0, y: flipped ? 0 : outer.height - h, width: outer.width, height: h),
                   cornerWidth: self.cornerRadius, cornerHeight: self.cornerRadius, transform: nil)
        }
        // Resize and redraw land as one, or the window server shows the old
        // contents in the new frame for a beat.
        disableScreenUpdatesUntilFlush()
        setFrame(outer, display: false)
        surface.frame = contentView?.bounds ?? .zero
        placeContent()
        let mask = clip.mask as? CAShapeLayer ?? CAShapeLayer()
        mask.frame = clip.bounds
        clip.mask = mask
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == generation else { return }
            self.disableScreenUpdatesUntilFlush()
            self.setFrame(target, display: false)
            self.surface.frame = self.contentView?.bounds ?? .zero
            clip.mask = nil
            self.placeContent()
            self.display()
        }
        let reveal = CABasicAnimation(keyPath: "path")
        reveal.fromValue = (mask.presentation()?.path ?? mask.path) ?? path(from)
        reveal.toValue = path(to)
        reveal.duration = 0.32
        reveal.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        mask.path = path(to)
        mask.add(reveal, forKey: "reveal")
        CATransaction.commit()
        display()
        // The shadow is traced from the window's alpha, so it's retraced
        // every frame the mask changes shape.
        let shadow = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.invalidateShadow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { shadow.invalidate() }
    }
}

/// The content's size as SwiftUI measures it. Neither AppKit channel works
/// for this: a hosting controller's preferredContentSize is computed only when
/// asked, and a hosting view doesn't invalidate its intrinsic size when state
/// changes inside it — so a window following either never grew.
private final class MeasuredSize {
    private(set) var size: CGSize = .zero
    var changed: (() -> Void)?

    func update(_ new: CGSize) {
        guard new != size else { return }
        size = new
        changed?()
    }
}

/// Lays the root out at its ideal height, pinned to the top, and reports that
/// size on every SwiftUI update.
private struct Measured<Root: View>: View {
    let root: Root
    let report: (CGSize) -> Void

    var body: some View {
        root
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: report)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}
