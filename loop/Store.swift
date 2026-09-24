import Darwin
import Foundation

/// Where runs live: ~/.n2-agents/loops/<id>/, beside the profiles they use.
/// Each holds state.json, the run's worktrees, and a log of every turn.
struct Store {
    let root: String

    static func standard() -> Store {
        let env = ProcessInfo.processInfo.environment
        return Store(root: env["N2_LOOP_HOME"] ?? (NSHomeDirectory() + "/.n2-agents/loops"))
    }

    func dir(_ id: String) -> String { root + "/" + id }
    func stateFile(_ id: String) -> String { dir(id) + "/state.json" }
    func pauseFile(_ id: String) -> String { dir(id) + "/pause-requested" }
    func controllerLog(_ id: String) -> String { dir(id) + "/controller.log" }
    func turnFiles(_ id: String, _ turn: String) -> String { dir(id) + "/turns/" + turn }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func load(_ id: String) throws -> RunState {
        guard let data = FileManager.default.contents(atPath: stateFile(id)) else { throw LoopError("no run \(id)") }
        do { return try Store.decoder.decode(RunState.self, from: data) } catch {
            throw LoopError("run \(id) has an unreadable state.json: \(error)")
        }
    }

    /// Atomic replace: a reader never sees half a file.
    func save(_ s: RunState) throws {
        try FileManager.default.createDirectory(atPath: dir(s.id) + "/turns", withIntermediateDirectories: true)
        let data = try Store.encoder.encode(s)
        let tmp = stateFile(s.id) + ".tmp"
        FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
        guard rename(tmp, stateFile(s.id)) == 0 else { throw LoopError("could not save run \(s.id): \(String(cString: strerror(errno)))") }
    }

    func ids() -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return all.filter { FileManager.default.fileExists(atPath: stateFile($0)) }
    }

    /// A run id, or a unique prefix of one; with no id, the only run there is.
    func resolve(_ given: String?) throws -> String {
        let all = ids()
        guard let given else {
            let live = try all.map { try load($0) }.filter { $0.status != .done }
            if live.count == 1 { return live[0].id }
            if all.count == 1 { return all[0] }
            throw LoopError(all.isEmpty ? "no loops yet — start one: agents loop \"goal\" --budget 2h"
                                        : "which run? \(all.sorted().joined(separator: ", "))")
        }
        let hits = all.filter { $0.hasPrefix(given) }
        guard hits.count == 1 else { throw LoopError(hits.isEmpty ? "no run \(given)" : "\(given) matches \(hits.joined(separator: ", "))") }
        return hits[0]
    }

    // MARK: controller lock

    /// Held by the controller for its whole life. The kernel drops it when the
    /// process dies, so a stale pid can never make a dead run look alive.
    func lock(_ id: String) -> Int32? {
        let fd = open(dir(id) + "/controller.lock", O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        close(fd)
        return nil
    }

    func controllerRunning(_ id: String) -> Bool {
        guard let fd = lock(id) else { return true }
        flock(fd, LOCK_UN)
        close(fd)
        return false
    }
}
