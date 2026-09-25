import AppKit
import SwiftUI
import UserNotifications

// The fleet half of the app's side effects. Every function here is one
// `agents fleet …` invocation: the CLI owns enrollment, replication, conflict
// resolution, tool management and dispatch, and this file only carries the
// user's choice to it and the result back. Nothing decides fleet policy.
//
// Two behaviors are deliberate and easy to lose in a refactor:
//   · a fleet read never blocks the panel — it runs on its own queue beside
//     the profile read, and publishes whether or not the CLI answered;
//   · the notifier announces a notice exactly once per machine. The feed is
//     durable and re-read every refresh, so without the seen-set every refresh
//     would re-announce finished work.

extension AppDelegate {

    // MARK: - Reading

    /// One fleet read. `status` first: if there is no identity the rest of the
    /// verbs would only print usage errors, so they are not run at all.
    func refreshFleet() {
        DispatchQueue.global(qos: .utility).async {
            let status = self.runCLI(["fleet", "status", "--no-probe"])
            guard status.status == 0 else { return }
            var data = FleetData.parseStatus(status.output)
            if data.initialized {
                // Probed peers separately: reachability is the slow part, and
                // a stale roster beside fresh probes is still one consistent
                // read because both come from this pass.
                let probed = self.runCLI(["fleet", "peers"])
                if probed.status == 0 {
                    let peers = FleetPeer.parse(probed.output)
                    if !peers.isEmpty { data.peers = peers }
                }
                data.sync = FleetSync.parse(self.runCLI(["fleet", "sync", "status"]).output)
                data.conflicts = FleetConflict.parse(self.runCLI(["fleet", "sync", "conflicts"]).output)
                data.exceptions = FleetException.parse(self.runCLI(["fleet", "sync", "except", "list"]).output)
                data.tools = FleetTool.join(list: self.runCLI(["fleet", "tools", "list"]).output,
                                            status: self.runCLI(["fleet", "tools", "status"]).output,
                                            deferred: self.runCLI(["fleet", "tools", "deferred"]).output)
                data.tasks = FleetTask.parse(self.runCLI(["fleet", "task", "list"]).output)
                data.notices = FleetNotice.parse(self.runCLI(["fleet", "task", "notices"]).output)
            }
            DispatchQueue.main.async {
                self.model.fleet = data
                self.announce(data.notices)
                self.updateFleetAttention(data)
            }
        }
    }

    /// The menu bar says something only when the fleet needs a person: a
    /// machine waiting for approval, an unresolved conflict, a stranded worker.
    /// Routine dispatch is not an interruption and gets no badge.
    private func updateFleetAttention(_ data: FleetData) {
        guard let button = statusItem.button else { return }
        button.toolTip = data.initialized && data.needsAttention
            ? "N2 Agents — the fleet needs your attention" : nil
    }

    // MARK: - Native notifications

