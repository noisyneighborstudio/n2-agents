import AppKit

@main struct NativeSessionTransferTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "--send" {
            let args = CommandLine.arguments; var code: Int32 = 1
            await SessionTransferCoordinator().perform(thread: args[3], vendor: "codex", run: {
                SignInPlan.run(cli: args[2], environment: ProcessInfo.processInfo.environment, args: $0)
            }, choose: { peers in peers.first(where: { $0.id == args[4] }).map { ($0, args[5]) } },
                finish: { print($0); code = 0 }, fail: { print($0) })
            exit(code)
        }
        let thread = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let peerID = "SHA256:" + String(repeating: "a", count: 43)
        let peer = FleetPeer(id: peerID, machine: "Studio Mac", transport: "ssh", state: .approved, reach: .approved)
        let rows = "\(peerID)\tStudio Mac\tssh\tapproved\tapproved\nself\tHere\tself\tapproved\tself\npending\tOther\tssh\tpending\tpending\n"
        let path = "/Users/test/a 'b;$(touch NOPE)/"
        let plan = try SessionTransferPlan(thread: thread, vendor: "codex", peer: peer, cwd: path)
        precondition(plan.arguments == ["fleet", "session", "send", thread, "--peer", peerID, "--cwd", path])
        func receipt(_ id: String = thread) -> String { "{\"status\":\"saved\",\"thread\":\"\(id)\",\"cwd\":\"/private/canonical/project\"}" }
        let validReceipt = receipt()
        let message = try plan.receipt(status: 0, output: validReceipt)
        precondition(message.contains("/private/canonical/project"))
        for output in ["{}", "bad JSON", receipt("wrong"), "{\"status\":\"saved\",\"thread\":\"\(thread)\",\"cwd\":\"relative\"}"] {
            do { _ = try plan.receipt(status: 0, output: output); fatalError("invalid receipt accepted") } catch {}
        }
        for (vendor, cwd) in [("claude", path), ("codex", "~/project"), ("codex", "/bad\npath")] {
            do { _ = try SessionTransferPlan(thread: thread, vendor: vendor, peer: peer, cwd: cwd); fatalError("invalid plan accepted") } catch {}
        }
        let coordinator = SessionTransferCoordinator(); var finished = 0, failed = 0
        await coordinator.perform(thread: thread, vendor: "codex", run: { args in
            precondition(!Thread.isMainThread && args == ["fleet", "peers", "--no-probe"]); return (0, rows)
        }, choose: { peers in precondition(peers == [peer]); return nil }, finish: { _ in fatalError("cancelled transfer completed") }, fail: { _ in fatalError("cancelled transfer failed") })
        for status: Int32 in [0, 1] {
            await coordinator.perform(thread: thread, vendor: "codex", run: { args in
                precondition(!Thread.isMainThread)
                if args == ["fleet", "peers", "--no-probe"] { return (0, rows) }
                precondition(args == plan.arguments); return (status, status == 0 ? validReceipt : "ERR session-import-refused")
            }, choose: { _ in (peer, path) }, finish: { message in
                precondition(message.contains("Studio Mac") && message.contains("original account")); finished += 1
            }, fail: { message in precondition(message.contains("directory exists") && !message.contains("ERR")); failed += 1 })
        }
        for result: (Int32, String) in [(1, rows), (0, "")] {
            await coordinator.perform(thread: thread, vendor: "codex", run: { _ in result },
                choose: { _ in fatalError("unavailable peers reached prompt") }, finish: { _ in fatalError("unavailable peers sent") }, fail: { _ in failed += 1 })
        }
        let started = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        let pending = Task { await coordinator.perform(thread: thread, vendor: "codex", run: { _ in
            started.continuation.yield(()); started.continuation.finish()
            precondition(release.wait(timeout: .now()+5) == .success); return (0, rows)
        }, choose: { _ in fatalError("cancelled read reached prompt") }, finish: { _ in fatalError("cancelled read sent") }, fail: { _ in fatalError("cancelled read failed") }) }
        for await _ in started.stream { break }
        await coordinator.perform(thread: thread, vendor: "codex", run: { _ in fatalError("concurrent read started") },
            choose: { _ in fatalError() }, finish: { _ in fatalError() }, fail: { message in precondition(message.contains("already in progress")); failed += 1 })
        pending.cancel(); release.signal(); await pending.value
        precondition(!coordinator.isRunning && finished == 1 && failed == 4)
        print("Native session transfer arguments, approval, cancellation, responsiveness and receipts passed")
    }
}
