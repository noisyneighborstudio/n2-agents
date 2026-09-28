import AppKit
import SwiftUI

// Only the surrounding app model/actions are stubbed. The Settings view,
// Fleet view, GlassWindow, PATH lookup and subprocess code are production code.
final class PanelModel: ObservableObject {
    struct Data { var terminals = ["Terminal"] }
    @Published var data: Data? = Data()
}

final class PanelActions {
    var panelShortcut: String? { nil }
    func closeSettings() {}
    func setPreferredTerminal(_ value: String) {}
    func installCLI() -> String { "test" }
    func setUpdateChannel(_ value: UpdateChannel) {}
    func setPanelShortcut() {}
    func checkForUpdates() {}
}

@main struct FleetSettingsUITests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Probe()
        app.delegate = delegate
        app.run()
    }
}

@MainActor final class Probe: NSObject, NSApplicationDelegate {
    private var window: GlassWindow!
    private var timer: Timer?
    private var start = ProcessInfo.processInfo.systemUptime
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var maxGap = 0.0
    private var pendingTicks = 0
    private var scrollEvents = 0
    private var firstScroll: Double?
    private var firstPosition: CGFloat?
    private var scrollDistance: CGFloat = 0
    private let directory = ProcessInfo.processInfo.environment["N2_SETTINGS_TEST_DIR"]!

    func applicationDidFinishLaunching(_ notification: Notification) {
        start = ProcessInfo.processInfo.systemUptime
        lastTick = start
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        window = GlassWindow(rootView: SettingsWindowView(model: PanelModel(), actions: PanelActions()),
                             behavior: .floating)
        window.title = "N2 Settings responsiveness fixture"
        window.present()
        print(String(format: "present returned at %.3fs", elapsed))
        fflush(stdout)
    }

    private var elapsed: Double { ProcessInfo.processInfo.systemUptime - start }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        maxGap = max(maxGap, now - lastTick)
        lastTick = now
        let files = FileManager.default
        let pending = files.fileExists(atPath: directory + "/peers-started") &&
            !files.fileExists(atPath: directory + "/peers-finished")

        if let content = window.contentView, let scroll = scrollView(in: content), elapsed > 0.6 {
            let position = scroll.contentView.bounds.origin.y
            if let firstPosition {
                if pending {
                    scrollDistance = max(scrollDistance, abs(position - firstPosition))
                    if scrollDistance > 20, firstScroll == nil { firstScroll = elapsed }
                }
            } else { firstPosition = position }

            if pending {
                pendingTicks += 1
                // Deliver a real wheel event through the hit-tested view's
                // responder chain. Never assign the clip view's scroll offset.
                let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
                let screenPoint = window.convertPoint(toScreen: point)
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                    wheel1: -32, wheel2: 0, wheel3: 0)!
                event.location = CGPoint(x: screenPoint.x,
                                         y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y)
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                           value: Int64(window.windowNumber))
                let target = content.hitTest(content.convert(point, from: nil))
                target?.scrollWheel(with: NSEvent(cgEvent: event)!)
                scrollEvents += 1
            }
        }

        // Allow startup overhead in addition to the synthetic shell/peer delays.
        // Retain a finite deadline so incomplete commands still fail the test.
        let peerFinished = files.fileExists(atPath: directory + "/peers-finished")
        if (elapsed >= 7 && peerFinished) || elapsed >= 15 {
            timer?.invalidate()
            let commands = (try? String(contentsOfFile: directory + "/commands"))?
                .split(separator: "\n").map(String.init) ?? []
            let expected = ["fleet sync categories", "fleet sync auth list", "fleet peers",
                            "fleet sync service status", "fleet sync conflicts"]
            let complete = commands.sorted() == expected.sorted() &&
                files.fileExists(atPath: directory + "/peers-finished")
            let passed = maxGap < 0.5 && scrollDistance > 100 && pendingTicks >= 10 && complete
            let loginCalls = (try? String(contentsOfFile: directory + "/login-calls"))?
                .split(separator: "\n").count ?? 0
            print(String(format: "max_main_runloop_gap=%.3fs pending_ticks=%d wheel_events=%d pending_scroll_distance=%.1f first_scroll=%.3fs commands=%d login_calls=%d result=%@",
                         maxGap, pendingTicks, scrollEvents, scrollDistance, firstScroll ?? -1,
                         commands.count, loginCalls,
                         passed ? "PASS" : "FAIL"))
            fflush(stdout)
            exit(passed ? 0 : 1)
        }
    }
}
