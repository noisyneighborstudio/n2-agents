import Foundation

/// One profile's sign-in for one lab — the unit the loop hands work to.
/// Everything here comes from the `agents` CLI, which stays the single source
/// of truth for profiles, sign-in and quota.
struct Slot {
    let profile: String
    let vendor: String
    /// yes · no · unknown
    let signedIn: String
    /// Highest window used, 0-100; nil when the lab reports none or the read failed.
    var used: Double?
    /// ok · no-token · stale-token · rate-limited · fetch-error · no-usage-api
    var quota: String
    /// When a full window frees up, if the lab says.
    var resets: Date? = nil
    var key: String { "\(vendor)|\(profile)" }
}

/// How the loop drives one lab's CLI headless. Only labs with a scoped,
/// non-interactive approval mode are here: nobody is present to approve a tool
/// call, and "run everything" modes (grok --always-approve, cursor --force)
/// are not something the loop may turn on for you.
struct Adapter {
    let vendor: String
    /// Relative strength per effort rating. Ties go to the slot with more quota.
    let strength: [Effort: Int]
    let promptOnStdin: Bool
    let args: (Effort, String) -> [String]

    static let all: [Adapter] = [
        Adapter(vendor: "claude", strength: [.deep: 3, .standard: 3, .light: 2], promptOnStdin: true) { effort, _ in
            let model: [Effort: (String, String)] = [.deep: ("opus", "high"), .standard: ("sonnet", "medium"), .light: ("haiku", "low")]
            let (m, e) = model[effort]!
            // auto: Claude's own classifier approves each tool call. Headless
            // prompts must go nowhere, or it waits on a host that isn't there.
            return ["-p", "--output-format", "text", "--permission-mode", "auto", "--permission-prompts", "none",
                    "--model", m, "--effort", e]
        },
        Adapter(vendor: "codex", strength: [.deep: 3, .standard: 3, .light: 2], promptOnStdin: true) { effort, _ in
            let e: [Effort: String] = [.deep: "high", .standard: "medium", .light: "low"]
            return ["exec", "--color", "never", "--approve-for-me", "-c", "model_reasoning_effort=\"\(e[effort]!)\"", "-"]
        },
        Adapter(vendor: "muse", strength: [.deep: 2, .standard: 2, .light: 2], promptOnStdin: false) { effort, file in
            let e: [Effort: String] = [.deep: "high", .standard: "medium", .light: "low"]
            return ["exec", "--approval-judge", "on", "--user-input-auto-resolve", "--reasoning-effort", e[effort]!, "--prompt-file", file]
        },
    ]

    static func of(_ vendor: String) -> Adapter? { all.first { $0.vendor == vendor } }
}

/// Reads slots and quota through `agents`. Quota is a network read per lab, so
/// it is reused for a minute.
final class SlotSource {
    let cli: String
    private var cached: (at: Date, slots: [Slot])?

    init(cli: String) { self.cli = cli }

    func slots(fresh: Bool = false) throws -> [Slot] {
        if !fresh, let c = cached, Date().timeIntervalSince(c.at) < 60 { return c.slots }
        let porcelain = run(cli, ["porcelain"])
        guard porcelain.ok else { throw LoopError("agents porcelain failed: \(porcelain.said)") }
        var usageLabs = Set<String>()
        var slots: [Slot] = []
        for line in porcelain.out.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.first == "V", f.count > 4, f[2] == "1", f[4] != "none" { usageLabs.insert(f[1]) }
            if f.first == "S", f.count > 5, Adapter.of(f[2]) != nil {
                slots.append(Slot(profile: f[1], vendor: f[2], signedIn: f[5], used: nil, quota: "no-usage-api"))
            }
        }
        for lab in Set(slots.map(\.vendor)) where usageLabs.contains(lab) {
            let rows = run(cli, ["best", "--porcelain", "--vendor", lab])
            for i in slots.indices where slots[i].vendor == lab { slots[i].quota = "fetch-error" }
            guard rows.ok else { continue }
            for row in rows.out.split(separator: "\n") {
                let f = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 5, let i = slots.firstIndex(where: { $0.vendor == lab && $0.profile == f[0] }) else { continue }
                slots[i].quota = f[4]
                let five = Double(f[1]), seven = Double(f[2])
                slots[i].used = [five, seven].compactMap { $0 }.max()
                // Resets are UTC minutes: 2026-09-26T08:24.
                let utc = DateFormatter()
                utc.locale = Locale(identifier: "en_US_POSIX")
                utc.timeZone = TimeZone(identifier: "UTC")
                utc.dateFormat = "yyyy-MM-dd'T'HH:mm"
                let full = [(five, f[3]), (seven, f.count > 5 ? f[5] : "")].filter { ($0.0 ?? 0) >= 95 }
                slots[i].resets = full.compactMap { utc.date(from: $0.1) }.max()
            }
        }
        cached = (Date(), slots)
        return slots
    }
}

