import Foundation

@main struct FleetSettingsLoaderTests {
    static func main() async {
        let started = Date()
        let values = await FleetSettingsLoader.load { command in
            Thread.sleep(forTimeInterval: 0.25)
            return command.joined(separator: " ")
        }
        let elapsed = Date().timeIntervalSince(started)

        precondition(values == FleetSettingsLoader.commands.map { $0.joined(separator: " ") },
                     "loader changed command result order: \(values)")
        precondition(elapsed < 0.75,
                     "five 250ms commands took \(elapsed)s; they appear to be serialized")
        print(String(format: "Fleet settings responsiveness test passed in %.3fs", elapsed))
    }
}
