import Darwin
import Foundation

/// Turn limits. A worker turn is one focused session; everything the plan
/// needs beyond that happens over several turns.
enum Limits {
    /// Scales every limit below; tests shrink it.
    static let scale = Double(ProcessInfo.processInfo.environment["N2_LOOP_TIME_SCALE"] ?? "") ?? 1
    static let worker: TimeInterval = 20 * 60 * scale
    static let review: TimeInterval = 10 * 60 * scale
    static let verifier: TimeInterval = 20 * 60 * scale
    static let command: TimeInterval = 30 * 60 * scale
    static let maxRevisions = 3        // supervisor rejections before a human decides
    static let maxStrategies = 2       // stall diagnoses per chunk before a human decides
    static let maxStalls = 2           // worker turns with no change before a diagnosis
    static let maxSlotFailures = 6     // failed turns in a row, across slots, before pausing
    static let maxRepeats = 3          // the same failure, or unusable answers for one decision, before pausing
}

/// Work in flight, off the main thread. Only the main thread touches state.
private final class Job {
    let turn: String
    let chunk: String?
    let slot: String?
    let abort = Flag()
    init(turn: String, chunk: String?, slot: String?) { self.turn = turn; self.chunk = chunk; self.slot = slot }
}

private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [() -> Void] = []
    func post(_ f: @escaping () -> Void) { lock.lock(); items.append(f); lock.unlock() }
    func drain() -> [() -> Void] { lock.lock(); defer { items = []; lock.unlock() }; return items }
}

final class Controller {
    let store: Store
    let cli: String
    var s: RunState
    private let slots: SlotSource
    private var jobs: [String: Job] = [:]
    private let inbox = Inbox()
    private var stopping = false
    private let dir: String

    init(store: Store, id: String, cli: String) throws {
        self.store = store
        self.cli = cli
        self.s = try store.load(id)
        self.slots = SlotSource(cli: cli)
        self.dir = store.dir(id)
    }

    private func note(_ kind: String, _ detail: String) {
        s.log(kind, detail)
        print("[\(iso.string(from: Date()))] \(kind): \(detail)")
        fflush(stdout)
    }

    private func save() { try? store.save(s) }

    // MARK: - lifecycle

    func run() throws {
        guard let lock = store.lock(s.id) else { throw LoopError("run \(s.shortId) already has a controller") }
        defer { flock(lock, LOCK_UN); close(lock) }
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler { [inbox] in inbox.post { self.requestStop() } }
        term.resume()
        if s.keepAwake { _ = try? spawnDetached(["/usr/bin/caffeinate", "-i", "-w", "\(getpid())"], log: "/dev/null") }

        try reconcile()
        s.status = .running
        s.reason = nil
        note("controller", "started (pid \(getpid()))")
        save()

        while true {
            for f in inbox.drain() { f() }
            if FileManager.default.fileExists(atPath: store.pauseFile(s.id)) { requestStop() }
            if stopping {
                if jobs.isEmpty {
                    try? FileManager.default.removeItem(atPath: store.pauseFile(s.id))
                    if s.status != .done { s.pause("paused by you — resume with: agents loop resume \(s.shortId)") }
                    save()
                    return
                }
            } else if s.status == .done || s.status == .paused {
                if jobs.isEmpty { save(); return }
                for j in jobs.values { j.abort.set() }
            } else {
                tick()
            }
            save()
            usleep(500_000)
        }
    }

    private func requestStop() {
        guard !stopping else { return }
        stopping = true
        note("pause", jobs.isEmpty ? "pausing" : "pausing: stopping \(jobs.count) running turn(s); their work is kept")
        for j in jobs.values { j.abort.set() }
    }

    /// After a crash or a pause: nothing the record says is running may still
    /// be running, and nothing half-done may be lost.
    private func reconcile() throws {
        guard FileManager.default.fileExists(atPath: s.repo) else { throw LoopError("the repository \(s.repo) is gone") }
        let integration = dir + "/integration"
        if !FileManager.default.fileExists(atPath: integration) {
            _ = try gitOrThrow(s.repo, ["worktree", "add", integration, s.branch])
        }
        for i in s.turns.indices where s.turns[i].endedAt == nil {
            if let g = s.turns[i].pgid, kill(-g, 0) == 0 { stop(group: g) }
            s.turns[i].endedAt = Date()
            s.turns[i].outcome = "interrupted"
        }
        for i in s.plan.chunks.indices where s.plan.chunks[i].status == .working {
            s.plan.chunks[i].status = .pending
        }
    }

