import AppKit
import Foundation

final class FakeSetupHost: SetupHost {
    private let lock = NSLock()
    private var credentials: [String: Bool] = ["codex": false, "claude": false]
    var session: NativeAuthSession?
    var started: [String] = []
    var startedProfiles: [String] = []
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
    func setupStartLogin(profile: String, vendor: String) -> NativeAuthSession? {
        started.append(vendor)
        startedProfiles.append(profile)
        return session
    }
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
            _ = RunLoop.main.run(mode: .default, before: deadline)
        }
        precondition(condition(), "Setup did not advance")
    }

    static func main() {
        reopenSignIn(isNew: true)
        reopenSignIn(isNew: false)
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
        let failedHost = FakeSetupHost()
        failedHost.session = NativeAuthSession(executable: "/bin/sh", arguments: [], environment: [:])
        let failed = ProfileSetup(profile: "Work", isNew: false, snapshot: snapshot,
                                  resume: ["codex"], host: failedHost)
        failed.beginSignIn()
        waitUntil { failedHost.started == ["codex"] }
        failedHost.session?.finish(1)
        precondition(failed.model.states["codex"] == .failed)
        precondition(failedHost.pending == ["codex"])
        failed.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        print("Profile setup tests passed")
    }

    static func reopenSignIn(isNew: Bool) {
        let snapshot = Snapshot.parse("V\tclaude\t1\tnone\toauth\tClaude\nV\tcodex\t1\tnone\toauth\tCodex\n")
        let host = FakeSetupHost()
        let original = NativeAuthSession(executable: "/bin/sh", arguments: [], environment: [:])
        host.session = original
        let setup = ProfileSetup(profile: "Work", isNew: isNew, snapshot: snapshot,
                                 resume: isNew ? nil : ["claude", "codex"], host: host)
        if isNew { setup.create() } else { setup.beginSignIn() }
        waitUntil { host.started == ["claude"] }
        let staleCompletion = original.onFinish
        let reopened = NativeAuthSession(executable: "/bin/sh", arguments: [], environment: [:])
        host.session = reopened
        setup.reopenLogin("claude")
        precondition(!original.isRunning, "Reopen must cancel the stalled login")
        precondition(setup.model.authSession === reopened && reopened.isRunning)
        precondition(host.started == ["claude", "claude"])
        precondition(host.startedProfiles == ["Work", "Work"], "Reopen must preserve the account binding")
        precondition(host.pending == ["claude", "codex"])
        staleCompletion?(1)
        precondition(setup.model.states["claude"] == .signingIn, "Old completion must not fail the new login")
        precondition(setup.model.states["codex"] == .waiting)
        reopened.finish(1)
        precondition(setup.model.states["claude"] == .failed)
        let retry = NativeAuthSession(executable: "/bin/sh", arguments: [], environment: [:])
        host.session = retry
        setup.reopenLogin("claude")
        precondition(setup.model.authSession === retry)
        precondition(host.started == ["claude", "claude", "claude"])
        host.authenticate("claude")
        host.session = NativeAuthSession(executable: "/bin/sh", arguments: [], environment: [:])
        retry.finish(0)
        waitUntil { host.started.last == "codex" }
        precondition(host.pending == ["codex"])
        setup.reopenLogin("claude")
        precondition(host.started.count == 4, "Completed providers must not restart")
        host.authenticate("codex")
        host.session?.finish(0)
        waitUntil { setup.model.step == .ready }
        precondition(host.pending == nil)
        setup.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        setup.reopenLogin("codex")
        precondition(host.started.count == 4)
    }
}
