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
    var fleet: FleetData? { didSet { precondition(Thread.isMainThread); publications += 1 } }
}
final class AppDelegate {
    let model = ReadModel()
    var mode = "first-failure"
    var announcements = 0
    var alerts = 0
    let peer = "peer-id\tPeer\tssh\tapproved\tonline\n"
    func runCLI(_ args: [String]) -> (status: Int32, output: String) {
        let command = args.dropFirst().joined(separator: " ")
        if command == mode || (mode == "first-failure" && command == "status --no-probe") { return (1, "") }
        switch command {
        case "status --no-probe":
            if mode == "malformed-status" { return (0, "invalid") }
            if mode == "uninitialized" { return (0, "fleet\tuninitialized\n") }
            return (0, "self\tFixture\tself-id\n" + peer)
        case "peers": return (0, peer)
        case "task list":
            if mode == "malformed-task" { return (0, "invalid\n") }
            if mode == "empty" { return (0, "") }
            return (0, "task-1\t\(mode == "recovery" ? "completed" : "running")\tcodex\t0\tWork\tPeer\tdispatcher\n")
        default: return (0, "")
        }
    }
    func announce(_ notices: [FleetNotice]) { announcements += 1 }
    func updateFleetAttention(_ data: FleetData) {}
    func alert(_ title: String, _ body: String) { alerts += 1 }
    func dismissPanel() { fatalError("stale dispatch opened a form") }
    // PRODUCTION_METHODS
}
@main struct FleetReadTests {
    static let app = AppDelegate()
    static let modes = ["first-failure", "good", "status --no-probe", "peers", "sync status",
                        "sync conflicts", "sync except list", "tools list", "tools status",
                        "tools deferred", "task list", "task notices", "malformed-status",
                        "malformed-task", "recovery", "empty", "uninitialized"]
    static var index = 0
    static func step() {
        app.mode = modes[index]
        let previous = app.model.fleet
        let announcements = app.announcements
        app.refreshFleet()
        DispatchQueue.group.notify(queue: .main) {
            precondition(app.model.publications == index + 1, "every failed read must publish its failure")
            let value = app.model.fleet!
            if ["good", "recovery", "empty", "uninitialized"].contains(app.mode) {
                precondition(value.readError == nil && value.observedAt != nil)
                precondition(app.announcements == announcements + 1)
                if app.mode == "recovery" { precondition(value.tasks.first?.state == .done) }
                if app.mode == "empty" { precondition(value.tasks.isEmpty && value.initialized) }
                if app.mode == "uninitialized" { precondition(!value.initialized) }
                if value.initialized { precondition(value.destinations.count == 1) }
            } else {
                precondition(value.readError != nil && value.destinations.isEmpty)
                precondition(value.tasks == (previous?.tasks ?? []))
                precondition(value.peers == (previous?.peers ?? []))
                precondition(value.observedAt == previous?.observedAt)
                precondition(app.announcements == announcements, "failed reads must not announce")
                let alerts = app.alerts
                app.fleetDispatch()
                precondition(app.alerts == alerts + 1, "stale dispatch must explain refusal")
                app.fleetRetry(task: "task-1")
                precondition(app.alerts == alerts + 2, "stale retry must explain refusal")
            }
            index += 1
            if index < modes.count { step() }
            else { print("Fleet read: 17 failure, recovery, empty-feed and dispatch-admission cases passed"); exit(0) }
        }
    }
    static func main() { step(); RunLoop.main.run() }
}
