import AppKit

@main struct NativeSignInTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--plan" {
            let cli = CommandLine.arguments[2], profile = CommandLine.arguments[3]
            let plan = try await SignInPlan.load(profile: profile, vendor: "codex") {
                SignInPlan.run(cli: cli, environment: ProcessInfo.processInfo.environment, args: $0)
            }
            print(String(data: try JSONSerialization.data(withJSONObject: plan.arguments), encoding: .utf8)!)
            return
        }
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "docs/audits/native-ownership-flow-spike.json"))) as! [String: Any]
        let binding = (fixture["active"] as! [String: Any])["binding"] as! [String: Any]
        let revision = String(repeating: "a", count: 64)
        func report(_ ownership: [String: Any], duplicate: Bool = false) -> String {
            let row: [String: Any] = ["name": "Work", "profileId": binding["profileId"]!, "metadataStatus": "ready",
                "routes": [["provider": "codex", "status": "available", "ownerBinding": ownership]]]
            return String(data: try! JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "profiles": duplicate ? [row, row] : [row]]), encoding: .utf8)!
        }
        let owned: [String: Any] = ["status": "registered", "revision": revision, "binding": binding]
        let text = report(owned)
        let plan = try SignInPlan.parse(profile: "Work", vendor: "codex", status: 0, output: text)
        precondition(plan.arguments == ["fleet", "auth", "login", "Work", "--expected-revision", revision])
        let alert = plan.alert(profile: "Work", label: "Codex")
        precondition(alert.informativeText.contains("same account") && !alert.informativeText.contains("removed"))
        let legacy = try SignInPlan.parse(profile: "Work", vendor: "codex", status: 0, output: report(["status": "unmanaged"]))
        precondition(legacy.arguments == ["login", "Work", "--vendor", "codex"] && legacy.owner == nil)
        let claude = try SignInPlan.parse(profile: "Work", vendor: "claude", status: 1, output: "")
        precondition(claude.arguments == ["login", "Work", "--vendor", "claude"])
        for invalid in ["{}", "not json", report(owned, duplicate: true), report(["status": "migration-pending"]),
                        report(["status": "conflicting"]), report(["status": "invalid"]), report(["status": "registered", "binding": binding]) ] {
            do { _ = try SignInPlan.parse(profile: "Work", vendor: "codex", status: 0, output: invalid); fatalError("invalid route accepted") }
            catch {}
        }
        for key in ["schemaVersion", "profileId", "grantId", "ownershipGeneration", "accountHash", "owner", "credentialStore"] {
            var invalid = binding; invalid[key] = key == "schemaVersion" ? true : "invalid"
            do { _ = try SignInPlan.parse(profile: "Work", vendor: "codex", status: 0,
                output: report(["status": "registered", "revision": revision, "binding": invalid])); fatalError("invalid binding accepted") }
            catch {}
        }
        do { _ = try SignInPlan.parse(profile: "Work", vendor: "codex", status: 1, output: text); fatalError("failed read accepted") }
        catch {}
        let coordinator = SignInCoordinator(); var confirmed = 0, launched = 0, failed = 0, cancelled = 0
        await coordinator.perform(profile: "Work", vendor: "codex", confirmLegacy: false, run: { args in
            precondition(!Thread.isMainThread && args == ["profiles", "--json"]); return (0, text)
        }, confirm: { _ in confirmed += 1; return false }, finish: { _ in launched += 1 }, cancelled: { cancelled += 1 }, fail: { _ in failed += 1 })
        precondition(confirmed == 1 && launched == 0 && failed == 0 && cancelled == 1, "owner cancellation launched login")
        await coordinator.perform(profile: "Work", vendor: "codex", confirmLegacy: false, run: { _ in (0, text) },
            confirm: { _ in true }, finish: { value in precondition(value.arguments == plan.arguments); launched += 1 }, fail: { _ in failed += 1 })
        await coordinator.perform(profile: "Work", vendor: "codex", confirmLegacy: false, run: { _ in (1, text) },
            confirm: { _ in fatalError("failed read reached confirmation") }, finish: { _ in launched += 1 }, fail: { _ in failed += 1 })
        precondition(launched == 1 && failed == 1)
        let started = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        let old = Task { await coordinator.perform(profile: "Work", vendor: "codex", confirmLegacy: false, run: { _ in
            started.continuation.yield(()); started.continuation.finish()
            precondition(release.wait(timeout: .now()+5) == .success); return (0, text)
        }, confirm: { _ in fatalError("stale read confirmed") }, finish: { _ in fatalError("stale read launched") }, fail: { _ in fatalError("stale read failed") }) }
        for await _ in started.stream { break }
        await coordinator.perform(profile: "Work", vendor: "codex", confirmLegacy: false, copyOnly: true, run: { _ in (0, text) },
            confirm: { _ in fatalError("copy asked for login") }, finish: { _ in launched += 1 }, fail: { _ in fatalError("copy failed") })
        release.signal(); await old.value
        precondition(launched == 2)
        // A terminal failure still reports completion; setup checks authentication separately.
        let failedPlan = SignInPlan(arguments: [], owner: plan.owner)
        let terminal = failedPlan.terminalCommand(cli: "/usr/bin/false", profile: "Work & Test", vendor: "codex", setup: true)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "open() { printf '%s\\n' \"$2\"; }; " + terminal]
        process.standardOutput = output; try process.run(); process.waitUntilExit()
        let callbacks = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.split(separator: "\n")
        precondition(callbacks.count == 2 && callbacks[0].contains("login-done") && callbacks[1].contains("refresh"))
        let items = URLComponents(string: String(callbacks[0]))!.queryItems!
        precondition(items.first(where: { $0.name == "profile" })?.value == "Work & Test")
        let quoted = SignInPlan.quote("/tmp/a' b;$(nope)")
        precondition(quoted == "'/tmp/a'\\'' b;$(nope)'")
        print("Native owner login routing, confirmation, cancellation, failed reads, stale responses and copying passed")
    }
}
