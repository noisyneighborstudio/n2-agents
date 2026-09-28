import AppKit

struct SessionTransferPlan {
    let thread: String
    let peer: FleetPeer
    let cwd: String
    struct Refused: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    init(thread: String, vendor: String, peer: FleetPeer, cwd: String) throws {
        guard vendor == "codex", UUID(uuidString: thread) != nil else {
            throw Refused(message: "Only saved, account-bound Codex sessions can be sent to another machine.")
        }
        guard peer.state == .approved, !peer.isSelf,
              peer.id.range(of: "^SHA256:[A-Za-z0-9+/]{43}$", options: .regularExpression) != nil else {
            throw Refused(message: "Choose an approved fleet machine.")
        }
        guard cwd.hasPrefix("/"), !cwd.contains("\0"), !cwd.contains("\n"), !cwd.contains("\r") else {
            throw Refused(message: "Enter an absolute destination directory, beginning with /.")
        }
        self.thread = thread; self.peer = peer; self.cwd = cwd
    }
    var arguments: [String] { ["fleet", "session", "send", thread, "--peer", peer.id, "--cwd", cwd] }
    func receipt(status: Int32, output: String) throws -> String {
        guard status == 0 else { throw Refused(message: "Transfer could not be confirmed. Check that the destination is reachable, the directory exists, and the original account is available there. Check the destination before retrying.") }
        guard let data = output.data(using: .utf8), data.count <= 65536,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["status"] as? String == "saved", value["thread"] as? String == thread,
              let destination = value["cwd"] as? String, destination.hasPrefix("/"),
              !destination.contains("\0"), !destination.contains("\n"), !destination.contains("\r") else {
            throw Refused(message: "The destination did not confirm this saved session. Check it before retrying.")
        }
        return "Saved on \(peer.machine) at \(destination). The session keeps its original account. Open N2 Agents there to resume it."
    }
    @MainActor static func prompt(title: String, peers: [FleetPeer], cwd: String?) -> (NSAlert, NSPopUpButton, NSTextField) {
        let alert = NSAlert(); alert.messageText = "Send saved session?"
        alert.informativeText = "\(title)\n\nChoose an approved machine and the directory to use there. This copies saved history and keeps the original account. It does not move a running agent or copy workspace files."
        alert.addButton(withTitle: "Send"); alert.addButton(withTitle: "Cancel")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 110))
        let peerLabel = NSTextField(labelWithString: "Destination machine")
        peerLabel.frame = NSRect(x: 0, y: 88, width: 410, height: 18)
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 57, width: 410, height: 28), pullsDown: false)
        picker.addItems(withTitles: peers.map { "\($0.machine) · \($0.id.prefix(19))…" })
        let pathLabel = NSTextField(labelWithString: "Directory on that machine")
        pathLabel.frame = NSRect(x: 0, y: 32, width: 410, height: 18)
        let path = NSTextField(string: cwd ?? ""); path.placeholderString = "/Users/you/project"
        path.frame = NSRect(x: 0, y: 0, width: 410, height: 24)
        for child in [peerLabel, picker, pathLabel, path] { view.addSubview(child) }
        alert.accessoryView = view; return (alert, picker, path)
    }
}

@MainActor final class SessionTransferCoordinator {
    private(set) var isRunning = false
    func perform(thread: String, vendor: String,
                 run: @escaping @Sendable ([String]) -> (Int32, String),
                 choose: @MainActor ([FleetPeer]) -> (FleetPeer, String)?,
                 finish: @MainActor (String) -> Void, fail: @MainActor (String) -> Void) async {
        guard !isRunning else { fail("A session transfer is already in progress."); return }
        isRunning = true; defer { isRunning = false }
        func command(_ args: [String]) async -> (Int32, String) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: run(args)) }
            }
        }
        do {
            guard vendor == "codex", UUID(uuidString: thread) != nil else {
                throw SessionTransferPlan.Refused(message: "Only saved, account-bound Codex sessions can be sent to another machine.")
            }
            let response = await command(["fleet", "peers", "--no-probe"])
            guard !Task.isCancelled else { return }
            guard response.0 == 0 else { throw SessionTransferPlan.Refused(message: "Could not read approved fleet machines.") }
            let peers = FleetPeer.parse(response.1).filter { $0.state == .approved && !$0.isSelf }
            guard !peers.isEmpty else { throw SessionTransferPlan.Refused(message: "No other approved fleet machines are available. Add or approve a machine in Fleet settings first.") }
            guard let (peer, cwd) = choose(peers), !Task.isCancelled else { return }
            guard peers.contains(peer) else { throw SessionTransferPlan.Refused(message: "The selected machine was not in the approved list.") }
            let plan = try SessionTransferPlan(thread: thread, vendor: vendor, peer: peer, cwd: cwd)
            let sent = await command(plan.arguments)
            finish(try plan.receipt(status: sent.0, output: sent.1))
        } catch { fail(error.localizedDescription) }
    }
}
