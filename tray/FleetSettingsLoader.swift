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
        ["sync", "review"],
    ]

    /// `sync review` lists one held profile per line, or a sentence when none
    /// are held. Profile names are letters and digits only, so the sentence
    /// never reads as a profile.
    static func heldProfiles(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init)
            .filter { $0.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil }
    }

    /// Each CLI invocation blocks while its process runs. Give every command
    /// its own dispatch work item so an unreachable peer does not serialize the
    /// otherwise local settings reads behind it.
    static func load(run: @escaping @Sendable ([String]) -> String) async -> [String] {
        await withTaskGroup(of: (Int, String).self, returning: [String].self) { group in
            for (index, command) in commands.enumerated() {
                group.addTask {
                    let value = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: run(command))
                        }
                    }
                    return (index, value)
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
    static func run(_ args: [String]) -> String { command(args).output }

    static func command(_ args: [String]) -> (status: Int32, output: String) {
        precondition(!Thread.isMainThread, "Fleet CLI must not block the main thread")
        guard let resources = Bundle.main.resourcePath else { return (1, "App resources unavailable") }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [resources + "/agents", "fleet"] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = commandPATH
        process.environment = env
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return (1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
