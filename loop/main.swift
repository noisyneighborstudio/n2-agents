import Darwin
import Foundation

let usage = """
agents loop — fan a goal out across your slots until its definition of done holds.

  agents loop "goal" --budget 2h [--file spec.md]…   plan, interview, approve, start
  agents loop plan "goal" --budget 2h                plan and interview; approve later
  agents loop approve <run> [--plan edited.json]     approve a drafted plan and start
  agents loop answer <run> <question> <answer>       answer a planner's question
  agents loop answer <run> "<decision>"              answer a paused run's question and resume
  agents loop waive <run> <criterion> "<why>"        waive a criterion the sign-off judged impossible, and resume
  agents loop replan <run>                           draft the plan again with your answers
  agents loop start --plan plan.json --budget 2h --yes   start a reviewed plan unattended
  agents loop status [run] [--json]                  where it stands, what done means
  agents loop wait [run] [--timeout 30m] [--json]    block until a merge, repair, pause, wait or done
  agents loop list                                   every run
  agents loop pause [run]                            stop turns now; all work is kept
  agents loop resume [run] [--budget 4h]             continue; --budget sets a new total
  agents loop log [run] [-f]                         the controller's log

Options:
  --budget <duration>    total agent time for the run (e.g. 45m, 2h)
  --concurrency <n>      agents working at once, 1-8 (default 3)
  --file <path>          add a document to the goal; repeatable
  --cwd <dir>            the repository (default: current directory)
  --keep-awake           keep the Mac awake while the run is going
  --json                 plan, answer, replan, status, wait: JSON on stdout
  --timeout <duration>   wait: return after this long with nothing new (default 30m)

How it works: a planner splits the goal into chunks and writes the definition
of done — observable criteria plus exact verification commands — which you
approve. Each chunk goes to the best slot for its effort with quota left, in
its own git worktree. A supervisor reviews every chunk before it is merged,
diagnoses stalls, and signs off at the end. Done means a fresh verifier found
every criterion met, and every command passed, on the final commit. Work lands
on branch n2/loop-<run>; your checkout is untouched and nothing is pushed.
"""

struct Args {
    var command = "start"
    var positional: [String] = []
    var files: [String] = []
    var plan: String?
    var budget: Int?
    var concurrency = 3
    var cwd = FileManager.default.currentDirectoryPath
    var keepAwake = false
    var yes = false
    var json = false
    var follow = false
    var timeout: Int?
}

func parseArgs(_ argv: [String]) throws -> Args {
    var a = Args()
    let commands: Set = ["start", "plan", "approve", "answer", "waive", "replan", "status", "wait", "list", "pause", "resume", "log", "_controller"]
    var rest = argv[...]
    if let first = rest.first, commands.contains(first) { a.command = first; rest = rest.dropFirst() }
    func value(_ flag: String) throws -> String {
        guard let v = rest.first, !v.hasPrefix("--") else { throw LoopError("\(flag) needs a value") }
        rest = rest.dropFirst()
        return v
    }
    while let arg = rest.first {
        rest = rest.dropFirst()
        switch arg {
        case "--budget": a.budget = try parseDuration(try value(arg))
        case "--concurrency":
            guard let n = Int(try value(arg)), (1...8).contains(n) else { throw LoopError("--concurrency takes 1-8") }
            a.concurrency = n
        case "--file": a.files.append(try value(arg))
        case "--plan": a.plan = try value(arg)
        case "--timeout": a.timeout = try parseDuration(try value(arg))
        case "--cwd": a.cwd = try value(arg)
        case "--keep-awake": a.keepAwake = true
        case "--yes": a.yes = true
        case "--json": a.json = true
        case "-f", "--follow": a.follow = true
        case "-h", "--help": print(usage); exit(0)
        default:
            if arg.hasPrefix("-") { throw LoopError("unknown option \(arg) (see: agents loop --help)") }
            a.positional.append(arg)
        }
    }
    return a
}

let interactive = isatty(0) == 1 && isatty(1) == 1
/// With --json, stdout carries only the JSON; progress goes to stderr.
var jsonOut = false

func say(_ line: String) {
    if jsonOut { FileHandle.standardError.write(Data((line + "\n").utf8)) } else { print(line) }
}

