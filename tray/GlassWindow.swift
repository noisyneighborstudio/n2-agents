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

    init(content: NSViewController, behavior: Behavior, cornerRadius: CGFloat = 16) {
        self.content = content
        self.behavior = behavior
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
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
        contentView = Self.glass(around: content.view, cornerRadius: cornerRadius)
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

    func present() {
        fit(recenter: true)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        // A pointer surface: no control starts out keyboard-focused (and ringed).
        makeFirstResponder(nil)
        if case .transient = behavior, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    /// Transient: hide, ready to show again. Floating: close for good.
    func dismiss() {
        guard isVisible else { return }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if case .transient = behavior { orderOut(nil) } else { close() }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func resignKey() {
        super.resignKey()
        if case .transient = behavior { dismiss() }
    }

    private func fit(recenter: Bool) {
        let preferred = content.preferredContentSize
        let size = preferred == .zero ? content.view.fittingSize : preferred
        guard size.width > 0, size.height > 0 else { return }
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
