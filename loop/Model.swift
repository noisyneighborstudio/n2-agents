import Foundation

// The durable record of one loop run. Only the controller writes it while the
// run is live; everything else reads it, so status never needs a model call.

enum RunStatus: String, Codable {
    case draft = "DRAFT"        // planned, awaiting approval
    case running = "RUNNING"
    case waiting = "WAITING"    // every usable slot is cooling down until retryAt
    case paused = "PAUSED"      // stopped with a reason; resume continues from here
    case done = "DONE"          // the definition of done holds on the final commit
}

enum ChunkStatus: String, Codable {
    case pending    // waiting for a worker (new, revising, or stalled with a strategy)
    case working    // a worker turn is running
    case reviewing  // committed; waiting for the supervisor
    case accepted   // reviewed and merged into the run branch
}

/// How much model the work needs. The planner rates every chunk; the slot
/// picked for it is the strongest one for that rating with quota left.
enum Effort: String, Codable, CaseIterable {
    case light, standard, deep
}

enum Role: String, Codable {
    case planner, worker, supervisor, verifier
}

/// One line of the definition of done: observable, and checked by a fresh
/// verifier against the final commit — never by the agent that did the work.
struct Criterion: Codable, Equatable {
    var id: String
    var description: String
    var verification: String
}

struct Chunk: Codable {
    var id: String
    var title: String
    var instructions: String
    /// Paths this chunk expects to touch. Chunks whose paths overlap never run
    /// at the same time; edits outside them go to the supervisor to judge.
    var paths: [String]
    var criteria: [String]
    var dependsOn: [String]
    var effort: Effort

    var status: ChunkStatus = .pending
    var branch: String? = nil
    var workspace: String? = nil
    var base: String? = nil
    var turns: Int = 0
    var revisions: Int = 0
    /// The supervisor's latest instruction to whoever works on this next.
    var feedback: String? = nil
    var summary: String? = nil
    /// Identity of the working tree after the last worker turn.
    var fingerprint: String? = nil
    /// Consecutive worker turns that changed nothing.
    var stalls: Int = 0
    /// Recovery strategies already tried; a repeat is not a new approach.
    var strategies: [String] = []
    var lastSlot: String? = nil
    var mergedAs: String? = nil
    /// Set when the chunk stalls: the supervisor diagnoses it before anyone
    /// works on it again.
    var problem: String? = nil
}

struct Plan: Codable {
    var goal: String
    /// The definition of done. Fixed at approval: no agent can change it.
    var criteria: [Criterion]
    /// Exact commands the loop itself runs on the final commit, in order.
    var verificationCommands: [String]
    var chunks: [Chunk]
}

struct Question: Codable {
    struct Option: Codable {
        var label: String
        var recommended: Bool
    }
    var id: String
    var question: String
    var options: [Option]
    var answer: String?
}

struct Evidence: Codable {
    var criterion: String
    var passed: Bool
    var detail: String
    var candidate: String
    var turn: String
}

struct CommandResult: Codable {
    var command: String
    var exitCode: Int32
    var tail: String
    var candidate: String
    var seconds: Double
}

struct Turn: Codable {
    var id: String
    var role: Role
    var chunk: String?
    var slot: String
    var effort: Effort
    var startedAt: Date
    var endedAt: Date? = nil
    var pgid: Int32? = nil
    /// ok · invalid · timeout · interrupted · quota · auth · outage · failed
    var outcome: String? = nil
    var note: String? = nil
}

struct Cooldown: Codable {
    var until: Date
    var reason: String
}

struct Event: Codable {
    var at: Date
    var kind: String
    var detail: String
}

struct RunState: Codable {
    var id: String
    var created: Date
    /// The user's repository. Never written to: all work happens in worktrees.
    var repo: String
    var baseCommit: String
    var branch: String
    var sources: [String]
    var status: RunStatus
    var reason: String?
    var retryAt: Date?
    var budgetMs: Int
    var usedMs: Int
    var concurrency: Int
    var keepAwake: Bool
    var plan: Plan
    var questions: [Question]
    var turns: [Turn]
    var evidence: [Evidence]
    var commands: [CommandResult]
    var cooldowns: [String: Cooldown]
    /// Failure signature → times seen. A repeat without a material change pauses.
    var signatures: [String: Int]
    var events: [Event]

    var shortId: String { String(id.prefix(8)) }
    var candidate: String? { plan.chunks.allSatisfy { $0.status == .accepted } ? lastMerge : nil }
    var lastMerge: String?

    func chunk(_ id: String) -> Chunk? { plan.chunks.first { $0.id == id } }

    mutating func update(_ id: String, _ body: (inout Chunk) -> Void) {
        if let i = plan.chunks.firstIndex(where: { $0.id == id }) { body(&plan.chunks[i]) }
    }

    mutating func log(_ kind: String, _ detail: String) {
        events.append(Event(at: Date(), kind: kind, detail: detail))
        if events.count > 400 { events.removeFirst(events.count - 400) }
    }

    mutating func pause(_ reason: String) {
        status = .paused
        self.reason = reason
        log("paused", reason)
    }

    /// Latest evidence per criterion for `candidate`.
    func evidence(for candidate: String) -> [String: Evidence] {
        var out: [String: Evidence] = [:]
        for e in evidence where e.candidate == candidate { out[e.criterion] = e }
        return out
    }

    /// True only when every criterion passed, and every verification command
    /// exited 0, on this exact commit. Nothing else counts as done.
    func definitionOfDoneHolds(on candidate: String) -> Bool {
        let ev = evidence(for: candidate)
        let criteriaPass = plan.criteria.allSatisfy { ev[$0.id]?.passed == true }
        let results = commands.filter { $0.candidate == candidate }
        let commandsPass = plan.verificationCommands.allSatisfy { cmd in
            results.last(where: { $0.command == cmd })?.exitCode == 0
        }
        return criteriaPass && commandsPass
    }
}