func ask(_ prompt: String) -> String {
    print(prompt, terminator: "")
    fflush(stdout)
    return (readLine() ?? "").trimmingCharacters(in: .whitespaces)
}

func agentsCLI() throws -> String {
    guard let cli = ProcessInfo.processInfo.environment["N2_AGENTS_CLI"], cli.hasPrefix("/") else {
        throw LoopError("run this through the agents CLI: agents loop …")
    }
    return cli
}

// MARK: - planning

/// One planner turn, failing over across slots the way the controller does.
func planOnce(_ s: inout RunState, cli: String, source: SlotSource, cwd: String, errors: [String]) throws -> [String: Any] {
    var avoid = Set<String>()
    var failedPlans = 0
    let cancellationFile = Store.standard().pauseFile(s.id)
    while failedPlans < 4 {
        guard !FileManager.default.fileExists(atPath: cancellationFile) else { throw LoopError("planning cancelled") }
        guard let slot = pick(try source.slots(), effort: .deep, cooldowns: s.cooldowns, busy: [:], avoidSlots: avoid) else {
            throw LoopError("no signed-in slot with quota left to plan with (see: agents list, agents best)")
        }
        say("planning with \(slot.key)…")
        let id = "\(s.turns.count + 1)-planner"
        s.turns.append(Turn(id: id, role: .planner, chunk: nil, slot: slot.key, effort: .deep, startedAt: Date()))
        try Store.standard().save(s)
        let out = try runTurn(TurnRequest(cli: cli, slot: slot, effort: .deep, cwd: cwd,
                                          prompt: plannerPrompt(goal: s.plan.goal, sources: s.sources, answers: s.questions,
                                                                budgetMs: s.budgetMs, errors: errors),
                                          files: Store.standard().turnFiles(s.id, id), timeout: Limits.review, detach: false, cancellationFile: cancellationFile),
                              abort: Flag()) { pid in
            guard !FileManager.default.fileExists(atPath: cancellationFile) else { throw LoopError("planning cancelled") }
            if slot.vendor == "codex", slot.accountHash != nil {
                s.turns[s.turns.count - 1].pgid = pid
                try Store.standard().save(s)
            }
        }
        s.usedMs += Int(out.seconds * 1000)
        let i = s.turns.count - 1
        s.turns[i].endedAt = Date()
        if out.aborted || FileManager.default.fileExists(atPath: cancellationFile) {
            s.turns[i].outcome = "aborted"
            s.reason = "planning stopped; the draft still needs a valid plan and approval"
            try Store.standard().save(s)
            throw LoopError("planning cancelled")
        }
        if out.exit == 0, let report = parseReport(out.stdout) {
            s.turns[i].outcome = "ok"
            recordUsageOutcome(cli: cli, slot: slot.key, outcome: "ok", task: "\(s.id)/\(id)", effort: .deep, usage: out.usage, failureText: out.tail, startedAt: s.turns[i].startedAt)
            return report
        }
        s.turns[i].note = oneLine(out.tail, 300)
        if out.exit == 0 {
            s.turns[i].outcome = "invalid"
        } else {
            let (outcome, cooldown) = slotTrouble(slot.key, out.tail)
            s.turns[i].outcome = outcome
            s.cooldowns[slot.key] = cooldown
        }
        recordUsageOutcome(cli: cli, slot: slot.key, outcome: s.turns[i].outcome ?? "failed", task: "\(s.id)/\(id)", effort: .deep, usage: out.usage, failureText: out.tail, startedAt: s.turns[i].startedAt)
        // Exhausted capacity says nothing about the planner's answer. Try
        // each remaining slot without spending the invalid-plan allowance.
        if s.turns[i].outcome != "quota" { failedPlans += 1 }
        avoid.insert(slot.key)
        say("  \(slot.key) \(out.exit == 0 ? "returned no plan" : "failed: " + oneLine(out.tail, 160))\(failedPlans < 4 ? " — trying another slot" : "")")
    }
    throw LoopError("four non-quota planner turns failed; see \(Store.standard().dir(s.id))/turns")
}

