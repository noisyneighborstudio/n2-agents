import Darwin
import Foundation

let usage = """
agents loop — fan a goal out across your slots until its definition of done holds.

  agents loop "goal" --budget 2h [--file spec.md]…   plan, interview, approve, start
  agents loop plan "goal" --budget 2h                plan and interview; approve later
  agents loop approve <run> [--plan edited.json]     approve a drafted plan and start
  agents loop start --plan plan.json --budget 2h --yes   start a reviewed plan unattended
  agents loop status [run] [--json]                  where it stands, what done means
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
}

func parseArgs(_ argv: [String]) throws -> Args {
    var a = Args()
    let commands: Set = ["start", "plan", "approve", "status", "list", "pause", "resume", "log", "_controller"]
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
    for attempt in 1...4 {
        guard let slot = pick(try source.slots(), effort: .deep, cooldowns: s.cooldowns, busy: [:], avoidSlots: avoid) else {
            throw LoopError("no signed-in slot with quota left to plan with (see: agents list, agents best)")
        }
        print("planning with \(slot.key)…")
        let id = "\(s.turns.count + 1)-planner"
        s.turns.append(Turn(id: id, role: .planner, chunk: nil, slot: slot.key, effort: .deep, startedAt: Date()))
        try Store.standard().save(s)
        let out = try runTurn(TurnRequest(cli: cli, slot: slot, effort: .deep, cwd: cwd,
                                          prompt: plannerPrompt(goal: s.plan.goal, sources: s.sources, answers: s.questions,
                                                                budgetMs: s.budgetMs, errors: errors),
                                          files: Store.standard().turnFiles(s.id, id), timeout: Limits.review, detach: false),
                              abort: Flag())
        s.usedMs += Int(out.seconds * 1000)
        let i = s.turns.count - 1
        s.turns[i].endedAt = Date()
        if out.exit == 0, let report = parseReport(out.stdout) {
            s.turns[i].outcome = "ok"
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
        avoid.insert(slot.key)
        print("  \(slot.key) \(out.exit == 0 ? "returned no plan" : "failed: " + oneLine(out.tail, 160))\(attempt < 4 ? " — trying another slot" : "")")
    }
    throw LoopError("four planner turns failed; see \(Store.standard().dir(s.id))/turns")
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
            s.questions = questions.map { var q = $0; q.answer = answered[q.question]; return q }
            return
        }
        errors = problems
        print("  the plan had \(problems.count) problem(s); asking for a corrected one")
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
        print("note: uncommitted changes in \(root) are not part of the run — it starts from \(base.prefix(10))")
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
func planRun(_ s: inout RunState, store: Store, cli: String) throws {
    let dir = store.dir(s.id) + "/plan"
    _ = try gitOrThrow(s.repo, ["worktree", "add", "--detach", dir, s.baseCommit])
    defer { _ = git(s.repo, "worktree", "remove", "--force", dir) }
    let source = SlotSource(cli: cli)
    try draft(&s, cli: cli, source: source, cwd: dir)
    try store.save(s)
    if interactive, interview(&s) {
        print("\nre-planning with your answers…")
        try draft(&s, cli: cli, source: source, cwd: dir)
    }
    try store.save(s)
}

func approveAndStart(_ s: inout RunState, store: Store, cli: String) throws {
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
    let source = SlotSource(cli: cli)
    print("\n" + describePlan(s, slots: try? source.slots()))
    if yes || (interactive && ask("Approve and start? [y/N] ").lowercased().hasPrefix("y")) {
        try approveAndStart(&s, store: store, cli: cli)
    } else {
        let file = try writePlanFile(s)
        print("saved as a draft. To change it, edit \(file); then: agents loop approve \(s.shortId) --plan \(file)")
    }
}

func main() throws {
    let a = try parseArgs(Array(CommandLine.arguments.dropFirst()))
    let store = Store.standard()
    switch a.command {
    case "start", "plan":
        let cli = try agentsCLI()
        var s = try newRun(a, store: store)
        if let file = a.plan {
            try loadPlanFile(file, into: &s)
            try store.save(s)
        } else {
            print("run \(s.shortId): planning \"\(oneLine(s.plan.goal, 80))\"")
            try planRun(&s, store: store, cli: cli)
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
        try confirmOrDraft(&s, store: store, cli: cli, yes: a.yes || !interactive)
    case "status":
        let s = try store.load(try store.resolve(a.positional.first))
        if a.json { print(String(decoding: try Store.encoder.encode(s), as: UTF8.self)) }
        else { print(describeRun(s, controllerAlive: store.controllerRunning(s.id)), terminator: "") }
    case "list":
        print(listRuns(store))
    case "pause":
        let id = try store.resolve(a.positional.first)
        var s = try store.load(id)
        guard [.running, .waiting].contains(s.status) else { throw LoopError("run \(s.shortId) is \(s.status.rawValue)") }
        if store.controllerRunning(id) {
            FileManager.default.createFile(atPath: store.pauseFile(id), contents: nil)
            print("pausing \(s.shortId): stopping running turns; their work stays in the worktrees…")
            while store.controllerRunning(id) { usleep(200_000) }
        } else {
            s.pause("paused by you — resume with: agents loop resume \(s.shortId)")
            try store.save(s)
        }
        print(describeRun(try store.load(id), controllerAlive: false), terminator: "")
    case "resume":
        let cli = try agentsCLI()
        _ = cli
        let id = try store.resolve(a.positional.first)
        var s = try store.load(id)
        guard !store.controllerRunning(id) else { throw LoopError("run \(s.shortId) is already running") }
        guard s.status != .done else { throw LoopError("run \(s.shortId) is done — its result is on branch \(s.branch)") }
        guard s.status != .draft else { throw LoopError("run \(s.shortId) is a draft — approve it: agents loop approve \(s.shortId)") }
        if let b = a.budget {
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
    case "log":
        let id = try store.resolve(a.positional.first)
        let log = store.controllerLog(id)
        if a.follow {
            let args = ["/usr/bin/tail", "-n", "40", "-f", log].map { strdup($0) } + [nil]
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
