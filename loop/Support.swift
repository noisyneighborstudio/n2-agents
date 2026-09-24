import Foundation

struct LoopError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct Output {
    var code: Int32
    var out: String
    var err: String
    var ok: Bool { code == 0 }
    /// Whatever the command said, for an error message.
    var said: String {
        let text = (err.isEmpty ? out : err).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "exit \(code)" : String(text.suffix(2000))
    }
}

/// Run a command to completion, capturing both streams. `exe` is looked up on
/// PATH unless it is absolute.
@discardableResult
func run(_ exe: String, _ args: [String], cwd: String? = nil, env: [String: String] = [:]) -> Output {
    let p = Process()
    if exe.hasPrefix("/") {
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
    } else {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [exe] + args
    }
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return Output(code: 127, out: "", err: "\(exe): \(error)") }
    // Drain both pipes at once, or a chatty stderr fills its buffer and hangs us.
    let box = DataBox()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        box.data = out.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    p.waitUntilExit()
    return Output(code: p.terminationStatus, out: String(decoding: box.data, as: UTF8.self),
                  err: String(decoding: errData, as: UTF8.self))
}

final class DataBox: @unchecked Sendable { var data = Data() }

// MARK: - git

func git(_ cwd: String, _ args: String...) -> Output { run("git", args, cwd: cwd) }

func gitOrThrow(_ cwd: String, _ args: [String]) throws -> String {
    let r = run("git", args, cwd: cwd)
    guard r.ok else { throw LoopError("git \(args.joined(separator: " ")) failed: \(r.said)") }
    return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
}

func head(_ cwd: String) throws -> String { try gitOrThrow(cwd, ["rev-parse", "HEAD"]) }

/// The working tree's identity, untracked files included, without touching
/// the real index — two identical fingerprints mean a turn changed nothing.
func fingerprint(_ cwd: String) -> String {
    let index = NSTemporaryDirectory() + "n2-fp-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: index) }
    let env = ["GIT_INDEX_FILE": index]
    _ = run("git", ["read-tree", "HEAD"], cwd: cwd, env: env)
    _ = run("git", ["add", "-A"], cwd: cwd, env: env)
    let tree = run("git", ["write-tree"], cwd: cwd, env: env)
    return tree.ok ? tree.out.trimmingCharacters(in: .whitespacesAndNewlines) : "unknown"
}

/// Tracked files the role changed, and untracked files it added.
func trackedChanges(_ cwd: String) -> [String] {
    let r = git(cwd, "status", "--porcelain", "--untracked-files=no")
    return r.out.split(separator: "\n").map { String($0.dropFirst(3)) }
}

func changedFiles(_ cwd: String, since base: String) -> [String] {
    let r = git(cwd, "diff", "--name-only", base, "HEAD")
    return r.out.split(separator: "\n").map(String.init)
}

// MARK: - paths

/// Glob match on path segments: `**` spans any number of them, `*` and `?`
/// stay inside one.
func pathMatches(_ path: String, _ pattern: String) -> Bool {
    func match(_ p: ArraySlice<Substring>, _ s: ArraySlice<Substring>) -> Bool {
        guard let first = p.first else { return s.isEmpty }
        if first == "**" {
            var rest = s
            while true {
                if match(p.dropFirst(), rest) { return true }
                if rest.isEmpty { return false }
                rest = rest.dropFirst()
            }
        }
        guard let seg = s.first else { return false }
        guard fnmatch(String(first), String(seg), 0) == 0 else { return false }
        return match(p.dropFirst(), s.dropFirst())
    }
    let pat = pattern.hasSuffix("/") ? pattern + "**" : pattern
    return match(ArraySlice(pat.split(separator: "/")), ArraySlice(path.split(separator: "/")))
}

func inPaths(_ path: String, _ patterns: [String]) -> Bool {
    patterns.contains { pathMatches(path, $0) || pathMatches(path, $0 + "/**") }
}

/// Could two path sets touch the same file? Conservative: compares the literal
/// prefix before the first wildcard, so a false "yes" only serialises work.
func pathsOverlap(_ a: [String], _ b: [String]) -> Bool {
    func stem(_ p: String) -> String {
        let cut = p.firstIndex { "*?[".contains($0) } ?? p.endIndex
        var s = String(p[..<cut])
        if let slash = s.lastIndex(of: "/"), cut != p.endIndex { s = String(s[..<slash]) } else if cut != p.endIndex { s = "" }
        return s
    }
    for x in a.map(stem) {
        for y in b.map(stem) {
            if x.isEmpty || y.isEmpty || x == y || x.hasPrefix(y + "/") || y.hasPrefix(x + "/") { return true }
        }
    }
    return false
}

// MARK: - reports

/// The JSON object an agent returned: the first object after the last
/// `N2_RESULT` marker, else the last fenced json block, else the whole text.
func parseReport(_ text: String) -> [String: Any]? {
    if let marker = text.range(of: "N2_RESULT", options: .backwards),
       let obj = firstObject(in: text[marker.upperBound...]) {
        return obj
    }
    let fences = text.components(separatedBy: "```").enumerated().filter { $0.offset % 2 == 1 }.map { $0.element }
    for block in fences.reversed() {
        if let obj = firstObject(in: Substring(block)) { return obj }
    }
    return firstObject(in: Substring(text))
}

private func firstObject(in text: Substring) -> [String: Any]? {
    var start = text.firstIndex(of: "{")
    while let s = start {
        var depth = 0, inString = false, escaped = false
        var i = s
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let json = Data(text[s...i].utf8)
                    if let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] { return obj }
                    break
                }
            }
            i = text.index(after: i)
        }
        start = text[text.index(after: s)...].firstIndex(of: "{")
    }
    return nil
}

func str(_ v: Any?) -> String? {
    guard let s = v as? String else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

func strings(_ v: Any?) -> [String] { (v as? [Any])?.compactMap { str($0) } ?? [] }

// MARK: - time

func parseDuration(_ s: String) throws -> Int {
    let units: [Character: Double] = ["s": 1_000, "m": 60_000, "h": 3_600_000]
    guard let unit = s.last, let mult = units[unit], let n = Double(s.dropLast()), n > 0 else {
        throw LoopError("use a duration such as 45m or 2h (got \"\(s)\")")
    }
    return Int(n * mult)
}

func human(_ ms: Int) -> String {
    let m = ms / 60_000
    if m < 60 { return "\(m)m" }
    return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h\(m % 60)m"
}

let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func clip(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n)) + "\n…[\(s.count - n) more characters]"
}

func oneLine(_ s: String, _ n: Int = 120) -> String {
    let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
    return flat.count <= n ? flat : String(flat.prefix(n - 1)) + "…"
}
