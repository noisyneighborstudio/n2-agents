import AppKit
import QuartzCore

@main struct NativeSignInPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let plan = SignInPlan(arguments: [], owner: "SHA256:" + String(repeating: "a", count: 43))
        let alert = plan.alert(profile: "Work", label: "Codex")
        alert.layout(); alert.window.animationBehavior = .none
        var reported = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: alert.window, queue: .main) { _ in
            guard !reported else { return }; reported = true
            CATransaction.flush()
            print("READY \(alert.window.windowNumber)"); fflush(stdout)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        alert.runModal()
    }
}
