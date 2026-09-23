import Foundation

// A GUI launch inherits launchd's PATH — /usr/bin:/bin:/usr/sbin:/sbin — and
// no lab's CLI lives there, so `agents` reported every vendor as not installed
// and every profile as empty. The bundled scripts run with the PATH a terminal
// has instead, read from the user's login shell.
enum ShellPath {
    /// The PATH `shell` gives a terminal, or nil if it can't be asked.
    static func fromLoginShell(_ shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                               timeout: TimeInterval = 5) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        // Login *and* interactive: PATH is set in .zshrc as often as in
        // .zprofile — mise, asdf and nvm all install themselves there. `env`
        // rather than echoing $PATH, which fish hands back space-separated.
        task.arguments = ["-ilc", "env"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        // An rc file that waits on input would otherwise hang every refresh.
        let expiry = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        expiry.cancel()
        // Last wins: an rc file that prints before setting PATH can't win over
        // the real environment, which `env` writes once, at the end.
        return out.split(separator: "\n").last { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) }
    }
}
