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

    /// Every fleet verb refuses before `agents fleet init`, with this reason.
    static func hasIdentity(_ output: String) -> Bool {
        !output.contains("no fleet identity yet")
    }

    /// `sync review` lists one held profile per line, or a sentence when none
    /// are held. Profile names are letters and digits only, so the sentence
    /// never reads as a profile.
    static func heldProfiles(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init)
            .filter { $0.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil }
    }

    /// Each CLI invocation blocks while its process runs, so every command gets
    /// its own dispatch work item, and each result is delivered the moment it
    /// arrives: one slow read (a peer probe) never holds back the others.
    static func load(run: @escaping @Sendable ([String]) -> String,
                     each: @escaping @MainActor @Sendable (Int, String) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, command) in commands.enumerated() {
                group.addTask {
                    let value = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: run(command))
                        }
                    }
                    await each(index, value)
                }
            }
        }
    }

    /// A read that hangs reports this instead of holding its section forever.
    nonisolated(unsafe) static var timeout: TimeInterval = 20
    static let timedOut = "Timed out"

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
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return (1, error.localizedDescription) }
        let output = OutputBox()
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return (-1, timedOut)
        }
        drained.wait()
        return (process.terminationStatus, String(data: output.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

private final class OutputBox: @unchecked Sendable { var data = Data() }