    /// Fires a desktop banner per new notice. `UNUserNotificationCenter`
    /// requires a bundle identifier — running the binary straight out of
    /// `.build` has none and would trap, so an unbundled run degrades to the
    /// in-panel feed instead of crashing. That is a real limitation of a
    /// non-bundled run, not a fallback that hides a failure.
    func announce(_ notices: [FleetNotice]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        // The seen-set and the first-read rule live in FleetAnnouncer so they
        // can be tested without a bundle; this function only carries the
        // result to the notification center.
        let fresh = announcer.adopt(notices)
        guard !fresh.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for n in fresh.suffix(5) {
                let content = UNMutableNotificationContent()
                content.title = n.title
                content.body = n.text
                content.subtitle = n.task
                if n.kind == .failed || n.kind == .disconnected { content.sound = .default }
                center.add(UNNotificationRequest(identifier: "fleet-\(n.id)",
                                                 content: content, trigger: nil))
            }
        }
    }

    // MARK: - Enrollment

    func fleetInit() {
        let r = runCLI(["fleet", "init"])
        if r.status != 0 { alert("Couldn't create a fleet identity", r.output) }
        refreshFleet()
    }

    /// Enrollment is a multi-step exchange with a pairing code and a host key,
    /// and every step can ask a question. It runs in Terminal on purpose: the
    /// operator sees the fingerprint they are approving rather than a spinner.
    func fleetEnroll(transport: String) {
        dismissPanel()
        switch transport {
        case "tailscale":
            guard let addr = ask("Join a fleet over Tailscale",
                                 "Enter the Tailscale hostname of a Mac already in the fleet. It still has to approve this machine before any profile or credential moves.",
                                 placeholder: "seths-mac-mini") else { return }
            runInTerminal("\"\(cliPath)\" fleet join --to \(shellQuote(addr))")
        case "ssh":
            guard let addr = ask("Pair over SSH",
                                 "Enter user@host of the Mac to pair with, then the one-time code it printed with “agents fleet invite”.",
                                 placeholder: "seth@192.168.1.20") else { return }
            guard let code = ask("Pairing code", "Paste the one-time code from the other Mac.", placeholder: "") else { return }
            runInTerminal("\"\(cliPath)\" fleet pair --to \(shellQuote(addr)) --code \(shellQuote(code))")
        default:
            break
        }
    }

    func fleetApprove(peer: String) {
        dismissPanel()
        let confirm = NSAlert()
        confirm.messageText = "Approve this machine?"
        confirm.informativeText = "Approving \(peer) lets it receive shared profiles, skills and credentials. Only approve it if this fingerprint matches the one shown on that Mac."
        confirm.addButton(withTitle: "Approve")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let r = runCLI(["fleet", "approve", peer])
        if r.status != 0 { alert("Approval failed", r.output) }
        refreshFleet()
    }

    func fleetDeny(peer: String) {
        let r = runCLI(["fleet", "deny", peer])
        if r.status != 0 { alert("Couldn't deny that machine", r.output) }
        refreshFleet()
    }

    func fleetRevoke(peer: String) {
        dismissPanel()
        let confirm = NSAlert()
        confirm.messageText = "Remove this machine from the fleet?"
        confirm.informativeText = "It stops receiving profiles and credentials and can no longer reach this Mac. Anything already on it stays there — revoking is not a remote wipe."
        confirm.addButton(withTitle: "Remove")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let r = runCLI(["fleet", "revoke", "--propagate", peer])
        if r.status != 0 { alert("Revocation failed", r.output) }
        refreshFleet()
    }

    // MARK: - Sync, conflicts, exceptions

    func fleetSyncNow() {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.runCLI(["fleet", "sync", "now"])
            DispatchQueue.main.async {
                if r.status != 0 { self.alert("Sync didn't finish", r.output) }
                self.refreshFleet()
            }
        }
    }

    /// The user's choice, carried verbatim. The app never picks a side and
    /// never resolves on a timer — an unresolved conflict stays visible.
    func fleetResolve(conflict: String, keepLocal: Bool) {
        let r = runCLI(["fleet", "sync", "resolve", conflict, keepLocal ? "--local" : "--remote"])
        if r.status != 0 { alert("Couldn't record that choice", r.output) }
        refreshFleet()
    }

    /// An exception address is `class|profile|vendor|glob`; `except add` takes
    /// those as positional words, and `except rm` takes the index the CLI
    /// listed. Both directions go through the CLI's own parser.
    func fleetExcept(address: String, add: Bool) {
        let parts = address.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let r: (status: Int32, output: String)
        if add {
            guard parts.count >= 3 else { return }
            r = runCLI(["fleet", "sync", "except", "add"] + parts)
        } else {
            // Re-read rather than trusting the last refresh: the number is a
            // position in the CLI's file, and another machine's sync may have
            // moved it since the panel drew.
            let rows = FleetException.parse(runCLI(["fleet", "sync", "except", "list"]).output)
            guard let row = rows.first(where: { $0.id == address })
            else { alert("Couldn't withdraw that exception", "It is no longer in the list."); return }
            r = runCLI(["fleet", "sync", "except", "rm", String(row.index)])
        }
        if r.status != 0 { alert(add ? "Couldn't add that exception" : "Couldn't withdraw that exception", r.output) }
        refreshFleet()
    }

    // MARK: - Managed tools

    /// Only designated tools are touched: `apply` walks the manifest, and a
    /// named install refuses anything unmanaged in the CLI itself. The app has
    /// no code path that installs software the user did not designate.
    func fleetToolApply(_ name: String?) {
        DispatchQueue.global(qos: .utility).async {
            let r = name.map { self.runCLI(["fleet", "tools", "install", $0]) }
                ?? self.runCLI(["fleet", "tools", "apply"])
            DispatchQueue.main.async {
                if r.status != 0 { self.alert("Some managed tools didn't apply", r.output) }
                self.refreshFleet()
            }
        }
    }

    // MARK: - Dispatch and tasks

    /// Asks for the work and the pins, then shows the CLI's own ranking before
    /// anything is sent — the estimate the dispatcher will use, not a second
    /// estimate computed here.
    func fleetDispatch() {
        dismissPanel()
        guard let fleet = model.fleet, fleet.initialized else { return }
        guard let command = ask("Send work to another Mac",
                                "The command runs on the machine the fleet picks. Add a pin below to force one.",
                                placeholder: "npm test") else { return }
        var args = ["fleet", "task", "run", "--label", "Panel dispatch"]
        if let pin = pinChoice(fleet) { args += pin }
        let plan = runCLI(args + ["--plan", "--"] + [command])
        // An unsatisfiable pin — a machine that is not in the fleet, an agent
        // no eligible machine has — plans nothing and still exits 0. Offering
        // "Send" there would dispatch work that is already refused, so an empty
        // plan ends the flow instead of becoming a button.
        guard plan.status == 0, !plan.output.isEmpty else {
            alert("Nothing can run this",
                  plan.output.isEmpty
                    ? "No machine in the fleet is eligible for this task with those pins. Remove a pin, or bring the machine you pinned online."
                    : plan.output)
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Send this work?"
        confirm.informativeText = plan.output
        confirm.addButton(withTitle: "Send")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.runCLI(args + ["--"] + [command])
            DispatchQueue.main.async {
                if r.status != 0 { self.alert("Dispatch refused", r.output) }
                self.refreshFleet()
            }
        }
    }

    /// Machine, agent, both, or neither — the four pins the CLI accepts, asked
    /// in one sheet so "both" is a single decision. The agent list is the labs
    /// actually installed here; the machine list is only the peers that could
    /// take work. Leaving a row on "let the fleet choose" sends no flag at all,
    /// so the dispatcher still ranks that dimension.
    private func pinChoice(_ fleet: FleetData) -> [String]? {
        let machines = fleet.destinations.map(\.machine)
        let agents = model.data?.snapshot.installedVendors.map(\.id) ?? []
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 58))
        let machinePop = NSPopUpButton(frame: NSRect(x: 0, y: 33, width: 280, height: 25))
        machinePop.addItem(withTitle: "Let the fleet choose the Mac")
        machines.forEach { machinePop.addItem(withTitle: "Pin to \($0)") }
        let agentPop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 25))
        agentPop.addItem(withTitle: "Let the fleet choose the agent")
        agents.forEach { agentPop.addItem(withTitle: "Pin to \($0)") }
        box.addSubview(machinePop)
        box.addSubview(agentPop)

        let alert = NSAlert()
        alert.messageText = "Where should this run?"
        alert.informativeText = "Pinning skips the speed comparison for whatever you pin. Pin both and only that pairing is considered."
        alert.accessoryView = box
        alert.addButton(withTitle: "Continue")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()

        let m = machinePop.indexOfSelectedItem
        let a = agentPop.indexOfSelectedItem
        let pins = FleetPins.flags(machine: m > 0 && m - 1 < machines.count ? machines[m - 1] : nil,
                                   agent: a > 0 && a - 1 < agents.count ? agents[a - 1] : nil)
        return pins.isEmpty ? nil : pins
    }

    func fleetShowTask(_ id: String) {
        dismissPanel()
        let r = runCLI(["fleet", "task", "show", id])
        alert("Task \(id)", r.output.isEmpty ? "No detail recorded for this task." : r.output)
    }

    /// A retry is a new task the user asked for. It is never automatic, and the
    /// CLI links it to the original rather than reusing its identity.
    func fleetRetry(task: String) {
        dismissPanel()
        let confirm = NSAlert()
        confirm.messageText = "Run this work somewhere else?"
        confirm.informativeText = "The original task may still be running on the machine that stopped answering. This starts a second, separate task — it does not cancel the first."
        confirm.addButton(withTitle: "Run It Again")
        confirm.addButton(withTitle: "Keep Waiting")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let r = runCLI(["fleet", "task", "retry", task])
        if r.status != 0 { alert("Retry refused", r.output) }
        refreshFleet()
    }

    /// Distribution is two explicit steps: pull this task's outputs here, then
    /// push them where the user named. Nothing moves without this call.
    func fleetDistribute(task: String, machine: String?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = NSTemporaryDirectory() + "n2-out-\(task)"
            try? FileManager.default.removeItem(atPath: dir)
            let fetched = self.runCLI(["fleet", "task", "fetch", task, dir])
            guard fetched.status == 0 else {
                DispatchQueue.main.async { self.alert("Couldn't collect the results", fetched.output) }
                return
            }
            let target = machine.map { ["--machine", $0] } ?? ["--all"]
            let r = self.runCLI(["fleet", "task", "distribute", dir, "--name", "task-\(task)"] + target)
            DispatchQueue.main.async {
                if r.status != 0 { self.alert("Couldn't distribute the results", r.output) }
                else { self.alert("Results copied", r.output.isEmpty ? "Delivered." : r.output) }
                self.refreshFleet()
            }
        }
    }

    /// Re-probes every task that has not reached a terminal state and updates
    /// the feed from what the workers actually report. It is deliberately not
    /// a "clear": reconciling can *append* notices (a task that finished while
    /// its machine was unreachable), and the CLI has no verb that discards the
    /// feed. Labelling it "Clear" promised the opposite of what it does.
    func fleetReconcileTasks() {
        let r = runCLI(["fleet", "task", "reconcile"])
        if r.status != 0 { alert("Couldn't reconcile tasks", r.output) }
        refreshFleet()
    }

    func fleetOpenTerminal(_ argv: [String]) {
        dismissPanel()
        runInTerminal(([cliPath] + argv).map(shellQuote).joined(separator: " "))
    }

    // MARK: - Small helpers

    private func ask(_ title: String, _ body: String, placeholder: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
