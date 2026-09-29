import AppKit

@main struct ClipboardTests {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            if !condition { fatalError(message) }
        }
        // A private pasteboard: the test never touches what the user copied.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("n2-clipboard-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let command = Clipboard.command(profile: "Work Laptop", vendor: "codex")
        check(command == "codex-work laptop", "command is the lab, a dash and the lowercased profile")
        Clipboard.copy(command, to: pasteboard)
        check(pasteboard.string(forType: .string) == "codex-work laptop", "copy puts the exact command on the pasteboard")

        let path = "/Users/me/Library/Application Support/Codex-Work Laptop/ünïcode"
        Clipboard.copy(path, to: pasteboard)
        check(pasteboard.string(forType: .string) == path, "copy puts the exact path, spaces and all")
        check(pasteboard.pasteboardItems?.count == 1, "a copy replaces what was there")
        print("clipboard tests passed")
    }
}
