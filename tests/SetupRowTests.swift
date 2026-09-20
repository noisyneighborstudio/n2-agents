import Foundation

// The Setup Assistant's contract with `agents setup --porcelain`, and the
// one-action-per-row rule it renders.
@main struct SetupRowTests {
    static func main() {
        let text = """
        S\tclaude\t1\treal\tyes\tClaude Code\tnpm install -g @anthropic-ai/claude-code
        S\tcodex\t1\tlinked\tno\tCodex\tnpm install -g @openai/codex
        S\tgrok\t0\tabsent\tno\tGrok\thttps://docs.x.ai/docs/grok-cli
        S\tcursor\t1\tlinked\tunknown\tCursor\tcurl https://cursor.com/install -fsS | bash
        S\thermes\t1\tlinked\tyes\tHermes\tcurl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
        X\tsomething a newer CLI emits
        """
        let rows = SetupRow.parse(text)
        precondition(rows.map { $0.id } == ["claude", "codex", "grok", "cursor", "hermes"])

        // Installed, signed in, but the dot dir is still a real directory: the
        // only sensible next step is to bring it in — never a re-login.
        guard case .adopt? = rows[0].action else { preconditionFailure("claude should adopt") }
        precondition(!rows[0].isReady)

        guard case .signIn? = rows[1].action else { preconditionFailure("codex should sign in") }
        guard case .install(let hint)? = rows[2].action, hint.hasPrefix("https://") else {
            preconditionFailure("grok should install via URL")
        }
        // Unknown sign-in state offers sign-in (idempotent) but doesn't block "ready".
        guard case .signIn? = rows[3].action else { preconditionFailure("cursor should offer sign in") }
        precondition(rows[3].isReady)

        precondition(rows[4].action == nil)
        precondition(rows[4].isReady)
        precondition(rows[4].detail == "Ready")
        precondition(rows[0].detail == "Signed in · not managed yet")
        precondition(rows[2].detail == "Not installed")
    }
}