    // MARK: - scheduling

    private var busy: [String: Int] {
        jobs.values.compactMap(\.slot).reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private var remainingMs: Int {
        let live = s.turns.filter { $0.endedAt == nil }.reduce(0) { $0 + Int(Date().timeIntervalSince($1.startedAt) * 1000) }
        return s.budgetMs - s.usedMs - live
    }

    /// What the last stretch of the budget is kept for: checking the result.
    private var reserveMs: Int { min(30 * 60_000, s.budgetMs / 4) }

    private func tick() {
        if s.status == .waiting {
            guard let at = s.retryAt, Date() >= at else { return }
            s.status = .running
            s.retryAt = nil
            note("capacity", "retrying now")
        }
        let chunkJobs = Set(jobs.values.compactMap(\.chunk))
        var started = false, starved = false

        func room() -> Bool { jobs.count < s.concurrency }

        for c in s.plan.chunks where room() && c.problem != nil && !chunkJobs.contains(c.id) {
            guard remainingMs > 0 else { break }
            if startTurn(.supervisor, chunk: c.id, effort: .deep, avoid: c.lastSlot) { started = true } else { starved = true }
        }
        for c in s.plan.chunks where room() && c.problem == nil && c.status == .reviewing && !chunkJobs.contains(c.id) {
            guard remainingMs > 0 else { break }
            if startTurn(.supervisor, chunk: c.id, effort: .deep, avoid: c.lastSlot) { started = true } else { starved = true }
        }
        var working = s.plan.chunks.filter { $0.status == .working || chunkJobs.contains($0.id) }
        for c in s.plan.chunks where room() && c.problem == nil && c.status == .pending && !chunkJobs.contains(c.id) {
            guard remainingMs > reserveMs else { break }
            let depsMerged = c.dependsOn.allSatisfy { s.chunk($0)?.status == .accepted }
            let clear = !working.contains { pathsOverlap($0.paths, c.paths) }
            guard depsMerged && clear else { continue }
            if startWorker(c.id) { started = true; working.append(c) } else { starved = true }
        }
        if jobs.isEmpty && !started && s.plan.chunks.allSatisfy({ $0.status == .accepted }) && s.status == .running {
            guard remainingMs > 0 else { return outOfBudget() }
            started = verifyStage()
            if !started { starved = true }
        }
        guard jobs.isEmpty, !started, s.status == .running else { return }
        if starved { return waitForCapacity() }
        let open = s.plan.chunks.filter { $0.status != .accepted }
        if !open.isEmpty && remainingMs <= reserveMs { return outOfBudget() }
        s.pause("nothing can run: \(open.map { "\($0.id) [\($0.status.rawValue)]" }.joined(separator: ", ")) — inspect with agents loop status")
    }

    private func outOfBudget() {
        s.pause("budget reached (\(human(s.usedMs)) of \(human(s.budgetMs)); the rest is kept for verification) — resume with: agents loop resume \(s.shortId) --budget <new total>")
    }

    /// Nothing usable right now. Wait for the earliest cooldown if there is
    /// one; otherwise a human has to sign something in.
    private func waitForCapacity() {
        let all = (try? slots.slots(fresh: true)) ?? []
        let next = (all.compactMap { s.cooldowns[$0.key]?.until } + all.compactMap(\.resets)).filter { $0 > Date() }.min()
        if let next {
            s.status = .waiting
            s.retryAt = next
            note("capacity", "every usable slot is out of quota or cooling down; retrying at \(iso.string(from: next))")
        } else {
            s.pause("no signed-in slot with quota left (see: agents list, agents best)")
        }
    }

    // MARK: - turns

    private func chooseSlot(_ effort: Effort, avoid: String?) -> Slot? {
        guard let all = try? slots.slots() else { return nil }
        let vendors: Set<String> = avoid.map { [String($0.split(separator: "|")[0])] } ?? []
        return pick(all, effort: effort, cooldowns: s.cooldowns, busy: busy, avoidVendors: vendors)
    }

    private func newTurn(_ role: Role, chunk: String?, slot: Slot, effort: Effort) -> Turn {
        let id = "\(s.turns.count + 1)-\(role.rawValue)\(chunk.map { "-" + $0 } ?? "")"
        let t = Turn(id: id, role: role, chunk: chunk, slot: slot.key, effort: effort, startedAt: Date())
        s.turns.append(t)
        return t
    }

    /// Launch an agent turn in the background; `done` runs on the main thread.
    private func launch(_ role: Role, chunk: String?, slot: Slot, effort: Effort, cwd: String, prompt: String,
                        timeout: TimeInterval, done: @escaping (Turn, TurnOutput) -> Void) {
        let turn = newTurn(role, chunk: chunk, slot: slot, effort: effort)
        let job = Job(turn: turn.id, chunk: chunk, slot: slot.key)
        jobs[turn.id] = job
        note(role.rawValue, "\(turn.id) → \(slot.key) [\(effort.rawValue)]")
        // No single turn may spend past the budget.
        let capped = min(timeout, max(60, Double(remainingMs) / 1000))
        let req = TurnRequest(cli: cli, slot: slot, effort: effort, cwd: cwd, prompt: prompt,
                              files: store.turnFiles(s.id, turn.id), timeout: capped, detach: true)
        let inbox = self.inbox
        DispatchQueue.global().async {
            let out: TurnOutput
            do {
                out = try runTurn(req, abort: job.abort) { pid in
                    inbox.post {
                        guard let i = self.s.turns.firstIndex(where: { $0.id == turn.id }) else { return }
                        self.s.turns[i].pgid = pid
                        self.save()
                    }
                }
            } catch {
                out = TurnOutput(exit: 127, timedOut: false, aborted: false, stdout: "", stderr: "\(error)", seconds: 0)
            }
            inbox.post {
                self.jobs[turn.id] = nil
                let t = self.settle(turn.id, out)
                done(t, out)
                self.save()
            }
        }
    }

    /// Book the turn's time and outcome. Slot trouble — quota, sign-in, an
    /// outage — cools that slot down and is never held against the work.
    private func settle(_ id: String, _ out: TurnOutput) -> Turn {
        let i = s.turns.firstIndex { $0.id == id }!
        s.turns[i].endedAt = Date()
        s.usedMs += Int(out.seconds * 1000)
        let slot = s.turns[i].slot
        var outcome = "ok"
        if out.aborted { outcome = "interrupted" }
        else if out.timedOut {
            outcome = "timeout"
            // A worker may simply have a big chunk; a reviewer that hangs is the slot's trouble.
            if s.turns[i].role != .worker { s.cooldowns[slot] = Cooldown(until: Date().addingTimeInterval(600), reason: "timed out") }
        }
        else if out.exit != 0 {
            let (o, cooldown) = slotTrouble(slot, out.tail)
            outcome = o
            s.cooldowns[slot] = cooldown
        } else if parseReport(out.stdout) == nil {
            outcome = "invalid"
            s.cooldowns[slot] = Cooldown(until: Date().addingTimeInterval(600), reason: "returned no usable report")
        }
        s.turns[i].outcome = outcome
        recordUsageOutcome(cli: cli, slot: slot, outcome: outcome, task: "\(s.id)/\(id)", effort: s.turns[i].effort, usage: out.usage)
        if outcome != "ok" { s.turns[i].note = oneLine(out.tail, 300) }

        // Only failures the loop can't account for trip the breaker. Quota and
        // "needs you" already set the slot aside until a known time, and running
        // dry has to end in WAITING, not in a pause nobody resumes.
        let troubled = ["auth", "outage", "failed"].contains(outcome)
        s.signatures["slot-failures"] = troubled ? (s.signatures["slot-failures"] ?? 0) + 1 : (outcome == "ok" ? 0 : s.signatures["slot-failures"])
        note(s.turns[i].role.rawValue, "\(id) \(outcome) after \(Int(out.seconds))s\(outcome == "ok" ? "" : ": " + oneLine(out.tail, 160))")
        if (s.signatures["slot-failures"] ?? 0) >= Limits.maxSlotFailures {
            s.pause("\(Limits.maxSlotFailures) turns in a row failed to run; last: \(oneLine(out.tail, 200))")
        }
        return s.turns[i]
    }

    private func report(_ t: Turn, _ out: TurnOutput) -> [String: Any]? { t.outcome == "ok" ? parseReport(out.stdout) : nil }

    /// A decision turn gave nothing usable. The work waits for another slot,
    /// but the same decision failing again and again stops the run.
    private func unusable(_ t: Turn, _ what: String) {
        guard ["ok", "invalid", "timeout"].contains(t.outcome ?? "") else { return }  // slot trouble isn't the question's fault
        let key = "unusable:\(what)"
        s.signatures[key, default: 0] += 1
        if s.signatures[key]! >= Limits.maxRepeats {
            s.pause("\(s.signatures[key]!) turns in a row gave no usable answer for \(what); last: \(t.note ?? t.outcome ?? "")")
        }
    }

    // MARK: - workers

    private func startWorker(_ id: String) -> Bool {
        guard var c = s.chunk(id), let slot = chooseSlot(c.effort, avoid: nil) else { return false }
        let resume = c.workspace != nil
        if c.workspace == nil {
            let path = dir + "/work/" + c.id, branch = "n2/\(s.shortId)/\(c.id)"
            let base = s.lastMerge ?? s.baseCommit
            _ = git(s.repo, "worktree", "remove", "--force", path)
            _ = git(s.repo, "branch", "-D", branch)
            let r = git(s.repo, "worktree", "add", "-b", branch, path, base)
            guard r.ok else { s.pause("could not create a worktree for \(c.id): \(r.said)"); return false }
            c.workspace = path; c.branch = branch; c.base = base
        }
        c.status = .working
        c.turns += 1
        c.lastSlot = slot.key
        s.update(id) { $0 = c }
        let merged = s.plan.chunks.filter { $0.status == .accepted }
        launch(.worker, chunk: id, slot: slot, effort: c.effort, cwd: c.workspace!,
               prompt: workerPrompt(s, c, merged: merged, resume: resume), timeout: Limits.worker) { t, out in
            self.workerDone(id, t, out)
        }
        return true
    }

    private func workerDone(_ id: String, _ t: Turn, _ out: TurnOutput) {
        guard var c = s.chunk(id) else { return }
        c.status = .pending
        defer { s.update(id) { $0 = c } }
        switch t.outcome {
        case "interrupted", "quota", "attention", "auth", "outage", "failed": return   // the slot's problem; the work waits for another
        default: break
        }
        let r = report(t, out)
        let status = str(r?["status"]) ?? (t.outcome == "timeout" ? "progress" : "invalid")
        c.summary = str(r?["summary"]) ?? (t.outcome == "timeout" ? "the turn ran out of time mid-work" : "no usable report")
        switch status {
        case "done":
            guard let ws = c.workspace else { return }
            _ = git(ws, "add", "-A")
            let staged = git(ws, "diff", "--cached", "--quiet")
            let merging = FileManager.default.fileExists(atPath: (try? gitOrThrow(ws, ["rev-parse", "--git-path", "MERGE_HEAD"])).map { $0.hasPrefix("/") ? $0 : ws + "/" + $0 } ?? "")
            if !staged.ok || merging {
                let commit = git(ws, "commit", "--no-edit", "-m", "loop \(s.shortId): \(c.id) — \(c.title)")
                if !commit.ok {
                    c.revisions += 1
                    c.feedback = "The commit was rejected, most likely by the repository's hooks. Make it pass; never bypass hooks:\n\(clip(commit.said, 4000))"
                    note("commit", "\(c.id): rejected — sent back to the worker")
                    if c.revisions > Limits.maxRevisions { c.problem = "commits keep being rejected: \(oneLine(commit.said, 300))" }
                    return
                }
            }
            c.stalls = 0
            c.fingerprint = nil
            c.status = .reviewing
            note("worker", "\(c.id) done — waiting for the supervisor")
        case "blocked":
            c.problem = "the worker is blocked: " + (str(r?["blocker"]) ?? c.summary ?? "no reason given")
        default:
            let fp = c.workspace.map(fingerprint) ?? ""
            c.stalls = fp == c.fingerprint ? c.stalls + 1 : 0
            c.fingerprint = fp
            if c.stalls >= Limits.maxStalls { c.problem = "\(c.stalls) turns in a row changed nothing (last: \(c.summary ?? ""))" }
        }
    }

    // MARK: - supervisor

    private func startTurn(_ role: Role, chunk id: String, effort: Effort, avoid: String?) -> Bool {
        guard let c = s.chunk(id), let ws = c.workspace, let slot = chooseSlot(effort, avoid: avoid) else { return false }
        if let problem = c.problem {
            launch(.supervisor, chunk: id, slot: slot, effort: effort, cwd: ws,
                   prompt: diagnosePrompt(s, c, problem: problem), timeout: Limits.review) { t, out in
                self.diagnosed(id, t, out)
            }
            return true
        }
        let base = c.base ?? s.baseCommit
        let files = changedFiles(ws, since: base)
        let outside = files.filter { !inPaths($0, c.paths) }
        let diff = clip(git(ws, "diff", "--stat", base, "HEAD").out + "\n" + git(ws, "diff", base, "HEAD").out, 60_000)
        launch(.supervisor, chunk: id, slot: slot, effort: effort, cwd: ws,
               prompt: reviewPrompt(s, c, diff: diff, outside: outside), timeout: Limits.review) { t, out in
            self.reviewed(id, t, out)
        }
        return true
    }

    /// A read-only role left edits behind: throw them away, and its verdict too.
    private func readOnlyViolated(_ cwd: String) -> Bool {
        guard !trackedChanges(cwd).isEmpty else { return false }
        _ = git(cwd, "reset", "--hard", "HEAD")
        return true
    }

    private func reviewed(_ id: String, _ t: Turn, _ out: TurnOutput) {
        guard var c = s.chunk(id), let ws = c.workspace else { return }
        defer { s.update(id) { $0 = c } }
        if readOnlyViolated(ws) { note("supervisor", "\(t.id) edited files during review; verdict discarded"); return unusable(t, "the review of \(id)") }
        guard let r = report(t, out), let decision = str(r["decision"]) else { return unusable(t, "the review of \(id)") }
        let feedback = str(r["feedback"]) ?? str(r["summary"]) ?? ""
        switch decision {
        case "accept":
            merge(&c, reason: str(r["summary"]) ?? "accepted")
        case "revise":
            c.revisions += 1
            c.feedback = feedback
            c.status = .pending
            note("supervisor", "\(c.id): revise — \(oneLine(feedback))")
            if c.revisions > Limits.maxRevisions {
                s.pause("the supervisor rejected \(c.id) \(c.revisions) times; last: \(oneLine(feedback, 300))")
            }
        case "pause":
            s.pause("supervisor on \(c.id): \(feedback)")
        default:
            note("supervisor", "\(t.id) returned an unknown decision \"\(decision)\"")
            unusable(t, "the review of \(id)")
        }
    }

    /// Merge an accepted chunk into the run branch. A conflict goes back to
    /// the chunk's worker with the conflict already in its worktree.
    private func merge(_ c: inout Chunk, reason: String) {
        guard let branch = c.branch, let ws = c.workspace else { return }
        let integration = dir + "/integration"
        let m = git(integration, "merge", "--no-ff", "--no-edit", "-m", "loop \(s.shortId): merge \(c.id) — \(c.title)", branch)
        if m.ok {
            s.lastMerge = try? head(integration)
            c.status = .accepted
            c.mergedAs = s.lastMerge
            c.feedback = nil
            note("merge", "\(c.id) accepted and merged (\(String(s.lastMerge?.prefix(10) ?? ""))): \(oneLine(reason))")
            return
        }
        _ = git(integration, "merge", "--abort")
        let into = git(ws, "merge", "--no-edit", s.branch)
        if into.ok {
            // It merged cleanly the other way round; the supervisor looks again at the result.
            c.status = .reviewing
            note("merge", "\(c.id) needed the latest run branch; merged it in for another review")
            return
        }
        let conflicted = git(ws, "diff", "--name-only", "--diff-filter=U").out.split(separator: "\n").joined(separator: ", ")
        c.status = .pending
        c.revisions += 1
        c.feedback = "Work merged since you started conflicts with yours in: \(conflicted). The conflict markers are in your worktree — resolve them keeping the intent of both sides, then finish the chunk."
        note("merge", "\(c.id) conflicts with merged work (\(conflicted)); back to a worker")
    }

    private func diagnosed(_ id: String, _ t: Turn, _ out: TurnOutput) {
        guard var c = s.chunk(id) else { return }
        defer { s.update(id) { $0 = c } }
        if let ws = c.workspace, readOnlyViolated(ws) { return unusable(t, "the diagnosis of \(id)") }
        guard let r = report(t, out), let decision = str(r["decision"]) else { return unusable(t, "the diagnosis of \(id)") }
        let strategy = str(r["strategy"])
        switch decision {
        case "retry", "amend":
            if decision == "retry" {
                guard let strategy, !c.strategies.contains(strategy) else {
                    s.pause("\(c.id) is stuck (\(c.problem ?? "")) and the supervisor has no new approach"); return
                }
            }
            if c.strategies.count >= Limits.maxStrategies {
                s.pause("\(c.id) stalled again after \(c.strategies.count) new approaches: \(c.problem ?? "")"); return
            }
            if decision == "amend" {
                var errors: [String] = []
                let ids = Set(s.plan.criteria.map(\.id))
                let added = ((r["chunks"] as? [Any]) ?? []).compactMap { parseChunk($0, criteria: ids, errors: &errors) }
                let clash = added.filter { a in s.plan.chunks.contains { $0.id == a.id } }.map(\.id)
                errors += clash.map { "chunk \"\($0)\" already exists" }
                errors += dependencyProblems(s.plan.chunks + added)
                guard errors.isEmpty else { s.pause("the supervisor's amendment for \(c.id) is invalid: \(errors.joined(separator: "; "))"); return }
                s.plan.chunks += added
                c.paths += strings(r["paths"]).filter { !c.paths.contains($0) }
                note("supervisor", "amended the plan for \(c.id): +\(added.map(\.id).joined(separator: ", ")) paths \(c.paths.joined(separator: ", "))")
            }
            c.strategies.append(strategy ?? "amended the plan")
            c.feedback = strategy.map { "New approach from the supervisor: \($0)" } ?? c.feedback
            c.problem = nil
            c.stalls = 0
            c.status = c.status == .reviewing ? .reviewing : .pending
            note("supervisor", "\(c.id): \(decision) — \(oneLine(strategy ?? ""))")
        case "pause":
            s.pause("\(c.id) needs you: \(str(r["question"]) ?? strategy ?? c.problem ?? "")")
        default:
            note("supervisor", "\(t.id) returned an unknown decision \"\(decision)\"")
            unusable(t, "the diagnosis of \(id)")
        }
    }

    // MARK: - verification: the definition of done

    /// Commands, then a fresh verifier, then the supervisor's sign-off — all on
    /// one exact commit. Returns whether it started something.
    private func verifyStage() -> Bool {
        guard let candidate = s.lastMerge ?? (s.plan.chunks.isEmpty ? nil : s.baseCommit) else { return false }
        let path = dir + "/verify/" + String(candidate.prefix(12))
        if !FileManager.default.fileExists(atPath: path) {
            let r = git(s.repo, "worktree", "add", "--detach", path, candidate)
            guard r.ok else { s.pause("could not check out \(candidate) for verification: \(r.said)"); return true }
        }
        let results = s.commands.filter { $0.candidate == candidate }
        let failedCommand = results.contains { $0.exitCode != 0 }
        if !failedCommand, let next = s.plan.verificationCommands.first(where: { cmd in !results.contains { $0.command == cmd } }) {
            runCommand(next, candidate: candidate, cwd: path)
            return true
        }
        let evidence = s.evidence(for: candidate)
        if s.plan.criteria.contains(where: { evidence[$0.id] == nil }) {
            // Independence from the labs whose work was merged, not from ones that merely failed to start.
            let workers = Set(s.plan.chunks.compactMap { $0.lastSlot?.split(separator: "|").first.map(String.init) })
            guard let all = try? slots.slots(),
                  let slot = pick(all, effort: .deep, cooldowns: s.cooldowns, busy: busy, avoidVendors: workers) else { return false }
            launch(.verifier, chunk: nil, slot: slot, effort: .deep, cwd: path,
                   prompt: verifierPrompt(s, candidate: candidate, results: results), timeout: Limits.verifier) { t, out in
                self.verified(candidate, path, t, out)
            }
            return true
        }
        guard let slot = chooseSlot(.deep, avoid: nil) else { return false }
        launch(.supervisor, chunk: nil, slot: slot, effort: .deep, cwd: path,
               prompt: signoffPrompt(s, candidate: candidate, evidence: Array(evidence.values).sorted { $0.criterion < $1.criterion }, results: results),
               timeout: Limits.review) { t, out in
            self.signedOff(candidate, path, t, out)
        }
        return true
    }

    private func runCommand(_ command: String, candidate: String, cwd: String) {
        let id = "\(s.turns.count + 1)-command"
        let job = Job(turn: id, chunk: nil, slot: nil)
        jobs[id] = job
        note("verify", "$ \(command)")
        let files = store.turnFiles(s.id, id)
        let inbox = self.inbox
        DispatchQueue.global().async {
            let started = Date()
            let result = (try? spawnAndWait(["/bin/sh", "-c", command], cwd: cwd, stdin: "/dev/null", stdout: files + ".out",
                                            stderr: files + ".out.err", timeout: Limits.command, detach: true, abort: job.abort))
            let text = ((try? String(contentsOfFile: files + ".out", encoding: .utf8)) ?? "") + ((try? String(contentsOfFile: files + ".out.err", encoding: .utf8)) ?? "")
            inbox.post {
                self.jobs[id] = nil
                guard let (exit, timedOut, aborted) = result, !aborted else { return }   // paused: runs again on resume
                let code: Int32 = timedOut ? 124 : exit
                self.s.commands.append(CommandResult(command: command, exitCode: code, tail: String(text.suffix(4000)),
                                                     candidate: candidate, seconds: Date().timeIntervalSince(started)))
                self.note("verify", "\(command) → exit \(code)\(timedOut ? " (timed out)" : "")")
            }
        }
    }

    private func verified(_ candidate: String, _ cwd: String, _ t: Turn, _ out: TurnOutput) {
        if readOnlyViolated(cwd) { note("verifier", "\(t.id) edited the candidate; verdict discarded"); return unusable(t, "verification") }
        guard let r = report(t, out) else { return unusable(t, "verification") }
        let given = (r["criteria"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let ids = given.compactMap { str($0["id"]) }
        let expected = s.plan.criteria.map(\.id)
        guard str(r["candidate"]).map({ candidate.hasPrefix($0) || $0.hasPrefix(candidate) }) ?? true,
              Set(ids) == Set(expected), ids.count == expected.count else {
            note("verifier", "\(t.id) didn't return exactly one verdict per criterion; asking another verifier")
            return unusable(t, "verification")
        }
        for g in given {
            s.evidence.append(Evidence(criterion: str(g["id"])!, passed: g["passed"] as? Bool ?? false,
                                       detail: str(g["evidence"]) ?? "", candidate: candidate, turn: t.id))
        }
        let failing = given.filter { ($0["passed"] as? Bool) != true }.compactMap { str($0["id"]) }.sorted()
        let failedCommands = s.commands.filter { $0.candidate == candidate && $0.exitCode != 0 }.map(\.command)
        note("verifier", failing.isEmpty && failedCommands.isEmpty ? "every criterion passed on \(candidate.prefix(10))"
                                                                  : "failing: \((failing + failedCommands).joined(separator: ", "))")
        if !failing.isEmpty || !failedCommands.isEmpty {
            let key = "verify:" + (failing + failedCommands).joined(separator: "|")
            s.signatures[key, default: 0] += 1
            if s.signatures[key]! >= Limits.maxRepeats {
                s.pause("the same checks failed \(s.signatures[key]!) times after repairs: \((failing + failedCommands).joined(separator: ", "))")
            }
        }
    }

    private func signedOff(_ candidate: String, _ cwd: String, _ t: Turn, _ out: TurnOutput) {
        if readOnlyViolated(cwd) { return unusable(t, "the sign-off") }
        guard let r = report(t, out), let decision = str(r["decision"]) else { return unusable(t, "the sign-off") }
        let holds = s.definitionOfDoneHolds(on: candidate)
        switch decision {
        case "done" where holds:
            s.status = .done
            s.reason = nil
            note("done", "the definition of done holds on \(candidate.prefix(10)) — branch \(s.branch)")
            finish(candidate, summary: str(r["summary"]) ?? "")
        case "done":
            s.pause("the supervisor called it done, but the definition of done doesn't hold on \(candidate.prefix(10)); refusing")
        case "repair":
            var errors: [String] = []
            let ids = Set(s.plan.criteria.map(\.id))
            let added = ((r["chunks"] as? [Any]) ?? []).compactMap { parseChunk($0, criteria: ids, errors: &errors) }
            errors += added.filter { a in s.plan.chunks.contains { $0.id == a.id } }.map { "chunk \"\($0.id)\" already exists" }
            let reopen = ((r["reopen"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
            for o in reopen where s.chunk(str(o["chunk"]) ?? "") == nil { errors.append("unknown chunk \"\(str(o["chunk"]) ?? "")\"") }
            errors += dependencyProblems(s.plan.chunks + added)
            if added.isEmpty && reopen.isEmpty { errors.append("the repair names no chunk") }
            let key = "repair:\(candidate)"
            s.signatures[key, default: 0] += 1
            if s.signatures[key]! >= Limits.maxRepeats { errors.append("\(s.signatures[key]!) repairs haven't changed the result") }
            guard errors.isEmpty else { s.pause("the supervisor's repair plan is invalid: \(errors.joined(separator: "; "))"); return }
            let repo = s.repo
            for o in reopen {
                let id = str(o["chunk"])!
                s.update(id) { c in
                    if let ws = c.workspace { _ = git(repo, "worktree", "remove", "--force", ws) }
                    if let b = c.branch { _ = git(repo, "branch", "-D", b) }
                    c.workspace = nil; c.branch = nil; c.base = nil
                    c.status = .pending
                    c.revisions += 1
                    c.feedback = "Independent verification found: \(str(o["feedback"]) ?? "")"
                }
            }
            s.plan.chunks += added
            note("supervisor", "repair: reopened \(reopen.compactMap { str($0["chunk"]) }.joined(separator: ", "))\(added.isEmpty ? "" : "; added \(added.map(\.id).joined(separator: ", "))")")
        case "pause":
            s.pause("supervisor: \(str(r["reason"]) ?? str(r["summary"]) ?? "needs a human")")
        default:
            note("supervisor", "\(t.id) returned an unknown decision \"\(decision)\"")
            unusable(t, "the sign-off")
        }
    }

    /// Leave the result on the run branch and clear away the scaffolding.
    private func finish(_ candidate: String, summary: String) {
        var doc = "# \(s.plan.goal)\n\nDone on branch `\(s.branch)` at `\(candidate)`.\n\n\(summary)\n\n## Definition of done\n\n"
        let ev = s.evidence(for: candidate)
        for c in s.plan.criteria { doc += "- **\(c.id)** — \(c.description)\n  - \(ev[c.id]?.detail ?? "")\n" }
        if !s.plan.verificationCommands.isEmpty {
            doc += "\n## Commands\n\n"
            for r in s.commands where r.candidate == candidate { doc += "- `\(r.command)` → exit \(r.exitCode)\n" }
        }
        try? doc.write(toFile: dir + "/DONE.md", atomically: true, encoding: .utf8)
        for c in s.plan.chunks {
            if let ws = c.workspace { _ = git(s.repo, "worktree", "remove", "--force", ws) }
            if let b = c.branch { _ = git(s.repo, "branch", "-D", b) }
        }
        let verify = dir + "/verify"
        for v in (try? FileManager.default.contentsOfDirectory(atPath: verify)) ?? [] {
            _ = git(s.repo, "worktree", "remove", "--force", verify + "/" + v)
        }
        _ = git(s.repo, "worktree", "remove", "--force", dir + "/integration")
        _ = git(s.repo, "worktree", "prune")
    }
}
