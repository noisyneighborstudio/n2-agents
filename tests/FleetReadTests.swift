import Foundation
import Dispatch

// Track real queue blocks, including nested publication, before observing state.
struct DispatchQueue {
    static let group = DispatchGroup()
    let queue: Dispatch.DispatchQueue
    static func global(qos: DispatchQoS.QoSClass) -> Self { Self(queue: .global(qos: qos)) }
    static var main: Self { Self(queue: .main) }
    func async(execute body: @escaping () -> Void) {
        Self.group.enter()
        queue.async { body(); Self.group.leave() }
    }
}
final class ReadModel {
    var publications = 0
    var workDraft = WorkDraft()
    var onPublish: ((FleetData) -> Void)?
    var fleet: FleetData? { didSet { precondition(Thread.isMainThread); publications += 1; onPublish?(fleet!) } }
}
final class AppDelegate {
    var fleetReadID: UUID?
    let model = ReadModel()
    var mode = "first-failure"
    var announcements = 0
    var alerts = 0
    let tasksHeld = DispatchSemaphore(value: 0)
    let peer = "peer-id\tPeer\tssh\tapproved\tonline\n"
    func runCLI(_ args: [String], timeout: TimeInterval? = nil) -> (status: Int32, output: String) {
        precondition(timeout == 20, "every fleet read is bounded")
        let command = args.dropFirst().joined(separator: " ")
        if command == mode || (mode == "first-failure" && command == "status --no-probe") { return (1, "") }
        switch command {
        case "status --no-probe":
            if mode == "malformed-status" { return (0, "invalid") }
            if mode == "uninitialized" { return (0, "fleet\tuninitialized\n") }
            return (0, "self\tFixture\tself-id\n" + peer)
        case "peers": return (0, peer)
        case "task list":
            if mode == "held-tasks" {
                precondition(tasksHeld.wait(timeout: .now() + 10) == .success, "sections waited on the held task read")
            }
            if mode == "malformed-task" { return (0, "invalid\n") }
            if mode == "empty" { return (0, "") }
            return (0, "task-1\t\(mode == "recovery" ? "completed" : "running")\tcodex\t0\tWork\tPeer\tdispatcher\n")
        default: return (0, "")
        }
    }
    func announce(_ notices: [FleetNotice]) { announcements += 1 }
    func updateFleetAttention(_ data: FleetData) {}
    func alert(_ title: String, _ body: String) { alerts += 1 }
    func dismissPanel() { fatalError("refused work opened a form") }
    func returnToPanel() { fatalError("refused work reopened the panel") }
    // PRODUCTION_METHODS
}
@main struct FleetReadTests {
    static let app = AppDelegate()
    // A failing command marks only the section it feeds.
    static let failing: [String: FleetRead] = [
        "peers": .machines, "sync status": .sync, "sync conflicts": .conflicts,
        "sync except list": .exceptions, "tools list": .tools, "tools status": .tools,
        "tools deferred": .tools, "task list": .tasks, "malformed-task": .tasks, "task notices": .activity]
    static let modes = ["first-failure", "good", "status --no-probe", "malformed-status", "peers",
                        "sync status", "sync conflicts", "sync except list", "tools list", "tools status",
                        "tools deferred", "task list", "task notices", "malformed-task", "held-tasks",
                        "recovery", "empty", "uninitialized"]
    static var index = 0
    static let spec = FleetDispatchSpec(task: "true", prompt: false, workspace: "", contextFile: "", requirements: "",
                                        machine: nil, agent: nil)
    static var sawOthersWhileTasksHeld = false
    static func step() {
        app.mode = modes[index]
        let previous = app.model.fleet
        let publications = app.model.publications
        let announcements = app.announcements
        let alerts = app.alerts
        app.model.onPublish = { fleet in
            // The UI rule: every other section renders while one read is held.
            if app.mode == "held-tasks" && fleet.loading == [.tasks] && !sawOthersWhileTasksHeld {
                sawOthersWhileTasksHeld = true
                app.tasksHeld.signal()
            }
        }
        app.refreshFleet()
        DispatchQueue.group.notify(queue: .main) {
            let value = app.model.fleet!
            switch app.mode {
            case "first-failure", "status --no-probe", "malformed-status":
                precondition(app.model.publications == publications + 1, "a failed status read publishes once")
                precondition(value.readError != nil && value.destinations.isEmpty)
                precondition(value.tasks == (previous?.tasks ?? []) && value.peers == (previous?.peers ?? []))
                precondition(value.observedAt == previous?.observedAt)
                precondition(app.announcements == announcements, "failed reads must not announce")
                app.model.workDraft = WorkDraft()
                app.fleetDispatch(Self.spec)
                app.fleetRetry(task: "task-1")
                precondition(app.alerts == alerts + 1, "a retry without current fleet state must explain refusal")
                if case .failed = app.model.workDraft.state {} else {
                    preconditionFailure("work without current fleet state must explain refusal on its page")
                }
            case "uninitialized":
                precondition(app.model.publications == publications + 1 && !value.initialized && value.readError == nil)
            default:
                precondition(app.model.publications == publications + 1 + FleetRead.allCases.count,
                             "status and each section publish once")
                precondition(value.readError == nil && value.observedAt != nil && value.loading.isEmpty)
                let failed = failing[app.mode]
                precondition(value.unavailable == (failed.map { [$0] } ?? []), "only the failed section is unavailable")
                precondition(app.announcements == announcements + (failed == .activity ? 0 : 1))
                if failed == .machines {
                    precondition(value.destinations.isEmpty && value.peers == previous!.peers)
                    app.model.workDraft = WorkDraft()
                    app.fleetDispatch(Self.spec)
                    if case .failed = app.model.workDraft.state {} else {
                        preconditionFailure("dispatch without a current machine list must explain refusal on its page")
                    }
                } else {
                    precondition(value.destinations.count == 1)
                }
                if failed == .tasks {
                    precondition(value.tasks == previous!.tasks && value.state(.tasks)?.contains("last values") == true)
                    app.fleetRetry(task: "task-1")
                    precondition(app.alerts == alerts + 1, "retry without a current task list must explain refusal")
                } else {
                    precondition(value.tasksCurrent)
                }
                if app.mode == "held-tasks" { precondition(sawOthersWhileTasksHeld) }
                if app.mode == "recovery" { precondition(value.tasks.first?.state == .done) }
                if app.mode == "empty" { precondition(value.tasks.isEmpty && value.initialized) }
            }
            index += 1
            if index < modes.count { step() }
            else { print("Fleet read: \(modes.count) status, per-section failure, held-read, recovery and admission cases passed"); exit(0) }
        }
    }
    static func main() { step(); RunLoop.main.run() }
}
