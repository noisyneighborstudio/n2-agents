import AppKit
import Foundation

final class FakeSetupHost: SetupHost {
    private let lock = NSLock()
    private var credentials: [String: Bool] = ["codex": false, "claude": false]
    var started: [String] = []
    var pending: [String]?
    func authenticate(_ vendor: String) {
        lock.lock(); defer { lock.unlock() }
        credentials[vendor] = true
    }
    func setupCreate(profile: String, vendors: [String]) -> String? { nil }
    func setupAuthed(profile: String) -> [String: Bool]? {
        lock.lock(); defer { lock.unlock() }
        return credentials
    }
    func setupStartLogin(profile: String, vendor: String) { started.append(vendor) }
    func setupCopyLoginCommand(profile: String, vendor: String) {}
    func setupPending(profile: String, labs: [String]?) { pending = labs }
    func setupOpen(profile: String, vendor: String) {}
    func setupMakeActive(profile: String) {}
    var setupTerminalName: String { "Test terminal" }
}

@main
struct ProfileSetupTests {
    static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(condition(), "Setup did not advance")
    }

    static func main() {
        let snapshot = Snapshot.parse("P\tWork\t0\tcodex:ok,claude:ok\n")
        let host = FakeSetupHost()
        let setup = ProfileSetup(profile: "Work", isNew: false, snapshot: snapshot,
                                 resume: ["codex", "claude"], host: host)
        setup.beginSignIn()
        waitUntil { host.started == ["codex"] }
        precondition(host.pending == ["codex", "claude"])
        host.authenticate("codex")
        setup.loginFinished(vendor: "codex")
        waitUntil { host.started == ["codex", "claude"] }
        precondition(host.pending == ["claude"])
        host.authenticate("claude")
        setup.loginFinished(vendor: "claude")
        waitUntil { setup.model.step == .ready }
        precondition(host.pending == nil)
        precondition(setup.model.finishedLabs == ["codex", "claude"])

        // Closing setup during an in-flight read must not launch another login.
        let cancelledHost = FakeSetupHost()
        let cancelled = ProfileSetup(profile: "Work", isNew: false, snapshot: snapshot,
                                     resume: ["codex"], host: cancelledHost)
        cancelled.beginSignIn()
        cancelled.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(cancelledHost.started.isEmpty)
        precondition(cancelledHost.pending == ["codex"])
        print("Profile setup tests passed")
    }
}
