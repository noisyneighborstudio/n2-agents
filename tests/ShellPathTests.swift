import Foundation

@main struct ShellPathTests {
    /// Fake login shells: each writes what a real one would, then exits.
    static func shell(_ body: String) -> String {
        let path = NSTemporaryDirectory() + "shell-path-test-" + UUID().uuidString
        try! ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    static func expect(_ got: String?, _ want: String?, _ what: String) {
        guard got == want else {
            FileHandle.standardError.write("✗ \(what): got \(got ?? "nil"), want \(want ?? "nil")\n".data(using: .utf8)!)
            exit(1)
        }
    }

    static func main() {
        // The PATH line out of `env`, among everything else a shell exports.
        expect(ShellPath.fromLoginShell(shell("echo HOME=/x; echo PATH=/opt/bin:/usr/bin; echo SHELL=/bin/zsh")),
               "/opt/bin:/usr/bin", "reads PATH from env output")

        // An rc file that prints its own banner — the word PATH included — first.
        expect(ShellPath.fromLoginShell(shell("echo 'PATH=/decoy'; echo LANG=en_US; echo PATH=/real/bin")),
               "/real/bin", "last PATH wins")

        // A shell that never mentions PATH, and one that cannot be run at all.
        expect(ShellPath.fromLoginShell(shell("echo LANG=en_US")), nil, "no PATH in output")
        expect(ShellPath.fromLoginShell("/nonexistent/shell"), nil, "unrunnable shell")

        // A hung rc file must not hang the app: the read ends with the timeout.
        let start = Date()
        _ = ShellPath.fromLoginShell(shell("echo PATH=/slow/bin; sleep 30"), timeout: 1)
        guard Date().timeIntervalSince(start) < 10 else {
            FileHandle.standardError.write("✗ hung shell was not terminated\n".data(using: .utf8)!)
            exit(1)
        }

        print("ShellPath tests passed")
    }
}
