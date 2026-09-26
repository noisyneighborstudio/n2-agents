import Foundation

// Keep blocking subprocess work outside View. SwiftUI infers @MainActor on
// View members, which caused even the detached refresh to hop back to the
// UI thread before reading a pipe from a slow peer probe.
enum FleetSettingsLoader {
    private static let commandPATH = ShellPath.fromLoginShell() ?? "/usr/bin:/bin:/usr/sbin:/sbin"

    static let commands = [
        ["sync", "categories"],
        ["sync", "auth", "list"],
        ["peers"],
        ["sync", "service", "status"],
        ["sync", "conflicts"],
    ]

    /// Each CLI invocation blocks while its process runs. Give every command
    /// its own detached task so an unreachable peer does not serialize the
    /// otherwise local settings reads behind it.
    static func load(run: @escaping @Sendable ([String]) -> String) async -> [String] {
        await withTaskGroup(of: (Int, String).self, returning: [String].self) { group in
            for (index, command) in commands.enumerated() {
                group.addTask {
                    (index, await Task.detached { run(command) }.value)
                }
            }

            var values = Array(repeating: "", count: commands.count)
            for await (index, value) in group {
                values[index] = value
            }
            return values
        }
    }

    /// Synchronous by design. Call only from a detached task, never the UI.
    static func run(_ args: [String]) -> String {
        precondition(!Thread.isMainThread, "Fleet CLI must not block the main thread")
        guard let resources = Bundle.main.resourcePath else { return "App resources unavailable" }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [resources + "/agents", "fleet"] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = commandPATH
        process.environment = env
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return error.localizedDescription }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
