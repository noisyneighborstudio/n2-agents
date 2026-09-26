import Darwin
import Foundation

struct TurnRequest {
    let cli: String          // the `agents` CLI: it pins the slot's config dir
    let slot: Slot
    let effort: Effort
    let cwd: String
    let prompt: String
    let files: String        // path prefix for .prompt / .out / .err
    let timeout: TimeInterval
    /// Run in its own session so a timeout or pause can stop the agent and
    /// everything it started. The foreground planner stays in the terminal's
    /// group instead, so Ctrl-C reaches it.
    let detach: Bool
}

struct TurnOutput {
    var exit: Int32
    var timedOut: Bool
    var aborted: Bool
    var stdout: String
    var stderr: String
    var seconds: Double
    var tail: String { String((stdout + "\n" + stderr).suffix(3000)) }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Run one agent turn to completion. Blocking: the controller calls it off
/// the main thread.
func runTurn(_ r: TurnRequest, abort: Flag, onSpawn: (pid_t) -> Void = { _ in }) throws -> TurnOutput {
    guard let adapter = Adapter.of(r.slot.vendor) else { throw LoopError("no headless adapter for \(r.slot.vendor)") }
    let promptFile = r.files + ".prompt", outFile = r.files + ".out", errFile = r.files + ".err"
    try r.prompt.write(toFile: promptFile, atomically: true, encoding: .utf8)
    let argv = [r.cli, "run", r.slot.profile, "--vendor", r.slot.vendor] + adapter.args(r.effort, promptFile)

    let started = Date()
    let (exit, timedOut, aborted) = try spawnAndWait(argv, cwd: r.cwd, stdin: adapter.promptOnStdin ? promptFile : "/dev/null",
                                                     stdout: outFile, stderr: errFile, timeout: r.timeout, detach: r.detach,
                                                     abort: abort, onSpawn: onSpawn)
    return TurnOutput(
        exit: exit, timedOut: timedOut, aborted: aborted,
        stdout: (try? String(contentsOfFile: outFile, encoding: .utf8)) ?? "",
        stderr: (try? String(contentsOfFile: errFile, encoding: .utf8)) ?? "",
        seconds: Date().timeIntervalSince(started))
}

/// Spawn `argv` (absolute path first) and wait, stopping it at the timeout or
/// when `abort` is set. Returns (exit status, timed out, aborted).
func spawnAndWait(_ argv: [String], cwd: String, stdin: String, stdout: String, stderr: String,
                  timeout: TimeInterval, detach: Bool, abort: Flag,
                  onSpawn: (pid_t) -> Void = { _ in }) throws -> (Int32, Bool, Bool) {
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, stdin, O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, stdout, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    posix_spawn_file_actions_addopen(&actions, 2, stderr, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    posix_spawn_file_actions_addchdir_np(&actions, cwd)
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    // A worker must not hold the controller's command pipes or lock open.
    // Only descriptors explicitly configured above belong in the child.
    var flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    if detach { flags |= Int16(POSIX_SPAWN_SETSID) }
    posix_spawnattr_setflags(&attr, flags)

    var pid: pid_t = 0
    let cargs = argv.map { strdup($0) } + [nil]
    defer { cargs.forEach { free($0) } }
    let started = Date()
    let rc = posix_spawn(&pid, argv[0], &actions, &attr, cargs, environ)
    guard rc == 0 else { throw LoopError("could not start \(argv[0]): \(String(cString: strerror(rc)))") }
    onSpawn(pid)

    var status: Int32 = 0
    var timedOut = false, aborted = false
    while waitpid(pid, &status, WNOHANG) == 0 {
        if Date().timeIntervalSince(started) > timeout { timedOut = true }
        if abort.isSet { aborted = true }
        if timedOut || aborted {
            // TERM the group and reap our child as it goes (a zombie would
            // still answer kill -0); then KILL whatever in the group is left.
            let target = detach ? -pid : pid
            kill(target, SIGTERM)
            var reaped = false
            for _ in 0..<50 where !reaped {
                reaped = waitpid(pid, &status, WNOHANG) != 0
                if !reaped { usleep(200_000) }
            }
            kill(target, SIGKILL)
            if !reaped { waitpid(pid, &status, 0) }
            break
        }
        usleep(200_000)
    }
    let exit: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    return (exit, timedOut, aborted)
}

/// TERM a process group we didn't start (an orphan from a crashed
/// controller), then KILL whatever is left after a grace.
func stop(group pid: pid_t) {
    let target = -pid
    kill(target, SIGTERM)
    for _ in 0..<50 {
        if kill(target, 0) != 0 { return }
        usleep(200_000)
    }
    kill(target, SIGKILL)
}

/// Start `argv` detached from this terminal, logging to `log`. The controller
/// runs this way so closing the terminal doesn't stop the run.
@discardableResult
func spawnDetached(_ argv: [String], log: String) throws -> pid_t {
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var pid: pid_t = 0
    let cargs = argv.map { strdup($0) } + [nil]
    defer { cargs.forEach { free($0) } }
    let rc = posix_spawn(&pid, argv[0], &actions, &attr, cargs, environ)
    guard rc == 0 else { throw LoopError("could not start \(argv[0]): \(String(cString: strerror(rc)))") }
    return pid
}