/// Why a slot can't take work right now, or nil when it can.
func unusable(_ s: Slot, cooldowns: [String: Cooldown], now: Date = Date()) -> String? {
    if s.signedIn == "no" { return "not signed in" }
    if let c = cooldowns[s.key], c.until > now { return c.reason }
    switch s.quota {
    case "no-token", "stale-token": return "sign-in expired (\(s.quota))"
    case "ok":
        guard let u = s.used, u.isFinite, u >= 0, u <= 100 else { return "usage unknown" }
        if u >= 95 { return "\(Int(u))% of quota used (local reserve)" }
    case "no-usage-api": break
    default: return "usage unavailable (\(s.quota))"
    }
    return nil
}

/// Best slot for `effort`, strongest first, then most quota left. Review roles
/// prefer a different lab from the work under review, so a model never grades
/// its own homework when another one is available.
func pick(_ slots: [Slot], effort: Effort, cooldowns: [String: Cooldown], busy: [String: Int],
          avoidVendors: Set<String> = [], avoidSlots: Set<String> = []) -> Slot? {
    let usable = slots.filter { unusable($0, cooldowns: cooldowns) == nil && !avoidSlots.contains($0.key) }
    func headroom(_ s: Slot) -> Double { s.quota == "ok" ? 100 - (s.used ?? 100) : 30 }  // unmeasured ranks below healthy
    return usable.sorted { a, b in
        let ia = avoidVendors.contains(a.vendor) ? 1 : 0, ib = avoidVendors.contains(b.vendor) ? 1 : 0
        if ia != ib { return ia < ib }
        let sa = Adapter.of(a.vendor)!.strength[effort]!, sb = Adapter.of(b.vendor)!.strength[effort]!
        if sa != sb { return sa > sb }
        let ba = busy[a.key] ?? 0, bb = busy[b.key] ?? 0
        if ba != bb { return ba < bb }
        let ha = headroom(a), hb = headroom(b)
        if ha != hb { return ha > hb }
        return a.key < b.key
    }.first
}

/// A failed run's outcome, and how long its slot sits out. Shared by the
/// planner and the controller so both judge slots the same way.
func slotTrouble(_ slot: String, _ tail: String, now: Date = Date()) -> (String, Cooldown) {
    switch Failure.classify(tail, now: now) {
    case .quota(let until):
        return ("quota", Cooldown(until: until, reason: "out of quota until \(iso.string(from: until))"))
    case .attention:
        return ("attention", Cooldown(until: now.addingTimeInterval(12 * 3600), reason: "needs you: \(oneLine(tail, 160))"))
    case .auth:
        let parts = slot.split(separator: "|")
        return ("auth", Cooldown(until: now.addingTimeInterval(12 * 3600),
                                 reason: "sign-in failed — run: agents login \(parts.last ?? "") --vendor \(parts.first ?? "")"))
    case .outage:
        return ("outage", Cooldown(until: now.addingTimeInterval(600), reason: "provider outage"))
    case .other:
        return ("failed", Cooldown(until: now.addingTimeInterval(600), reason: "the agent exited with an error"))
    }
}

/// What a failed turn says about the slot, as opposed to the work.
enum Failure {
    case quota(until: Date)
    case attention   // the lab wants a person first: new terms, a verification step
    case auth
    case outage
    case other

    /// A slot problem is never charged to the chunk: the work moves elsewhere.
    static func classify(_ text: String, now: Date = Date()) -> Failure {
        let t = text.lowercased()
        let quota = ["usage limit", "rate limit", "quota", "out of credits", "insufficient credits",
                     "limit reached", "too many requests", " 429", "hit your session limit",
                     "hit your weekly limit", "hit your monthly spend limit", "out of usage credits",
                     "opus usage limit", "sonnet usage limit"]
        if quota.contains(where: t.contains) { return .quota(until: resetTime(in: text, now: now) ?? now.addingTimeInterval(3600)) }
        let attention = ["action required", "you must run", "review the updated terms", "accept the terms"]
        if attention.contains(where: t.contains) { return .attention }
        let auth = ["not logged in", "please log in", "login required", "unauthorized", " 401", "authentication failed", "invalid api key"]
        if auth.contains(where: t.contains) { return .auth }
        let outage = [" 500", " 502", " 503", " 504", "overloaded", "internal server error", "service unavailable", "bad gateway"]
        if outage.contains(where: t.contains) { return .outage }
        return .other
    }

    /// "try again at Sep 26th, 2026 11:20 AM" and similar, when the lab says.
    static func resetTime(in text: String, now: Date) -> Date? {
        guard let r = text.range(of: #"(?i)try again (at|after|in) ([^.\n]+)"#, options: .regularExpression) else { return nil }
        let phrase = String(text[r]).replacingOccurrences(of: #"(?i)try again (at|after|in) "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(\d)(st|nd|rd|th)"#, with: "$1", options: .regularExpression)
        if let m = phrase.range(of: #"^(\d+)\s*(minute|min|hour|hr|second|sec)"#, options: .regularExpression) {
            let parts = phrase[m].split(separator: " ", maxSplits: 1)
            let n = Double(parts[0].filter(\.isNumber)) ?? 60
            let unit = phrase[m].lowercased()
            let secs = unit.contains("h") ? n * 3600 : unit.contains("m") ? n * 60 : n
            return now.addingTimeInterval(secs)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["MMM d, yyyy h:mm a", "MMMM d, yyyy h:mm a", "yyyy-MM-dd HH:mm", "MMM d h:mm a"] {
            f.dateFormat = format
            if let d = f.date(from: phrase.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }
}
