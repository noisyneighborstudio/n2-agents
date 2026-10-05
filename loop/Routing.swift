import Foundation

/// How a reviewed chunk went for the slot whose work it was: 1 accepted on
/// first review, 0.5 accepted after revisions, 0 reopened by verification.
struct Outcome: Codable {
    var slot: String
    var chunk: String
    var effort: Effort
    var score: Double
    var at: Date

    var lab: String { String(slot.split(separator: "|")[0]) }
}

/// Every run's outcomes, by lab: what a lab is really good at, learned from
/// its reviewed work. One JSON line per outcome beside the runs.
final class LabRecord {
    static let learnedAfter = 5
    let path: String
    private(set) var outcomes: [Outcome]

    init(path: String) {
        self.path = path
        // Line by line from the bytes: a damaged line, even invalid UTF-8, costs only itself.
        let data = FileManager.default.contents(atPath: path) ?? Data()
        outcomes = data.split(separator: 0x0A).compactMap { try? Store.decoder.decode(Outcome.self, from: Data($0)) }
    }

    /// One whole line per write, appended under a lock: runs sharing the
    /// record never overwrite or interleave each other's outcomes.
    func add(_ o: Outcome) {
        outcomes.append(o)
        guard let line = try? JSONEncoder.line.encode(o) else { return }
        let fd = open(path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 { guard errno == EINTR else { return } }
        defer { flock(fd, LOCK_UN) }
        // Write the whole line, through interruptions and short writes; a
        // write that fails partway is cut back so no half line is left.
        var before = stat()
        guard fstat(fd, &before) == 0 else { return }
        // A torn line left by a failure we couldn't roll back ends where the
        // next begins: start fresh, so it costs only itself.
        // A read that fails counts as torn: an extra blank line is harmless.
        var last: UInt8 = 0x0A
        if before.st_size > 0 {
            var n = pread(fd, &last, 1, before.st_size - 1)
            while n < 0 && errno == EINTR { n = pread(fd, &last, 1, before.st_size - 1) }
            if n != 1 { last = 0 }
        }
        let bytes = (last == 0x0A ? [] : [0x0A]) + [UInt8](line + Data("\n".utf8))
        var done = 0
        while done < bytes.count {
            let n = bytes[done...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { done += n } else if n < 0 && errno == EINTR { continue } else {
                while ftruncate(fd, before.st_size) != 0 && errno == EINTR {}
                return
            }
        }
    }

    /// The lab's measured strength for this effort on the adapters' 1-3 scale
    /// once it has enough reviewed chunks; the adapter's rating before.
    func strength(_ lab: String, _ effort: Effort) -> Double {
        let seen = outcomes.filter { $0.lab == lab && $0.effort == effort }
        guard seen.count >= Self.learnedAfter else { return Double(Adapter.of(lab)?.strength[effort] ?? 1) }
        return 1 + 2 * seen.map(\.score).reduce(0, +) / Double(seen.count)
    }
}

extension JSONEncoder {
    /// One compact line, dates as ISO 8601: the record's line format.
    static let line: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

/// The worker slot for a chunk: strength for its effort times quota left,
/// with no slot taking more than 1.5x its fair share of the run's work while
/// another usable slot has less. Measured capacity still comes before
/// unmeasured, so unknown usage never looks like room.
func pickWorker(_ slots: [Slot], effort: Effort, cooldowns: [String: Cooldown], busy: [String: Int],
                assigned: [String: Int], strength: (String, Effort) -> Double) -> Slot? {
    let open = slots.filter { unusable($0, cooldowns: cooldowns) == nil }
    // Fairness is shared among measured slots; unmeasured ones work only when none is left.
    let measured = open.filter { $0.quota == "ok" }
    let usable = measured.isEmpty ? open : measured
    guard !usable.isEmpty else { return nil }
    let total = usable.reduce(1) { $0 + (assigned[$1.key] ?? 0) }
    let cap = max(1, Int(1.5 * Double(total) / Double(usable.count)))
    let least = usable.map { assigned[$0.key] ?? 0 }.min()!
    let fair = usable.filter { (assigned[$0.key] ?? 0) < cap || (assigned[$0.key] ?? 0) == least }
    func score(_ s: Slot) -> Double { strength(s.vendor, effort) * (s.quota == "ok" ? (100 - (s.used ?? 100)) / 100 : 1) }
    return fair.sorted { a, b in
        if (a.quota == "ok") != (b.quota == "ok") { return a.quota == "ok" }
        let sa = score(a), sb = score(b)
        if abs(sa - sb) > 1e-9 { return sa > sb }
        let ba = busy[a.key] ?? 0, bb = busy[b.key] ?? 0
        if ba != bb { return ba < bb }
        let na = assigned[a.key] ?? 0, nb = assigned[b.key] ?? 0
        if na != nb { return na < nb }
        return a.key < b.key
    }.first
}

/// Who did the run's work and how it went, per slot and per lab.
func spreadTable(_ s: RunState) -> String {
    let outcomes = s.outcomes ?? []
    let work = s.turns.filter { $0.role == .worker }
    func row(_ name: String, _ match: (String) -> Bool) -> String {
        let mine = outcomes.filter { match($0.slot) }
        let accepted = mine.filter { $0.score > 0 }
        let pad = { (t: String, n: Int) in t.count >= n ? t : t + String(repeating: " ", count: n - t.count) }
        return "  " + pad(name, 22) + " " + pad("\(work.filter { match($0.slot) }.count)", 6) + " "
            + pad("\(accepted.count)", 9) + " " + pad("\(accepted.filter { $0.score == 1 }.count)", 11) + " "
            + "\(mine.filter { $0.score == 0 }.count)\n"
    }
    let slots = Set(work.map(\.slot)).sorted()
    guard !slots.isEmpty else { return "" }
    var out = "  SLOT                   TURNS  ACCEPTED  FIRST PASS  REOPENED\n"
    for k in slots { out += row(k) { $0 == k } }
    for lab in Set(slots.map { String($0.split(separator: "|")[0]) }).sorted() {
        out += row(lab + " (lab)") { $0.hasPrefix(lab + "|") }
    }
    return out
}
