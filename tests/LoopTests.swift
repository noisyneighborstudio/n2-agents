import Foundation
import Darwin

// Compiled with the loop sources minus main.swift (see scripts/test.sh).
@main struct LoopTests {
    static func expect(_ ok: Bool, _ what: String) {
        guard ok else {
            FileHandle.standardError.write("✗ \(what)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    static func slot(_ vendor: String, _ profile: String, used: Double?, quota: String = "ok", signedIn: String = "yes") -> Slot {
        Slot(profile: profile, vendor: vendor, signedIn: signedIn, used: used, quota: quota)
    }

    static func main() {
        // Even descriptors without FD_CLOEXEC must stay in the controller.
        let source = open("/dev/null", O_RDONLY)
        let inherited = fcntl(source, F_DUPFD, 100)
        close(source)
        expect(inherited >= 100, "create descriptor inheritance fixture")
        defer { close(inherited) }
        for detached in [false, true] {
            do {
                let result = try spawnAndWait(
                    ["/bin/sh", "-c", "test ! -e /dev/fd/\(inherited)"], cwd: "/",
                    stdin: "/dev/null", stdout: "/dev/null", stderr: "/dev/null",
                    timeout: 5, detach: detached, abort: Flag())
                expect(result.0 == 0 && !result.1 && !result.2, "spawn closes unrelated descriptors, detached=\(detached)")
            } catch { expect(false, "spawn descriptor test: \(error)") }
        }

        // Reports: the last marker wins, strings with braces don't confuse it.
        let text = "echo of the prompt: N2_RESULT {\"x\":1}\nwork…\nN2_RESULT {\"status\":\"done\",\"summary\":\"a } brace\"}\ntokens used: 12"
        expect(parseReport(text)?["summary"] as? String == "a } brace", "parses the last N2_RESULT object")
        expect(parseReport("```json\n{\"decision\":\"accept\"}\n```")?["decision"] as? String == "accept", "falls back to a fenced block")
        expect(parseReport("no json here") == nil, "no report is nil")

        // Slot trouble is told apart from work trouble.
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        if case .quota(let until) = Failure.classify("ERROR: You've hit your usage limit. Try again at Sep 26th, 2026 11:20 AM.", now: now) {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
            expect(f.string(from: until) == "2026-09-26 11:20", "reads the reset time a lab states")
        } else { expect(false, "usage limit is quota") }
        if case .quota(let until) = Failure.classify("429 Too Many Requests", now: now) {
            expect(until == now.addingTimeInterval(3600), "an unstated reset waits an hour")
        } else { expect(false, "429 is quota") }
        expect(Failure.reportedResetTime(in: "try again in 1 hour and 30 minutes", now: now) == nil, "compound reset is not a one-hour expiry")
        expect(Failure.reportedResetTime(in: "try again in 2 seconds.", now: now) == now.addingTimeInterval(2), "complete relative reset is known")
        expect(Failure.reportedResetTime(in: "try again at Sep 26 11:20 AM", now: now) == nil, "missing year/timezone is unknown")
        expect(Failure.reportedResetTime(in: "try again at 2099-09-26T11:20:00Z", now: now) != nil, "qualified future ISO reset is known")
        expect(Failure.reportedResetTime(in: "try again at 2000-09-26T11:20:00Z", now: now) == nil, "past reset is not recovery evidence")
        if case .auth = Failure.classify("Error: not logged in") {} else { expect(false, "not logged in is auth") }
        if case .attention = Failure.classify("[ACTION REQUIRED] An update to our Consumer Terms has taken effect. You must run `claude` to review the updated terms.") {}
        else { expect(false, "new terms need a person") }
        if case .outage = Failure.classify("HTTP 503 Service Unavailable") {} else { expect(false, "503 is an outage") }
        if case .other = Failure.classify("TypeError: undefined is not a function") {} else { expect(false, "a crash is other") }

        for message in ["You've hit your session limit", "You've hit your monthly spend limit",
                        "You're out of usage credits. Switch to another model to continue."] {
            if case .quota = Failure.classify(message) {} else { expect(false, "provider rejection: \(message)") }
        }
        for candidate in [slot("claude", "Unknown", used: nil),
                          slot("codex", "Failed", used: 10, quota: "fetch-error"),
                          slot("claude", "Throttled", used: 10, quota: "rate-limited")] {
            expect(pick([candidate], effort: .deep, cooldowns: [:], busy: [:]) == nil,
                   "missing or failed measurements cannot advertise capacity")
        }

        // Paths: overlapping chunks never run together.
        expect(pathsOverlap(["src/api/**"], ["src/api/users.ts"]), "a glob covers a file under it")
        expect(pathsOverlap(["**"], ["docs/x.md"]), "** overlaps everything")
        expect(!pathsOverlap(["src/api/**"], ["src/ui/**"]), "sibling dirs don't overlap")
        expect(!pathsOverlap(["a.txt"], ["b.txt"]), "different files don't overlap")
        expect(pathsOverlap(["src/*.ts"], ["src/app.ts"]), "a star in a dir overlaps its files")
        expect(inPaths("src/api/users.ts", ["src/api/**"]) && inPaths("src/api/users.ts", ["src/api"]), "in-scope files")
        expect(!inPaths("src/ui/a.ts", ["src/api/**"]), "out-of-scope files")

        // Picking: strongest for the effort, then most quota, never an unusable slot.
        let slots = [slot("claude", "Work", used: 40), slot("codex", "Home", used: 10), slot("muse", "N2", used: nil, quota: "no-usage-api"),
                     slot("claude", "Old", used: 1, quota: "stale-token"), slot("codex", "Full", used: 97)]
        expect(pick(slots, effort: .deep, cooldowns: [:], busy: [:])?.key == "codex|Home", "equal strength: more quota wins")
        expect(pick(slots, effort: .deep, cooldowns: ["codex|Home": Cooldown(until: .distantFuture, reason: "x")], busy: [:])?.key == "claude|Work",
               "a cooling slot is skipped")
        expect(pick(slots, effort: .deep, cooldowns: [:], busy: [:], avoidVendors: ["codex"])?.key == "claude|Work",
               "review roles prefer another lab")
        expect(pick([slots[3], slots[4]], effort: .light, cooldowns: [:], busy: [:]) == nil, "expired or full slots are never picked")
        expect(pick([slot("claude", "A", used: 10), slot("claude", "B", used: 10)], effort: .standard, cooldowns: [:], busy: ["claude|A": 1])?.key == "claude|B",
               "work spreads across equal slots")

        let reserved = slot("claude", "Reserve", used: 96, quota: "local-reserve")
        expect(pick([reserved], effort: .deep, cooldowns: [:], busy: [:]) == nil,
               "N2 reserve stays excluded without a provider-rejection label")
        expect(unusable(reserved, cooldowns: [:]) == "at N2 scheduling reserve", "name local scheduling policy")

        // Plans: every problem is named, so the planner can fix exactly that.
        let bad: [String: Any] = ["plan": ["criteria": [["id": "c1", "description": "d", "verification": "v"], ["id": "c2", "description": "d", "verification": "v"]],
                                           "chunks": [["id": "x", "title": "t", "instructions": "i", "paths": [], "criteria": ["c1", "nope"], "dependsOn": ["y"], "effort": "light"],
                                                      ["id": "y", "title": "t", "instructions": "i", "paths": ["y"], "criteria": ["c1"], "dependsOn": ["x"], "effort": "huge"]]]]
        let (plan, _, errors) = parsePlan(bad)
        let all = errors.joined(separator: "\n")
        expect(plan == nil, "an invalid plan is refused")
        expect(all.contains("chunk \"x\": needs paths"), "names the chunk without paths")
        expect(all.contains("chunk \"x\": serves unknown criterion \"nope\""), "names the unknown criterion")
        expect(all.contains("chunk \"y\": effort must be"), "names the bad effort")
        expect(all.contains("criterion \"c2\" is served by no chunk"), "every criterion needs a chunk")
        let cyclic = [Chunk(id: "p", title: "", instructions: "", paths: ["p"], criteria: [], dependsOn: ["q"], effort: .light),
                      Chunk(id: "q", title: "", instructions: "", paths: ["q"], criteria: [], dependsOn: ["p"], effort: .light)]
        expect(dependencyProblems(cyclic).contains { $0.hasPrefix("dependency cycle") }, "finds dependency cycles")

        // Done means every criterion and every command, on this exact commit.
        var s = RunState(id: "r", created: now, repo: "/", baseCommit: "0", branch: "b", sources: [], status: .running, reason: nil,
                         retryAt: nil, budgetMs: 1, usedMs: 0, concurrency: 1, keepAwake: false,
                         plan: Plan(goal: "g", criteria: [Criterion(id: "c1", description: "", verification: "")], verificationCommands: ["make test"], chunks: []),
                         questions: [], turns: [], evidence: [], commands: [], cooldowns: [:], signatures: [:], events: [], lastMerge: nil)
        s.evidence = [Evidence(criterion: "c1", passed: true, detail: "", candidate: "A", turn: "t")]
        expect(!s.definitionOfDoneHolds(on: "A"), "a command that never ran is not a pass")
        s.commands = [CommandResult(command: "make test", exitCode: 0, tail: "", candidate: "A", seconds: 1)]
        expect(s.definitionOfDoneHolds(on: "A"), "criteria and commands pass on A")
        expect(!s.definitionOfDoneHolds(on: "B"), "evidence for A says nothing about B")
        s.commands.append(CommandResult(command: "make test", exitCode: 1, tail: "", candidate: "A", seconds: 1))
        expect(!s.definitionOfDoneHolds(on: "A"), "the latest command result counts")

        print("Loop tests passed")
    }
}
