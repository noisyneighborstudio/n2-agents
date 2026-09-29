import AppKit
import SwiftUI
import UserNotifications

// The fleet half of the app's side effects. Every function here is one
// `agents fleet …` invocation: the CLI owns enrollment, replication, conflict
// resolution, tool management and dispatch, and this file only carries the
// user's choice to it and the result back. Nothing decides fleet policy.
//
// Two behaviors are deliberate and easy to lose in a refactor:
//   · a fleet read never blocks the panel — each section reads on its own
//     queue, publishes the moment it answers, and gives up after 20 seconds;
//   · the notifier announces a notice exactly once per machine. The feed is
//     durable and re-read every refresh, so without the seen-set every refresh
//     would re-announce finished work.

extension AppDelegate {

    // MARK: - Reading

    /// One fleet read. `status` first: if there is no identity the rest of the
    /// verbs would only print usage errors, so they are not run at all. Then
    /// every section reads at once and publishes the moment it answers; a read
    /// that hangs gives up after 20 seconds and marks only its own section.
    func refreshFleet() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refreshFleet() }
            return
        }
        let requestID = UUID()
        fleetReadID = requestID
        DispatchQueue.global(qos: .utility).async {
            let status = self.runCLI(["fleet", "status", "--no-probe"], timeout: 20)
            let data = FleetData.parseStatus(status.output)
            let understood = status.status == 0 && (data.initialized
                || status.output.trimmingCharacters(in: .whitespacesAndNewlines) == "fleet\tuninitialized")
            DispatchQueue.main.async {
                guard self.fleetReadID == requestID else { return }
                var fleet = self.model.fleet ?? FleetData()
                if !understood {
                    fleet.readError = status.status == 0 ? "Couldn't understand fleet state." : "Couldn't read fleet state."
                } else if !data.initialized {
                    fleet = data
                    fleet.observedAt = Date()
                } else {
                    // Identity and approval requests come from status. Every
                    // other section keeps its last values until its read answers.
                    fleet.readError = nil
                    fleet.initialized = true
                    fleet.machine = data.machine
                    fleet.selfID = data.selfID
                    fleet.pending = data.pending
                    if !fleet.loaded.contains(.machines) { fleet.peers = data.peers }
                    fleet.observedAt = Date()
                    fleet.loading = Set(FleetRead.allCases)
                }
                self.model.fleet = fleet
                self.updateFleetAttention(fleet)
                guard understood && data.initialized else { return }
                for read in FleetRead.allCases {
                    DispatchQueue.global(qos: .utility).async {
                        let change = read.read { self.runCLI($0, timeout: 20) }
                        DispatchQueue.main.async {
                            guard self.fleetReadID == requestID, var fleet = self.model.fleet else { return }
                            fleet.loading.remove(read)
                            if let change {
                                change(&fleet)
                                fleet.loaded.insert(read)
                                fleet.unavailable.remove(read)
                            } else {
                                fleet.unavailable.insert(read)
                            }
                            self.model.fleet = fleet
                            if read == .activity && change != nil { self.announce(fleet.notices) }
                            self.updateFleetAttention(fleet)
                        }
                    }
                }
            }
        }
    }

    /// The menu bar says something only when the fleet needs a person: a
    /// machine waiting for approval, an unresolved conflict, a stranded worker.
    /// Routine dispatch is not an interruption and gets no badge.
    private func updateFleetAttention(_ data: FleetData) {
        guard let button = statusItem.button else { return }
        button.toolTip = data.readError != nil ? "N2 Agents — fleet state unavailable"
            : (data.initialized && data.needsAttention ? "N2 Agents — the fleet needs your attention" : nil)
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

        let attempt = UUID()
        notificationAttempt = attempt
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                guard granted && error == nil else {
                    if self.notificationAttempt == attempt {
                        self.model.fleetNotificationError = "Desktop notifications are unavailable. Check notification permission in System Settings."
                    }
                    return
                }
                let batch = fresh.suffix(5)
                var remaining = batch.count
                var failed = false
                for n in batch {
                    let content = UNMutableNotificationContent()
                    content.title = n.title
                    content.body = n.text
                    content.subtitle = n.task
                    if n.kind == .failed || n.kind == .disconnected { content.sound = .default }
                    center.add(UNNotificationRequest(identifier: "fleet-\(n.id)", content: content, trigger: nil)) { error in
                        DispatchQueue.main.async {
                            failed = failed || error != nil
                            remaining -= 1
                            if remaining == 0 && self.notificationAttempt == attempt {
                                self.model.fleetNotificationError = failed ? "A desktop notification couldn't be submitted." : nil
                            }
                        }
                    }
                }
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
            guard let key = ask("Peer SSH host key", "Paste the output of agents fleet id --host-key from that Mac, obtained through a trusted connection.", placeholder: "ssh-ed25519 …") else { return }
            runInTerminal("\"\(cliPath)\" fleet join --to \(shellQuote(addr)) --host-key \(shellQuote(key))")
        case "ssh":
            guard let addr = ask("Pair over SSH",
                                 "Enter user@host of the Mac to pair with, then the one-time code it printed with “agents fleet invite”.",
                                 placeholder: "seth@192.168.1.20") else { return }
            guard let code = ask("Pairing code", "Paste the one-time code from the other Mac.", placeholder: "") else { return }
            guard let key = ask("Peer SSH host key", "Paste the output of agents fleet id --host-key from that Mac, obtained through a trusted connection.", placeholder: "ssh-ed25519 …") else { return }
            runInTerminal("\"\(cliPath)\" fleet pair --to \(shellQuote(addr)) --code \(shellQuote(code)) --host-key \(shellQuote(key))")
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

    /// The CLI's own ranking for this work, shown on the page before Send —
    /// the estimate the dispatcher will use, not a second one made here.
    func fleetPlan(_ spec: FleetDispatchSpec) {
        model.workDraft.state = .planning
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = self.runCLI(spec.arguments + ["--plan", "--", spec.task])
            DispatchQueue.main.async {
                guard self.model.workDraft.spec?.task == spec.task else { return }   // edited since
                self.model.workDraft.state = plan.status == 0 ? .planned(FleetPlan.parse(plan.output))
                    : .failed(plan.output.isEmpty ? "Couldn't plan this work." : plan.output)
            }
        }
    }

    /// Plans again and sends only when the plan names a machine and agent: an
    /// empty plan (a pin that matches nothing) exits 0 and must not be sent.
    func fleetDispatch(_ spec: FleetDispatchSpec) {
        guard let fleet = model.fleet, fleet.readError == nil, fleet.machinesCurrent else {
            model.workDraft.state = .failed("Wait for the machine list to load before sending work.")
            return
        }
        model.workDraft.state = .sending
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = self.runCLI(spec.arguments + ["--plan", "--", spec.task])
            guard plan.status == 0, FleetDispatchSpec.hasCandidate(plan.output) else {
                DispatchQueue.main.async {
                    self.model.workDraft.state = .failed(plan.output.isEmpty ? "No eligible machine and agent were found." : plan.output)
                }
                return
            }
            let result = self.runCLI(spec.arguments + ["--", spec.task])
            DispatchQueue.main.async {
                self.model.workDraft.state = result.status == 0
                    ? .sent(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                    : .failed(result.output.isEmpty ? "Dispatch refused." : result.output)
                self.refreshFleet()
            }
        }
    }

    func fleetShowTask(_ id: String) {
        dismissPanel()
        let r = runCLI(["fleet", "task", "show", id])
        alert("Task \(id)", r.output.isEmpty ? "No detail recorded for this task." : r.output)
    }

    /// A retry is a new task the user asked for. It is never automatic, and the
    /// CLI links it to the original rather than reusing its identity.
    func fleetRetry(task: String) {
        guard let fleet = model.fleet, fleet.tasksCurrent else {
            alert("Fleet tasks unavailable", "Wait for the task list to load before starting more work.")
            return
        }
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
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.runCLI(["fleet", "task", "reconcile"])
            DispatchQueue.main.async {
                if r.status != 0 { self.alert("Couldn't reconcile tasks", r.output) }
                self.refreshFleet()
            }
        }
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
