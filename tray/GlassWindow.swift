import AppKit

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
        /// The setup window: floats above everything, including the terminal
        /// that takes focus mid-sign-in, until it is closed.
        case floating
    }

    private let content: NSViewController
    private let behavior: Behavior
    private var sizeObservation: NSKeyValueObservation?
    private var clickMonitor: Any?
    /// Holds the content at its full size, pinned top-centre and clipped, so
    /// the window can unfurl around it without the layout moving.
    private let stage = NSView()
    private var unfurling = false
    private var dismissing = false
    /// Bumped by every present/dismiss, so a stale animation's completion
    /// can't hide a panel that was reopened mid-furl.
    private var generation = 0

    /// Shown, and not on its way out.
    var isShowing: Bool { isVisible && !dismissing }

    init(content: NSViewController, behavior: Behavior, cornerRadius: CGFloat = 16) {
        self.content = content
        self.behavior = behavior
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // No window shadow: the glass is composited by the system, so the
        // window server sees a clear rectangle and shades it as one — a grey
        // square outline around the rounded corners.
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        switch behavior {
        case .transient:
            level = .popUpMenu
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        case .floating:
            level = .floating
            isMovableByWindowBackground = true
        }
        stage.wantsLayer = true
        stage.layer?.masksToBounds = true
        content.view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        stage.addSubview(content.view)
        contentView = Self.glass(around: stage, cornerRadius: cornerRadius)
        // SwiftUI reports its size through preferredContentSize; follow it
        // with the top edge held still, so content grows downward.
        sizeObservation = content.observe(\.preferredContentSize) { [weak self] _, _ in
            DispatchQueue.main.async { self?.fit(recenter: false) }
        }
    }

    private static func glass(around view: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = view
            return glass
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
        content.view.frame = stage.bounds
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
        NSApp.activate(ignoringOtherApps: true)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || target.isEmpty {
            makeKeyAndOrderFront(nil)
        } else {
            setFrame(furled(target), display: false)
            alphaValue = 0
            makeKeyAndOrderFront(nil)
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

    /// Transient: furls back up and hides, ready to show again (160 ms).
    /// Floating: close for good.
    func dismiss() {
        guard isShowing else { return }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        guard case .transient = behavior else {
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
        }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func resignKey() {
        super.resignKey()
        if case .transient = behavior { dismiss() }
    }

    private func fit(recenter: Bool) {
        guard !unfurling else { return }   // present()'s completion refits
        let preferred = content.preferredContentSize
        let size = preferred == .zero ? content.view.fittingSize : preferred
        guard size.width > 0, size.height > 0 else { return }
        defer { placeContent() }
        switch behavior {
        case .transient(let button):
            guard let buttonWindow = button.window else { return }
            let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            var x = anchor.midX - size.width / 2
            if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
                x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            }
            setFrame(NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height),
                     display: true)
        case .floating:
            if recenter || frame.size == .zero {
                setContentSize(size)
                center()
            } else {
                let top = frame.maxY
                setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height),
                         display: true, animate: false)
            }
        }
    }
}