/// Plan until the draft validates, repairing it from the named problems.
func draft(_ s: inout RunState, cli: String, source: SlotSource, cwd: String) throws {
    var errors: [String] = []
    for _ in 0..<3 {
        let report = try planOnce(&s, cli: cli, source: source, cwd: cwd, errors: errors)
        let (plan, questions, problems) = parsePlan(report)
        if var plan {
            if plan.goal.isEmpty { plan.goal = s.plan.goal }
            s.plan = plan
            let answered = Dictionary(uniqueKeysWithValues: s.questions.compactMap { q in q.answer.map { (q.question, $0) } })
            // The planner saw these answers, so this draft is planned with them.
            s.questions = questions.map { var q = $0; q.answer = answered[q.question]; q.plannedWith = q.answer; return q }
            return
        }
        errors = problems
        say("  the plan had \(problems.count) problem(s); asking for a corrected one")
    }
    throw LoopError("the planner couldn't produce a valid plan:\n  " + errors.joined(separator: "\n  "))
}

/// Ask each open question; any answer other than the recommendation means
/// the plan is drafted again with it.
func interview(_ s: inout RunState) -> Bool {
    var changed = false
    for i in s.questions.indices where s.questions[i].answer == nil {
        let q = s.questions[i]
        print("\n\(q.question)")
        for (n, o) in q.options.enumerated() { print("  \(n + 1). \(o.label)\(o.recommended ? "  (recommended)" : "")") }
        let reply = ask("Answer [Enter = recommended, a number, or your own words]: ")
        let rec = q.options.first(where: \.recommended)?.label
        if reply.isEmpty { s.questions[i].answer = rec ?? "no preference"; continue }
        let chosen = Int(reply).flatMap { $0 >= 1 && $0 <= q.options.count ? q.options[$0 - 1].label : nil } ?? reply
        s.questions[i].answer = chosen
        if chosen != rec { changed = true }
    }
    return changed
}

func writePlanFile(_ s: RunState) throws -> String {
    let path = Store.standard().dir(s.id) + "/plan.json"
    let plan: [String: Any] = [
        "goal": s.plan.goal,
        "criteria": s.plan.criteria.map { ["id": $0.id, "description": $0.description, "verification": $0.verification] },
        "verificationCommands": s.plan.verificationCommands,
        "chunks": s.plan.chunks.map { ["id": $0.id, "title": $0.title, "instructions": $0.instructions, "paths": $0.paths,
                                        "criteria": $0.criteria, "dependsOn": $0.dependsOn, "effort": $0.effort.rawValue] },
    ]
    let data = try JSONSerialization.data(withJSONObject: ["plan": plan], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
    return path
}

func loadPlanFile(_ path: String, into s: inout RunState) throws {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw LoopError("\(path) is not a JSON object")
    }
    let (plan, _, errors) = parsePlan(obj["plan"] == nil ? ["plan": obj] : obj)
    guard var plan else { throw LoopError("\(path) is not a valid plan:\n  " + errors.joined(separator: "\n  ")) }
    if plan.goal.isEmpty { plan.goal = s.plan.goal }
    s.plan = plan
}

// MARK: - commands

func newRun(_ a: Args, store: Store) throws -> RunState {
    let repo = run("git", ["rev-parse", "--show-toplevel"], cwd: a.cwd)
    guard repo.ok else { throw LoopError("\(a.cwd) is not in a git repository — the loop works in git worktrees (git init first)") }
    let root = repo.out.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = try head(root)
    var budget = a.budget
    if budget == nil, interactive { budget = try parseDuration(ask("Budget — total agent time for this run (e.g. 2h): ")) }
    guard let budget else { throw LoopError("give the run a budget: --budget 2h") }
    var sources: [String] = []
    for f in a.files {
        guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { throw LoopError("can't read \(f)") }
        sources.append("--- \(f) ---\n\(text)")
    }
    let goal = a.positional.joined(separator: " ")
    guard !goal.isEmpty || !sources.isEmpty || a.plan != nil else { throw LoopError("what's the goal? agents loop \"goal\" --budget 2h") }
    let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    if !trackedChanges(root).isEmpty || !git(root, "ls-files", "--others", "--exclude-standard").out.isEmpty {
        say("note: uncommitted changes in \(root) are not part of the run — it starts from \(base.prefix(10))")
    }
    let s = RunState(
        id: id, created: Date(), repo: root, baseCommit: base, branch: "n2/loop-\(id.prefix(8))", sources: sources,
        status: .draft, reason: nil, retryAt: nil, budgetMs: budget, usedMs: 0, concurrency: a.concurrency,
        keepAwake: a.keepAwake,
        plan: Plan(goal: goal.isEmpty ? "Complete the work described in the supplied documents." : goal,
                   criteria: [], verificationCommands: [], chunks: []),
        questions: [], turns: [], evidence: [], commands: [], cooldowns: [:], signatures: [:], events: [], lastMerge: nil)
    try store.save(s)
    return s
}

