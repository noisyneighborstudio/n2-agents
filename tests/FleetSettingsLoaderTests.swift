import Foundation

@main struct FleetSettingsLoaderTests {
    @MainActor static func main() async {
        let commands = FleetSettingsLoader.commands
        let started = AsyncStream<Int>.makeStream()
        let finished = AsyncStream<Int>.makeStream()
        let releases = commands.map { _ in DispatchSemaphore(value: 0) }
        // Only a stuck-test guard, never a performance assertion.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            preconditionFailure("settings concurrency proof did not finish")
        }
        let loading = Task {
            await FleetSettingsLoader.load { command in
                precondition(!Thread.isMainThread, "settings read blocked the main thread")
                let index = commands.firstIndex(of: command)!
                started.continuation.yield(index)
                precondition(releases[index].wait(timeout: .now() + 20) == .success,
                             "reads did not all start before release")
                finished.continuation.yield(index)
                return command.joined(separator: " ")
            }
        }
        var seen = Set<Int>()
        for await index in started.stream {
            precondition(seen.insert(index).inserted, "duplicate command")
            if seen.count == commands.count { break }
        }
        // The main actor remains runnable while every blocking read is held.
        // Release reads in reverse order to exercise indexed result collection.
        var completions = finished.stream.makeAsyncIterator()
        for index in commands.indices.reversed() {
            releases[index].signal()
            let completed = await completions.next()
            precondition(completed == index, "unexpected completion receipt")
        }
        let values = await loading.value
        precondition(values == commands.map { $0.joined(separator: " ") },
                     "loader changed command result order: \(values)")
        started.continuation.finish(); finished.continuation.finish()
        // The exact `agents fleet sync review` output (scripts/test-sync-review.sh).
        precondition(FleetSettingsLoader.heldProfiles("nothing to review").isEmpty,
                     "the empty-review sentence is not a profile")
        precondition(FleetSettingsLoader.heldProfiles("Client\nShared") == ["Client", "Shared"],
                     "held profiles are listed in order")
        print("Fleet settings concurrent reads, main-actor responsiveness, result order and held profiles passed")
    }
}
