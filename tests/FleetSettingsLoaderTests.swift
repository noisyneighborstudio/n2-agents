import Foundation

@main struct FleetSettingsLoaderTests {
    @MainActor static func main() async {
        let commands = FleetSettingsLoader.commands
        let started = AsyncStream<Int>.makeStream()
        let delivered = AsyncStream<(Int, String)>.makeStream()
        let releases = commands.map { _ in DispatchSemaphore(value: 0) }
        // Only a stuck-test guard, never a performance assertion.
        DispatchQueue.global().asyncAfter(deadline: .now() + 40) {
            preconditionFailure("settings loading proof did not finish")
        }
        let loading = Task {
            await FleetSettingsLoader.load(run: { command in
                precondition(!Thread.isMainThread, "settings read blocked the main thread")
                let index = commands.firstIndex(of: command)!
                started.continuation.yield(index)
                precondition(releases[index].wait(timeout: .now() + 20) == .success,
                             "reads did not all start before release")
                return command.joined(separator: " ")
            }) { index, value in
                delivered.continuation.yield((index, value))
            }
        }
        var seen = Set<Int>()
        for await index in started.stream {
            precondition(seen.insert(index).inserted, "duplicate command")
            if seen.count == commands.count { break }
        }
        // Every read is blocked, and the main actor is still free to run this.
        // Release one at a time: each result must reach the view while every
        // earlier read is still held, so a slow read never gates the others.
        var deliveries = delivered.stream.makeAsyncIterator()
        for index in commands.indices.reversed() {
            releases[index].signal()
            let result = await deliveries.next()
            precondition(result?.0 == index && result?.1 == commands[index].joined(separator: " "),
                         "a released read was not delivered while others were held")
        }
        await loading.value
        started.continuation.finish(); delivered.continuation.finish()

        // A read that never answers reports a timeout instead of holding its section.
        let agents = URL(fileURLWithPath: Bundle.main.resourcePath!).appendingPathComponent("agents")
        try! "#!/bin/sh\nexec /bin/sleep 30\n".write(to: agents, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agents.path)
        FleetSettingsLoader.timeout = 1
        let hung = await Task.detached { FleetSettingsLoader.command(["peers"]) }.value
        precondition(hung.output == FleetSettingsLoader.timedOut, "a hung read did not time out: \(hung)")

        // The exact `agents fleet sync review` output (scripts/test-sync-review.sh).
        precondition(FleetSettingsLoader.heldProfiles("nothing to review").isEmpty,
                     "the empty-review sentence is not a profile")
        precondition(FleetSettingsLoader.heldProfiles("Client\nShared") == ["Client", "Shared"],
                     "held profiles are listed in order")
        // `agents fleet peers` before `agents fleet init`.
        precondition(!FleetSettingsLoader.hasIdentity("agents: no fleet identity yet (run: agents fleet init)"),
                     "a Mac outside a fleet shows the create-identity hint")
        precondition(FleetSettingsLoader.hasIdentity("SHA256:abc\talpha\tself\tapproved\tself"),
                     "an initialized fleet shows its controls")
        print("Fleet settings: reads deliver independently, a hung read times out, held profiles and identity parse")
    }
}
