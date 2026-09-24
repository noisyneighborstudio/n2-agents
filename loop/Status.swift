import Foundation

private func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

/// Everything about a run, read from its record alone.
func describeRun(_ s: RunState, controllerAlive: Bool) -> String {
    let live = s.turns.filter { $0.endedAt == nil }
    let used = s.usedMs + live.reduce(0) { $0 + Int(Date().timeIntervalSince($1.startedAt) * 1000) }
    var state = s.status.rawValue
    if [.running, .waiting].contains(s.status) && !controllerAlive { state += " (controller not running — agents loop resume \(s.shortId))" }
    var out = "loop \(s.shortId) · \(state) · \(human(used)) of \(human(s.budgetMs)) agent time · branch \(s.branch)\n"
    out += "goal: \(oneLine(s.plan.goal, 200))\n"
    if let r = s.reason { out += "\(s.status == .paused ? "paused" : "note"): \(r)\n" }
    if s.status == .waiting, let at = s.retryAt { out += "waiting for quota until \(iso.string(from: at))\n" }

    let candidate = s.candidate
    out += "\ndone means\(candidate.map { " (checked on \($0.prefix(10)))" } ?? " (nothing to check until every chunk is merged)"):\n"
    let ev = candidate.map { s.evidence(for: $0) } ?? [:]
    for c in s.plan.criteria {
        let mark = ev[c.id].map { $0.passed ? "✓" : "✗" } ?? "·"
        out += "  \(mark) \(pad(c.id, 18)) \(oneLine(c.description, 90))\n"
        if let e = ev[c.id], !e.passed { out += "      \(oneLine(e.detail, 150))\n" }
    }
    if !s.plan.verificationCommands.isEmpty {
        let results = s.commands.filter { $0.candidate == candidate }
        let marks = s.plan.verificationCommands.map { cmd -> String in
            let r = results.last { $0.command == cmd }
            return "\(r.map { $0.exitCode == 0 ? "✓" : "✗" } ?? "·") \(cmd)"
        }
        out += "  commands: \(marks.joined(separator: "   "))\n"
    }

    out += "\n  \(pad("CHUNK", 18)) \(pad("STATUS", 10)) \(pad("EFFORT", 9)) \(pad("LAST SLOT", 22)) TURNS REV\n"
    for c in s.plan.chunks {
        let status = c.problem != nil ? "stalled" : c.status.rawValue
        out += "  \(pad(c.id, 18)) \(pad(status, 10)) \(pad(c.effort.rawValue, 9)) \(pad(c.lastSlot ?? "–", 22)) \(pad(String(c.turns), 5)) \(c.revisions)\n"
        if let p = c.problem { out += "      problem: \(oneLine(p, 140))\n" }
        else if c.status != .accepted, let f = c.feedback { out += "      next: \(oneLine(f, 140))\n" }
    }
    if !live.isEmpty {
        out += "\nnow:\n"
        for t in live {
            out += "  \(t.role.rawValue) \(t.chunk ?? "") on \(t.slot) [\(t.effort.rawValue)] for \(Int(Date().timeIntervalSince(t.startedAt) / 60))m\n"
        }
    }
    let cooling = s.cooldowns.filter { $0.value.until > Date() }
    if !cooling.isEmpty {
        out += "\nslots set aside:\n"
        for (k, c) in cooling.sorted(by: { $0.key < $1.key }) { out += "  \(pad(k, 22)) \(c.reason)\n" }
    }
    if s.status == .done { out += "\nresult: branch \(s.branch) — merge it when you're happy. Report: \(Store.standard().dir(s.id))/DONE.md\n" }
    return out
}

func listRuns(_ store: Store) -> String {
    let runs = store.ids().compactMap { try? store.load($0) }.sorted { $0.created > $1.created }
    guard !runs.isEmpty else { return "no loops yet — start one: agents loop \"goal\" --budget 2h" }
    return runs.map { r in
        let alive = store.controllerRunning(r.id)
        let state = r.status.rawValue + ([.running, .waiting].contains(r.status) && !alive ? "*" : "")
        let merged = r.plan.chunks.filter { $0.status == .accepted }.count
        return "\(r.shortId)  \(pad(state, 9)) \(merged)/\(r.plan.chunks.count) chunks  \(pad(human(r.usedMs) + "/" + human(r.budgetMs), 10)) \(oneLine(r.plan.goal, 70))"
    }.joined(separator: "\n") + (runs.contains { [.running, .waiting].contains($0.status) && !store.controllerRunning($0.id) } ? "\n* controller not running — agents loop resume <run>" : "")
}
