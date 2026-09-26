import Darwin
import Foundation

func waitForBoundProvider(_ started: URL) throws -> pid_t {
    let deadline = Date().addingTimeInterval(8)
    while !FileManager.default.fileExists(atPath: started.path) && Date() < deadline { usleep(20_000) }
    return pid_t(try String(contentsOf: started, encoding: .utf8))!
}

@main struct BoundAgentRunTests {
    static func main() throws {
        let repo = CommandLine.arguments[1]
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("n2-bound-loop-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let profiles = root.appendingPathComponent("profiles")
        let home = profiles.appendingPathComponent("Test/codex")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"tokens":{"access_token":"synthetic-private-token","account_id":"workspace"}}"#.write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("codex")
        try fm.copyItem(atPath: repo + "/tests/fake-bound-codex.py", toPath: binary.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        setenv("N2_AGENTS_ROOT", profiles.path, 1)
        setenv("HOME", root.path, 1)
        setenv("PATH", root.path + ":/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("N2_BOUND_TRACE", root.appendingPathComponent("trace").path, 1)
        unsetenv("OPENAI_BASE_URL")
        let started = root.appendingPathComponent("started")
        setenv("N2_BOUND_STARTED", started.path, 1)
        let account = "45f01d4b6f08a2de562009a269b814d5f52c2ceb8573ff8a0b7cbe624003b9b0"
        let slot = Slot(profile: "Test", vendor: "codex", signedIn: "yes", used: 12, quota: "ok", accountHash: account)
        var sequence = 0
        func request(_ cli: String, detach: Bool = true) -> TurnRequest {
            sequence += 1
            return TurnRequest(cli: cli, slot: slot, effort: .standard, cwd: root.path, prompt: "Synthetic prompt",
                               files: root.appendingPathComponent("turn-\(sequence)").path, timeout: 10, detach: detach)
        }
        setenv("N2_BOUND_FIXTURE", "", 1)
        let good = try runTurn(request(repo + "/agents"), abort: Flag())
        precondition(good.exit == 0 && good.usage.accountHash == account && good.stdout == "Bound answer", good.tail)
        precondition(good.usage.totalTokens == 60)
        recordUsageOutcome(cli: repo + "/agents", slot: slot.key, outcome: "ok", task: "bound-fixture/1", effort: .standard, usage: good.usage, startedAt: Date())
        let history = run(repo + "/agents", ["usage", "history"])
        precondition(history.ok && history.out.contains(account) && history.out.contains("bound-fixture/1"), history.said)
        precondition(!history.out.contains("synthetic-private-token"))

        let fake = root.appendingPathComponent("fake-agents")
        let terminal = "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
        let session = "{\"type\":\"thread.started\",\"thread_id\":\"session\"}"
        let report = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"N2_RESULT {}\"}}"
        let receipt = "{\"type\":\"n2.account.binding\",\"identity\":{\"status\":\"verified\",\"accountHash\":\"\(account)\"},\"session\":\"session\",\"turn\":\"turn\",\"usageScope\":\"provider-thread\"}"
        for suffix in ["", receipt.replacingOccurrences(of: account, with: String(repeating: "b", count: 64)), receipt + "\n" + receipt] {
            try ("#!/bin/sh\ncat <<'JSON'\n" + session + "\n" + report + "\n" + terminal + "\n" + suffix + "\nJSON\n").write(to: fake, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            let invalid = try runTurn(request(fake.path), abort: Flag())
            precondition(invalid.exit != 0 && invalid.usage.accountHash == nil, "bound success requires exactly one matching receipt")
        }
        func assertStopped(_ pid: pid_t) {
            let state = run("/bin/ps", ["-p", String(pid), "-o", "stat="]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            precondition(state.isEmpty || state.hasPrefix("Z"), "provider survived wrapper cleanup")
        }
        setenv("N2_BOUND_FIXTURE", "slow", 1)
        let crashed = try runTurn(request(repo + "/agents"), abort: Flag()) { pid in
            DispatchQueue.global().async {
                let provider = try! waitForBoundProvider(started)
                precondition(getpgid(provider) == pid, "server must share the persisted execution group")
                kill(pid, SIGKILL)
            }
        }
        precondition(crashed.exit != 0 && crashed.usage.accountHash == nil)
        assertStopped(try waitForBoundProvider(started))
        try fm.removeItem(at: started)
        let cancelled = try runTurn(request(repo + "/agents", detach: false), abort: Flag()) { _ in
            DispatchQueue.global().async {
                _ = try! waitForBoundProvider(started)
                kill(getpid(), SIGINT)
            }
        }
        precondition(cancelled.aborted && cancelled.exit != 0)
        assertStopped(try waitForBoundProvider(started))
        let leftovers = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".codex-home") }
        precondition(leftovers.isEmpty, "the loop must remove isolated config after crashes and cancellation")
        print("Bound loop launch, journal, missing-receipt, crash recovery and foreground cancellation tests passed")
    }
}
