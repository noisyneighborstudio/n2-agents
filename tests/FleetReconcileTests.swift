import Foundation

final class AppDelegate {
    let cliPath = ProcessInfo.processInfo.environment["N2_TEST_CLI"]!
    static let scriptEnvironment = ProcessInfo.processInfo.environment
    var events: [String] = []
    let failure = ProcessInfo.processInfo.environment["N2_TEST_RC"] == "1"

    func alert(_ title: String, _ message: String) {
        precondition(Thread.isMainThread)
        precondition(title == "Couldn't reconcile tasks" && message == "fixture refusal")
        events.append("error")
    }

    func refreshFleet() {
        precondition(Thread.isMainThread)
        events.append("refresh")
        precondition(events.contains("main-thread-receipt"))
        precondition(events.filter { $0 == "refresh" }.count == 1)
        precondition(events.contains("error") == failure)
        if failure { precondition(events.firstIndex(of: "error")! < events.firstIndex(of: "refresh")!) }
        print(events.joined(separator: ","))
        exit(0)
    }

    // PRODUCTION_METHODS
}

@main struct Proof {
    static func main() {
        let app = AppDelegate()
        let directory = ProcessInfo.processInfo.environment["N2_TEST_DIR"]!
        DispatchQueue.global().async {
            let started = FileHandle(forReadingAtPath: directory + "/started")!
            precondition(started.readDataToEndOfFile() == Data("started\n".utf8))
            started.closeFile()
            DispatchQueue.main.async {
                app.events.append("main-thread-receipt")
                let release = FileHandle(forWritingAtPath: directory + "/release")!
                release.write(Data("release\n".utf8))
                release.closeFile()
            }
        }
        DispatchQueue.main.async { app.fleetReconcileTasks() }
        RunLoop.main.run()
    }
}