/// Plan in a throwaway worktree of the starting commit: planners read, and
/// the user's checkout is never where an agent runs.
func planRun(_ s: inout RunState, store: Store, cli: String, interview asking: Bool = interactive) throws {
    guard let lock = store.lock(s.id) else { throw LoopError("run already has an active planner or controller") }
    defer {
        try? FileManager.default.removeItem(atPath: store.pauseFile(s.id))
        flock(lock, LOCK_UN); close(lock)
    }
    let dir = store.dir(s.id) + "/plan"
    _ = try gitOrThrow(s.repo, ["worktree", "add", "--detach", dir, s.baseCommit])
    defer { _ = git(s.repo, "worktree", "remove", "--force", dir) }
    let source = SlotSource(cli: cli)
    try draft(&s, cli: cli, source: source, cwd: dir)
    try store.save(s)
    if asking, interview(&s) {
        print("\nre-planning with your answers…")
        try draft(&s, cli: cli, source: source, cwd: dir)
    }
    try store.save(s)
}

func approveAndStart(_ s: inout RunState, store: Store, cli: String) throws {
    guard !store.controllerRunning(s.id) else { throw LoopError("run already has an active planner or controller") }
    if let blocker = approvalBlocker(s.questions, run: s.shortId) { throw LoopError("not approved: " + blocker) }
    recoverTurnProcesses(&s.turns, runId: s.id, store: store)
    try? FileManager.default.removeItem(atPath: store.pauseFile(s.id))
    _ = try gitOrThrow(s.repo, ["branch", s.branch, s.baseCommit])
    _ = try gitOrThrow(s.repo, ["worktree", "add", store.dir(s.id) + "/integration", s.branch])
    s.status = .running
    s.log("approved", "\(s.plan.criteria.count) criteria, \(s.plan.chunks.count) chunks, budget \(human(s.budgetMs))")
    try store.save(s)
    try launchController(s, store: store)
    print("""

    started loop \(s.shortId) on branch \(s.branch)
      agents loop status \(s.shortId)     where it stands
      agents loop log \(s.shortId) -f     follow it
      agents loop pause \(s.shortId)      stop now, keep everything
    """)
}

func launchController(_ s: RunState, store: Store) throws {
    guard let exe = Bundle.main.executablePath else { throw LoopError("can't find my own executable") }
    try spawnDetached([exe, "_controller", s.id], log: store.controllerLog(s.id))
    // It takes the lock at once; wait for it so status is truthful immediately.
    for _ in 0..<50 where !store.controllerRunning(s.id) { usleep(100_000) }
}

func confirmOrDraft(_ s: inout RunState, store: Store, cli: String, yes: Bool) throws {
    if let blocker = approvalBlocker(s.questions, run: s.shortId) {
        _ = try writePlanFile(s)
        print("\n" + describePlan(s, slots: nil) + "\nsaved as a draft: " + blocker)
        return
    }
    let source = SlotSource(cli: cli)
    print("\n" + describePlan(s, slots: try? source.slots()))
    if yes || (interactive && ask("Approve and start? [y/N] ").lowercased().hasPrefix("y")) {
        try approveAndStart(&s, store: store, cli: cli)
    } else {
        let file = try writePlanFile(s)
        print("saved as a draft. To change it, edit \(file); then: agents loop approve \(s.shortId) --plan \(file)")
    }
}

