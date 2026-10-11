import Foundation

// Fed by scripts/test-fleet-invite.sh with what the real CLI printed in a
// throwaway fleet, read the way the app reads it (stderr merged into stdout).
@main struct FleetInviteTests {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            if !condition { fatalError(message) }
        }
        let args = CommandLine.arguments
        let minted = try! String(contentsOfFile: args[1], encoding: .utf8)
        let hostKey = try! String(contentsOfFile: args[2], encoding: .utf8)
        let invites = args[3]

        let invite = FleetInvite(inviteOutput: minted, hostKeyOutput: hostKey)
        check(invite != nil, "the real invite output parses")
        let files = try! FileManager.default.contentsOfDirectory(atPath: invites)
        let stored = files.map { try! String(contentsOfFile: invites + "/" + $0, encoding: .utf8) }
        check(stored.contains { $0.contains("secret=\(invite!.code)\n") }, "the code shown is the secret the CLI stored")
        check(!invite!.code.contains("agents:"), "stderr notes never become the code")
        let line = hostKey.trimmingCharacters(in: .whitespacesAndNewlines)
        check(invite!.hostKey == (line.isEmpty ? nil : line), "the host key line is carried whole")
        check(FleetInvite(inviteOutput: minted, hostKeyOutput: "n2 ssh-ed25519 AAAAfixture\n")?.hostKey == "n2 ssh-ed25519 AAAAfixture",
              "a host key line loses only its trailing newline")

        check(FleetInvite(inviteOutput: minted, hostKeyOutput: "")?.hostKey == nil, "no host key is shown as none, not as an empty line")
        check(FleetInvite(inviteOutput: "agents: no fleet identity (run: agents fleet init)", hostKeyOutput: hostKey) == nil,
              "a CLI error is never shown as a code")
        check(FleetInvite(inviteOutput: "", hostKeyOutput: hostKey) == nil, "empty output is not a code")
        print("fleet invite tests passed")
    }
}
