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
                          slot("muse", "Unreadable", used: 10, quota: "credential-store-unavailable"),
                          slot("muse", "Missing", used: 10, quota: "no-token"),
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

        // Review: another lab whenever one is signed in, and a wait rather than self-review.
        let claude = slot("claude", "Work", used: 10), codex = slot("codex", "Home", used: 50)
        func reviewer(_ s: [Slot], of labs: Set<String>, avoid: Set<String> = []) -> String? {
            pickReviewer(s, effort: .deep, cooldowns: [:], busy: [:], notFrom: labs, avoidSlots: avoid)?.key
        }
        expect(reviewer([claude, codex], of: ["claude"]) == "codex|Home", "Claude's work goes to Codex, though Claude has more quota")
        expect(reviewer([claude, slot("codex", "Home", used: 97)], of: ["claude"]) == nil,
               "another lab out of quota means waiting, never self-review")
        expect(reviewer([claude, codex], of: ["codex"]) == "claude|Work", "a sign-off goes to the lab that didn't verify")
        expect(reviewLabs([claude, slot("codex", "Home", used: 97)], notFrom: ["claude"]) == ["codex"], "the wait names the lab it needs")
        expect(reviewer([claude, slot("codex", "Home", used: 10, signedIn: "no")], of: ["claude"]) == "claude|Work",
               "a lab that isn't signed in can't review; one lab reviews within itself")
        let a = slot("codex", "A", used: 10), b = slot("codex", "B", used: 60)
        expect(reviewer([a, b], of: ["codex"], avoid: ["codex|A"]) == "codex|B", "within one lab, another account reviews")
        expect(reviewer([a, slot("codex", "B", used: 99)], of: ["codex"], avoid: ["codex|A"]) == "codex|A",
               "a lone usable account still gets its review")

        // What the controller starts gets a clean signal state, though it is
        // started from a GCD thread (every signal blocked) by a process
        // ignoring SIGINT and SIGTERM: a TUI under test must see SIGWINCH.
        let probe = NSTemporaryDirectory() + "signals-\(UUID().uuidString)"
        defer { for f in [probe, probe + ".err"] { try? FileManager.default.removeItem(atPath: f) } }
        let previous = signal(SIGINT, SIG_IGN)
        let spawned = DispatchGroup()
        spawned.enter()
        DispatchQueue.global().async {
            _ = try? spawnAndWait(["/usr/bin/python3", "-c", "import signal; print(sorted(int(s) for s in signal.pthread_sigmask(signal.SIG_BLOCK, [])), signal.getsignal(signal.SIGINT) is signal.SIG_IGN)"],
                                  cwd: "/", stdin: "/dev/null", stdout: probe, stderr: probe + ".err",
                                  timeout: 30, detach: true, abort: Flag())
            spawned.leave()
        }
        spawned.wait()
        signal(SIGINT, previous)
        let seen = (try? String(contentsOfFile: probe, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        expect(seen == "[] False", "a spawned command starts with no blocked or ignored signals (saw \(seen ?? "nothing"))")

        // A failed command keeps the failure's name: the trial's PTY test dumped
        // 50 KB of screen bytes after it, and a plain tail kept only those.
        let dump = String(repeating: "\u{1B}[3;9H1\u{1B}[23;40H\u{1B}(B\u{1B}[m screen bytes\n", count: 1500)
        let output = "test_flash ... ok\nFAIL: test_resize (tests.test_tui_pty.CalculatorPTYTests)\n"
            + "  File \"tests/test_tui_pty.py\", line 479, in test_resize\nAssertionError: Timed out waiting for the long entry\n" + dump
            + "\nRan 67 tests in 7.6s\n\nFAILED (failures=1)\n"
        let excerpt = failureExcerpt(output)
        expect(excerpt.count <= 3000, "the excerpt fits its limit (\(excerpt.count))")
        expect(excerpt.contains("FAIL: test_resize") && excerpt.contains("AssertionError: Timed out") && excerpt.contains("line 479"),
               "the failing test, its line and its assertion survive")
        expect(excerpt.hasSuffix("FAILED (failures=1)\n") && !excerpt.contains("\u{1B}"), "the end is kept and terminal escapes are gone")
        expect(failureExcerpt("short\n") == "short\n", "short output is kept whole")

        // A repair keeps coupled chunks together: the trial's tui and pty-smoke
        // deadlocked split (pty-smoke waited on tui; tui's review failed on its test).
        func chunk(_ id: String, _ deps: [String] = []) -> Chunk {
            Chunk(id: id, title: id, instructions: "", paths: [id], criteria: [], dependsOn: deps, effort: .standard)
        }
        let model = chunk("model"), tui = chunk("tui", ["model", "layout"]), pty = chunk("pty-smoke", ["tui"]),
            tests = chunk("arithmetic-tests", ["model"]), docs = chunk("docs")
        expect(coupledRepairs([tui, pty]) == ["tui": ["pty-smoke"]], "a reopened chunk and its reopened dependent run as one, rooted at the dependency")
        expect(coupledRepairs([model, tests, tui, pty]) == ["model": ["arithmetic-tests", "tui", "pty-smoke"]],
               "links through each other join one group")
        expect(coupledRepairs([tui, docs]).isEmpty, "unrelated reopened chunks stay apart and run in parallel")
        expect(coupledRepairs([pty]).isEmpty, "a dependency that wasn't reopened couples nothing")
        expect(coupledRepairs([tui, pty, pty]) == ["tui": ["pty-smoke"]], "a chunk named twice neither traps nor doubles")
        // Folding that would make a cycle keeps the group apart (Codex's case:
        // a needs x, x needs b, c needs a and b; all but x reopened).
        let cyc = [chunk("a", ["x"]), chunk("x", ["b"]), chunk("b"), chunk("c", ["a", "b"])]
        let folded = absorbRepairs(cyc, reopened: ["a", "b", "c"], added: [])
        expect(folded.together.isEmpty && folded.apart.count == 1 && dependencyProblems(folded.chunks).isEmpty,
               "a fold that would cycle stays apart and the plan stays valid (\(folded))")
        let plain = absorbRepairs([model, chunk("layout"), tui, pty], reopened: ["tui", "pty-smoke"], added: [chunk("c", ["pty-smoke"])])
        expect(plain.together == ["tui+pty-smoke"] && plain.chunks.first { $0.id == "c" }?.dependsOn == ["pty-smoke", "tui"]
               && plain.chunks.first { $0.id == "pty-smoke" }?.status == .accepted, "a valid fold carries added dependents to its root")
        // What depended on an absorbed chunk, a chunk the repair adds included, waits for its carrier.
        var afterRepair = [model, tui, pty, chunk("c", ["pty-smoke"]), docs]
        waitForCarriers(&afterRepair, carriedBy: ["pty-smoke": "tui"])
        expect(afterRepair[3].dependsOn == ["pty-smoke", "tui"] && afterRepair[2].dependsOn == ["tui"] && afterRepair[4].dependsOn.isEmpty,
               "a dependent of the absorbed chunk now also waits for the root")

        // Workers: strength x quota left, and no slot past 1.5x its fair share.
        let hand: (String, Effort) -> Double = { lab, effort in Double(Adapter.of(lab)!.strength[effort]!) }
        func worker(_ s: [Slot], _ effort: Effort = .standard, assigned: [String: Int] = [:],
                    strength: @escaping (String, Effort) -> Double = hand) -> String? {
            pickWorker(s, effort: effort, cooldowns: [:], busy: [:], assigned: assigned, strength: strength)?.key
        }
        let roomy = slot("codex", "Roomy", used: 10), tight = slot("claude", "Tight", used: 70)
        expect(worker([tight, roomy]) == "codex|Roomy", "equal strength: more quota left wins")
        expect(worker([tight, roomy], strength: { lab, _ in lab == "claude" ? 3 : 1 }) == "claude|Tight",
               "a much stronger lab beats more quota: 3 x 0.3 > 1 x 0.9")
        expect(worker([tight, roomy], assigned: ["codex|Roomy": 2]) == "claude|Tight",
               "past 1.5x its fair share a slot waits while another has less")
        expect(worker([tight, roomy], assigned: ["codex|Roomy": 2, "claude|Tight": 2]) == "codex|Roomy",
               "level shares go back to the score")
        let ten = (0..<10).map { slot($0 < 5 ? "claude" : "codex", "P\($0)", used: Double($0) * 5) }
        var spread: [String: Int] = [:]
        for _ in 0..<20 { spread[worker(ten, assigned: spread)!, default: 0] += 1 }
        expect(spread.count == 10 && spread.values.max()! <= 3, "twenty chunks over ten slots: everyone works, nobody past 3 (\(spread))")
        expect(worker([slot("codex", "Full", used: 97), slot("claude", "Off", used: 10, signedIn: "no")]) == nil, "unusable slots never work")
        expect(worker([slot("codex", "Unmetered", used: nil, quota: "no-usage-api"), slot("claude", "Metered", used: 90)]) == "claude|Metered",
               "measured capacity before unmeasured")
        expect(worker([slot("codex", "Unmetered", used: nil, quota: "no-usage-api"), slot("claude", "Metered", used: 90)],
                      assigned: ["claude|Metered": 1]) == "claude|Metered",
               "the spread cap never hands work to unknown capacity while measured capacity is left")

        // Strength is learned from reviewed work once a lab has five outcomes.
        let recordPath = NSTemporaryDirectory() + "lab-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: recordPath) }
        let record = LabRecord(path: recordPath)
        for score in [1.0, 1, 0.5, 0] { record.add(Outcome(slot: "codex|A", chunk: "c", effort: .deep, score: score, at: Date())) }
        expect(record.strength("codex", .deep) == 3, "four outcomes: still the adapter's rating")
        record.add(Outcome(slot: "codex|B", chunk: "d", effort: .deep, score: 0, at: Date()))
        expect(abs(record.strength("codex", .deep) - 2.0) < 1e-9, "five outcomes averaging 0.5 measure 2.0")
        expect(record.strength("codex", .light) == 2, "other efforts keep their rating")
        expect(LabRecord(path: recordPath).outcomes.count == 5, "the record survives a restart")
        // A torn line costs only itself: the next outcome starts on a line of its own.
        let torn = NSTemporaryDirectory() + "lab-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: torn) }
        try? Data("{\"slot\":\"codex|T\",\"chunk\":\"half".utf8).write(to: URL(fileURLWithPath: torn))
        LabRecord(path: torn).add(Outcome(slot: "codex|T", chunk: "whole", effort: .light, score: 1, at: Date()))
        expect(LabRecord(path: torn).outcomes.map(\.chunk) == ["whole"], "an outcome after a torn line is still readable")
        // Two runs appending at once lose nothing and corrupt nothing.
        let shared = NSTemporaryDirectory() + "lab-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: shared) }
        // Each writer is its own record, as each run's controller is its own process.
        DispatchQueue.concurrentPerform(iterations: 4) { r in
            let record = LabRecord(path: shared)
            for i in 0..<100 {
                record.add(Outcome(slot: "codex|R\(r)", chunk: "c\(i)-" + String(repeating: "x", count: i % 37), effort: .standard, score: 1, at: Date()))
            }
        }
        let lines = ((try? String(contentsOfFile: shared, encoding: .utf8)) ?? "").split(separator: "\n")
        expect(lines.count == 400 && LabRecord(path: shared).outcomes.count == 400,
               "concurrent appends keep every line whole (\(lines.count) lines, \(LabRecord(path: shared).outcomes.count) readable)")

        // Approval waits for every answer, and for a plan drafted with any answer that changes it.
        var q = Question(id: "where", question: "Where?", options: [.init(label: "b", recommended: true), .init(label: "c", recommended: false)])
        expect(approvalBlocker([q], run: "r1")?.contains("agents loop answer r1") == true, "an open question blocks approval")
        q.answer = "b"
        expect(approvalBlocker([q], run: "r1") == nil, "the recommendation is what the plan assumed")
        q.answer = "c"
        expect(approvalBlocker([q], run: "r1")?.contains("agents loop replan r1") == true, "another answer needs a new draft")
        q.plannedWith = "c"
        expect(approvalBlocker([q], run: "r1") == nil, "a draft planned with the answer can be approved")
        q.answer = "b"
        expect(approvalBlocker([q], run: "r1")?.contains("agents loop replan r1") == true,
               "back to the recommendation after a draft built on another answer needs a new draft")
        var open = Question(id: "x", question: "X?", options: [])
        open.answer = "no preference"
        expect(approvalBlocker([open], run: "r1") == nil, "no preference on a question without a recommendation changes nothing")

        let reserved = slot("claude", "Reserve", used: 96, quota: "local-reserve")
        expect(pick([reserved], effort: .deep, cooldowns: [:], busy: [:]) == nil,
               "N2 reserve stays excluded without a provider-rejection label")
        expect(unusable(reserved, cooldowns: [:]) == "at N2 scheduling reserve", "name local scheduling policy")
        let measured = slot("muse", "Measured", used: 80)
        let unmeasured = slot("codex", "Unmeasured", used: nil, quota: "no-usage-api")
        for effort in Effort.allCases {
            expect(pick([unmeasured, measured], effort: effort, cooldowns: [:],
                        busy: ["muse|Measured": 3], avoidVendors: ["muse"])?.key == measured.key,
                   "measured capacity beats unmeasured strength, busyness and preference")
        }
        expect(pick([unmeasured], effort: .deep, cooldowns: [:], busy: [:])?.key == unmeasured.key,
               "no-API remains an explicit fallback")
        for bad in [slot("codex", "Missing", used: nil), slot("codex", "Failed", used: 0, quota: "fetch-error"),
                    slot("codex", "NaN", used: .nan), slot("codex", "Denied", used: 100)] {
            expect(unusable(bad, cooldowns: [:]) != nil, "missing/failed/invalid/denied slots are ineligible")
        }
        let collector = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: collector, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: collector) }
        let script = collector.appendingPathComponent("agents")
        try! """
        #!/bin/sh
        if [ "$1" = porcelain ]; then
          printf 'V\tcodex\t1\tnone\toauth\nS\tFixture\tcodex\tok\tunused\tyes\n'
        else
          echo 'collector unavailable' >&2
          exit 7
        fi
        """.write(to: script, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let failedSlots = try! SlotSource(cli: script.path).slots(fresh: true)
        expect(failedSlots.count == 1 && failedSlots[0].quota == "fetch-error", "failed metered read must not become no-API")
        let windows = collector.appendingPathComponent("windows")
        try! """
        #!/bin/sh
        if [ "$1" = porcelain ]; then
          printf 'V\tcodex\t1\tnone\toauth\nS\tSpent\tcodex\tok\tunused\tyes\nS\tDenied\tcodex\tok\tunused\tyes\n'
        else
          now=$(date +%s)
          printf '{"schemaVersion":1,"provider":"codex","profile":"Spent","status":"ok","observedAt":%s,"windows":[{"scope":"codex:primary_window","usedPercent":100,"resetsAt":1790393040},{"scope":"codex:secondary_window","usedPercent":30,"resetsAt":1790411040}],"restrictions":[]}\n' "$now"
          printf '{"schemaVersion":1,"provider":"codex","profile":"Denied","status":"restricted","observedAt":%s,"windows":[{"scope":"codex:primary_window","usedPercent":80,"resetsAt":1790411040}],"restrictions":[{"scope":"codex","reason":"limit-reached"}]}\n' "$now"
        fi
        """.write(to: windows, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: windows.path)
        let read = try! SlotSource(cli: windows.path).slots(fresh: true)
        expect(read.first { $0.profile == "Spent" }?.resets == Date(timeIntervalSince1970: 1790393040),
               "a spent 5h window returns at its own reset, not the weekly one")
        expect(read.first { $0.profile == "Denied" }?.resets == nil,
               "a denial that names no reset does not borrow a window's reset")
        expect(read.count == 2 && read.allSatisfy { unusable($0, cooldowns: [:]) != nil },
               "spent and refused slots are ineligible")

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