/// A draft as an agent reads it: the plan, its questions, and what stands
/// between it and approval.
func draftJSON(_ s: RunState) throws -> String {
    let questions: [[String: Any]] = s.questions.map { q in
        var o: [String: Any] = ["id": q.id, "question": q.question,
                                "options": q.options.map { ["label": $0.label, "recommended": $0.recommended] }]
        o["answer"] = q.answer ?? NSNull()
        o["changesPlan"] = q.changesPlan
        return o
    }
    let view: [String: Any] = [
        "run": s.shortId, "status": s.status.rawValue, "goal": s.plan.goal, "budget": human(s.budgetMs),
        "criteria": s.plan.criteria.map { ["id": $0.id, "description": $0.description, "verification": $0.verification] },
        "verificationCommands": s.plan.verificationCommands,
        "chunks": s.plan.chunks.map { ["id": $0.id, "title": $0.title, "paths": $0.paths, "dependsOn": $0.dependsOn,
                                        "effort": $0.effort.rawValue] },
        "questions": questions,
        "blocker": approvalBlocker(s.questions, run: s.shortId) ?? NSNull(),
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: view, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
}

/// The events worth telling someone about: work merged, a repair, a wait
/// for quota, a pause, done.
func newsworthy(_ e: Event) -> Bool {
    ["merge", "done", "paused", "capacity"].contains(e.kind) || (e.kind == "supervisor" && e.detail.hasPrefix("repair"))
}

/// Block until the run has news, then print it: the events since the call,
/// and where the run stands. A paused, finished or orphaned run answers at once.
func waitForNews(store: Store, id: String, timeoutMs: Int, json: Bool) throws {
    let first = try store.load(id)
    let mark = first.events.last
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    var s = first
    var news: [Event] = []
    while true {
        let alive = store.controllerRunning(id)
        let tail: ArraySlice<Event>
        if let mark, let i = s.events.lastIndex(where: { $0.at == mark.at && $0.kind == mark.kind && $0.detail == mark.detail }) {
            tail = s.events[(i + 1)...]
        } else {
            tail = s.events[...]
        }
        news = tail.filter(newsworthy)
        let settled = [.paused, .done, .draft].contains(s.status) || ([.running, .waiting].contains(s.status) && !alive)
        if settled || !news.isEmpty || s.status != first.status || Date() >= deadline { break }
        usleep(1_000_000)
        s = try store.load(id)
    }
    let orphaned = [.running, .waiting].contains(s.status) && !store.controllerRunning(id)
    if json {
        var o: [String: Any] = ["run": s.shortId, "status": s.status.rawValue, "controllerRunning": store.controllerRunning(id),
                                "events": news.map { ["at": iso.string(from: $0.at), "kind": $0.kind, "detail": $0.detail] }]
        o["reason"] = s.reason ?? NSNull()
        o["retryAt"] = s.retryAt.map { iso.string(from: $0) } ?? NSNull()
        print(String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    } else {
        for e in news { print("\(iso.string(from: e.at)) \(e.kind): \(e.detail)") }
        print("status: \(s.status.rawValue)\(s.reason.map { " — " + $0 } ?? "")\(orphaned ? " (controller not running — agents loop resume \(s.shortId))" : "")")
    }
}

/// Continue a paused or orphaned run from where it stopped.
func resumeRun(store: Store, id: String, budget: Int?) throws {
    var s = try store.load(id)
    guard !store.controllerRunning(id) else { throw LoopError("run \(s.shortId) is already running") }
    guard s.status != .done else { throw LoopError("run \(s.shortId) is done — its result is on branch \(s.branch)") }
    guard s.status != .draft else { throw LoopError("run \(s.shortId) is a draft — approve it: agents loop approve \(s.shortId)") }
    if let b = budget {
        guard b > s.usedMs else { throw LoopError("the new total must exceed the \(human(s.usedMs)) already used") }
        s.budgetMs = b
    }
    s.status = .running
    s.reason = nil
    s.retryAt = nil
    // A human resuming is the material change: fresh chances for what had stalled.
    s.signatures = s.signatures.filter { !$0.key.hasPrefix("unusable:") && $0.key != "slot-failures" }
    s.log("resumed", "budget \(human(s.budgetMs)), \(human(s.usedMs)) used")
    try store.save(s)
    try launchController(s, store: store)
    print("resumed loop \(s.shortId) — agents loop status \(s.shortId)")
}

func main() throws {
    let a = try parseArgs(Array(CommandLine.arguments.dropFirst()))
    jsonOut = a.json
    let store = Store.standard()
    switch a.command {
    case "start", "plan":
        let cli = try agentsCLI()
        var s = try newRun(a, store: store)
        if let file = a.plan {
            try loadPlanFile(file, into: &s)
            try store.save(s)
        } else {
            say("run \(s.shortId): planning \"\(oneLine(s.plan.goal, 80))\"")
            try planRun(&s, store: store, cli: cli, interview: interactive && !a.json)
        }
        if a.command == "plan" && a.json {
            _ = try writePlanFile(s)
            print(try draftJSON(s))
            return
        }
        if a.command == "plan" {
            print("\n" + describePlan(s, slots: nil))
            let file = try writePlanFile(s)
            print("draft saved. Approve it as is: agents loop approve \(s.shortId)\nor edit \(file) first and: agents loop approve \(s.shortId) --plan \(file)")
            return
        }
        if a.plan != nil && !a.yes && !interactive { throw LoopError("an unattended start needs --yes, after you have reviewed the plan") }
        try confirmOrDraft(&s, store: store, cli: cli, yes: a.yes)
    case "approve":
        let cli = try agentsCLI()
        var s = try store.load(try store.resolve(a.positional.first))
        guard s.status == .draft else { throw LoopError("run \(s.shortId) is \(s.status.rawValue), not a draft") }
        if let file = a.plan { try loadPlanFile(file, into: &s) }
        if let b = a.budget { s.budgetMs = b }
        if let blocker = approvalBlocker(s.questions, run: s.shortId) { throw LoopError("not approved: " + blocker) }
        try confirmOrDraft(&s, store: store, cli: cli, yes: a.yes || !interactive)
    case "answer" where a.positional.count == 2:
        let id = try store.resolve(a.positional[0])
        var s = try store.load(id)
        guard s.status == .paused, !store.controllerRunning(id) else {
            throw LoopError("run \(s.shortId) is \(s.status.rawValue); a decision answers a paused run (a draft's questions take: answer <run> <question> <answer>)")
        }
        let decision = a.positional[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decision.isEmpty else { throw LoopError("the decision is empty") }
        s.decisions = (s.decisions ?? []) + [decision]
        s.log("decided", decision)
        // The decision is the material change: a chunk stopped at the revision cap gets one more try.
        for i in s.plan.chunks.indices where s.plan.chunks[i].status != .accepted && s.plan.chunks[i].revisions >= Limits.maxRevisions {
            s.plan.chunks[i].revisions = Limits.maxRevisions - 1
        }
        try store.save(s)
        try resumeRun(store: store, id: id, budget: a.budget)
    case "waive":
        guard a.positional.count >= 3 else { throw LoopError("usage: agents loop waive <run> <criterion> \"<why>\"") }
        let id = try store.resolve(a.positional[0])
        var s = try store.load(id)
        guard s.status == .paused, !store.controllerRunning(id) else { throw LoopError("run \(s.shortId) is \(s.status.rawValue); only a paused run's criterion can be waived") }
        let criterion = a.positional[1], why = a.positional[2...].joined(separator: " ")
        guard s.plan.criteria.contains(where: { $0.id == criterion }) else {
            throw LoopError("run \(s.shortId) has no criterion \"\(criterion)\" (it has: \(s.plan.criteria.map(\.id).joined(separator: ", ")))")
        }
        s.waived = (s.waived ?? [:]).merging([criterion: why]) { $1 }
        s.log("waived", "\(criterion): \(why)")
        try store.save(s)
        try resumeRun(store: store, id: id, budget: a.budget)
    case "answer":
        guard a.positional.count >= 3 else { throw LoopError("usage: agents loop answer <run> <question> <answer>, or for a paused run: agents loop answer <run> \"<decision>\"") }
        var s = try store.load(try store.resolve(a.positional[0]))
        guard s.status == .draft else { throw LoopError("run \(s.shortId) is \(s.status.rawValue), not a draft") }
        guard let i = s.questions.firstIndex(where: { $0.id == a.positional[1] }) else {
            throw LoopError("run \(s.shortId) has no question \"\(a.positional[1])\" (it has: \(s.questions.map(\.id).joined(separator: ", ")))")
        }
        let reply = a.positional[2...].joined(separator: " ")
        let q = s.questions[i]
        // A number picks an option, as in the interactive interview.
        s.questions[i].answer = Int(reply).flatMap { $0 >= 1 && $0 <= q.options.count ? q.options[$0 - 1].label : nil } ?? reply
        s.log("answered", "\(q.id): \(s.questions[i].answer!)")
        try store.save(s)
        if a.json { print(try draftJSON(s)) }
        else { print(approvalBlocker(s.questions, run: s.shortId) ?? "ready to approve: agents loop approve \(s.shortId)") }
    case "replan":
        let cli = try agentsCLI()
        var s = try store.load(try store.resolve(a.positional.first))
        guard s.status == .draft else { throw LoopError("run \(s.shortId) is \(s.status.rawValue), not a draft") }
        say("run \(s.shortId): planning again with your answers")
        try planRun(&s, store: store, cli: cli, interview: false)
        _ = try writePlanFile(s)
        if a.json { print(try draftJSON(s)) }
        else { print("\n" + describePlan(s, slots: nil)); print(approvalBlocker(s.questions, run: s.shortId) ?? "ready to approve: agents loop approve \(s.shortId)") }
    case "status":
        let s = try store.load(try store.resolve(a.positional.first))
        if a.json { print(String(decoding: try Store.encoder.encode(s), as: UTF8.self)) }
        else { print(describeRun(s, controllerAlive: store.controllerRunning(s.id)), terminator: "") }
    case "wait":
        try waitForNews(store: store, id: try store.resolve(a.positional.first), timeoutMs: a.timeout ?? 30 * 60_000, json: a.json)
    case "list":
        print(listRuns(store))
    case "pause":
        let id = try store.resolve(a.positional.first)
        var s = try store.load(id)
        let unfinishedDraft = s.status == .draft && s.turns.contains { $0.endedAt == nil }
        guard [.running, .waiting].contains(s.status) || unfinishedDraft else { throw LoopError("run \(s.shortId) is \(s.status.rawValue)") }
        if store.controllerRunning(id) {
            FileManager.default.createFile(atPath: store.pauseFile(id), contents: nil)
            print("pausing \(s.shortId): stopping running turns; their work stays in the worktrees…")
            while store.controllerRunning(id) { usleep(200_000) }
        } else {
            recoverTurnProcesses(&s.turns, runId: s.id, store: store)
            if unfinishedDraft {
                s.reason = "planning stopped; the draft still needs a valid plan and approval"
                s.log("planning-stopped", s.reason!)
            } else {
                s.pause("paused by you — resume with: agents loop resume \(s.shortId)")
            }
            try store.save(s)
        }
        print(describeRun(try store.load(id), controllerAlive: false), terminator: "")
    case "resume":
        _ = try agentsCLI()
        try resumeRun(store: store, id: try store.resolve(a.positional.first), budget: a.budget)
    case "log":
        let id = try store.resolve(a.positional.first)
        let log = store.controllerLog(id)
        if a.follow {
            let cArgs: [UnsafeMutablePointer<CChar>?] = ["/usr/bin/tail", "-n", "40", "-f", log].map { value in
                value.withCString { strdup($0) }
            }
            let args = cArgs + [nil]
            execv("/usr/bin/tail", args)
            throw LoopError("could not run tail")
        }
        print((try? String(contentsOfFile: log, encoding: .utf8)) ?? "(no log yet)", terminator: "")
    case "_controller":
        let cli = try agentsCLI()
        guard let id = a.positional.first else { throw LoopError("_controller needs a run id") }
        do {
            try Controller(store: store, id: id, cli: cli).run()
        } catch {
            // Never leave a run that looks alive with nobody driving it.
            if var s = try? store.load(id), !store.controllerRunning(id), s.status != .done {
                s.pause("controller stopped: \(error)")
                try? store.save(s)
            }
            throw error
        }
    default:
        throw LoopError("unknown command \(a.command)")
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write("agents loop: \(error)\n".data(using: .utf8)!)
    exit(1)
}
