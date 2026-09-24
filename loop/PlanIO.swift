import Foundation

private let slug = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,39}$")
private func isSlug(_ s: String) -> Bool {
    slug.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// A chunk from agent JSON. Every problem names the chunk, so a planner (or a
/// person) can fix exactly that.
func parseChunk(_ raw: Any, criteria: Set<String>, errors: inout [String]) -> Chunk? {
    guard let o = raw as? [String: Any] else { errors.append("a chunk is not an object"); return nil }
    let id = str(o["id"]) ?? "?"
    let name = "chunk \"\(id)\""
    var ok = true
    func need(_ cond: Bool, _ msg: String) { if !cond { errors.append("\(name): \(msg)"); ok = false } }
    need(isSlug(id), "id must be a short lowercase slug (a-z, 0-9, - or _)")
    need(str(o["title"]) != nil, "needs a title")
    need(str(o["instructions"]) != nil, "needs instructions")
    let paths = strings(o["paths"])
    need(!paths.isEmpty, "needs paths — the files or globs it will touch; use \"**\" only if it spans everything")
    let serves = strings(o["criteria"])
    need(!serves.isEmpty, "must serve at least one criterion")
    for c in serves where !criteria.contains(c) { need(false, "serves unknown criterion \"\(c)\"") }
    let effort = Effort(rawValue: str(o["effort"]) ?? "")
    need(effort != nil, "effort must be light, standard or deep")
    guard ok else { return nil }
    return Chunk(id: id, title: str(o["title"])!, instructions: str(o["instructions"])!, paths: paths,
                 criteria: serves, dependsOn: strings(o["dependsOn"]), effort: effort!)
}

/// The planner's report as a plan plus questions, or every reason it isn't one.
func parsePlan(_ report: [String: Any]) -> (Plan?, [Question], [String]) {
    var errors: [String] = []
    guard let p = report["plan"] as? [String: Any] else { return (nil, [], ["the report has no \"plan\" object"]) }
    var criteria: [Criterion] = []
    for raw in (p["criteria"] as? [Any]) ?? [] {
        guard let o = raw as? [String: Any], let id = str(o["id"]) else { errors.append("a criterion has no id"); continue }
        guard isSlug(id) else { errors.append("criterion \"\(id)\": id must be a short lowercase slug"); continue }
        guard let d = str(o["description"]), let v = str(o["verification"]) else {
            errors.append("criterion \"\(id)\": needs a description and how it is verified"); continue
        }
        if criteria.contains(where: { $0.id == id }) { errors.append("criterion \"\(id)\" appears twice"); continue }
        criteria.append(Criterion(id: id, description: d, verification: v))
    }
    if criteria.isEmpty { errors.append("the plan needs at least one criterion: the definition of done") }
    let ids = Set(criteria.map(\.id))
    var chunks: [Chunk] = []
    for raw in (p["chunks"] as? [Any]) ?? [] {
        guard let c = parseChunk(raw, criteria: ids, errors: &errors) else { continue }
        if chunks.contains(where: { $0.id == c.id }) { errors.append("chunk \"\(c.id)\" appears twice"); continue }
        chunks.append(c)
    }
    if chunks.isEmpty { errors.append("the plan needs at least one chunk") }
    errors += dependencyProblems(chunks)
    for c in criteria where !chunks.contains(where: { $0.criteria.contains(c.id) }) {
        errors.append("criterion \"\(c.id)\" is served by no chunk")
    }
    var questions: [Question] = []
    for raw in (report["questions"] as? [Any]) ?? [] {
        guard let o = raw as? [String: Any], let q = str(o["question"]) else { continue }
        let options = ((o["options"] as? [Any]) ?? []).compactMap { r -> Question.Option? in
            guard let o = r as? [String: Any], let l = str(o["label"]) else { return nil }
            return Question.Option(label: l, recommended: o["recommended"] as? Bool ?? false)
        }
        questions.append(Question(id: str(o["id"]) ?? "q\(questions.count + 1)", question: q, options: options, answer: nil))
    }
    guard errors.isEmpty else { return (nil, questions, errors) }
    let plan = Plan(goal: str(p["goal"]) ?? "", criteria: criteria,
                    verificationCommands: strings(p["verificationCommands"]), chunks: chunks)
    return (plan, questions, [])
}

/// Unknown dependencies and cycles, by name.
func dependencyProblems(_ chunks: [Chunk]) -> [String] {
    var errors: [String] = []
    let ids = Set(chunks.map(\.id))
    for c in chunks {
        for d in c.dependsOn where !ids.contains(d) { errors.append("chunk \"\(c.id)\" depends on unknown chunk \"\(d)\"") }
    }
    var state: [String: Int] = [:]  // 1 visiting, 2 done
    func visit(_ id: String, _ path: [String]) {
        if state[id] == 2 { return }
        if state[id] == 1 { errors.append("dependency cycle: \((path + [id]).joined(separator: " → "))"); return }
        state[id] = 1
        for d in chunks.first(where: { $0.id == id })?.dependsOn ?? [] where ids.contains(d) { visit(d, path + [id]) }
        state[id] = 2
    }
    for c in chunks { visit(c.id, []) }
    return errors
}

/// The plan as the user approves it: what done means, how the work splits,
/// and what the loop will and won't do.
func describePlan(_ s: RunState, slots: [Slot]?) -> String {
    var out = "Goal: \(s.plan.goal)\n\nDone means — checked by a fresh verifier on the final commit:\n"
    for c in s.plan.criteria { out += "  [\(c.id)] \(c.description)\n      check: \(c.verification)\n" }
    if !s.plan.verificationCommands.isEmpty {
        out += "\nThe loop runs, in order, on the final commit:\n"
        for c in s.plan.verificationCommands { out += "  $ \(c)\n" }
    }
    out += "\nChunks (\(s.plan.chunks.count)), up to \(s.concurrency) at once:\n"
    for c in s.plan.chunks {
        var line = "  \(c.id.padding(toLength: 18, withPad: " ", startingAt: 0)) \(c.effort.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(c.title)"
        if let slots, let best = pick(slots, effort: c.effort, cooldowns: s.cooldowns, busy: [:]) { line += "  → \(best.key)" }
        out += line + "\n"
        if !c.dependsOn.isEmpty { out += "      after: \(c.dependsOn.joined(separator: ", "))\n" }
        out += "      paths: \(c.paths.joined(separator: ", "))\n"
    }
    let assumed = s.questions.filter { $0.answer == nil }
    if !assumed.isEmpty {
        out += "\nAssumed (the recommended answer):\n"
        for q in assumed { out += "  \(q.question) → \(q.options.first(where: \.recommended)?.label ?? "no recommendation")\n" }
    }
    out += "\nBudget: \(human(s.budgetMs)) of agent time. Work happens on branch \(s.branch) in worktrees; your checkout is untouched and nothing is pushed.\n"
    return out
}
