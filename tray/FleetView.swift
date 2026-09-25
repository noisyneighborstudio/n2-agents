import AppKit
import SwiftUI

// The fleet half of the panel. Every row here renders what a `agents fleet …`
// verb printed and every control calls one back through FleetActions — the CLI
// stays the behavior authority, so no policy decision (who is enrolled, which
// side of a conflict wins, whether an output travels) is ever made in Swift.
//
// Three rules the layout encodes, because they are product decisions and not
// presentation taste:
//   · reachability is not enrollment — a pending machine is its own list with
//     its own Approve, never a peer row with a greyed badge;
//   · a conflict is an unanswered question and an exception is an answered
//     one, so they never share a list;
//   · an unreachable worker is waiting, not failed, and its only offered verb
//     is one the user explicitly chooses.

private enum FM {
    static let side: CGFloat = 13
    static let radius: CGFloat = 8
}

/// What the fleet UI can ask the app to do. Mirrors PanelActions: the view
/// never spawns a process, the delegate does.
protocol FleetActions: AnyObject {
    func fleetInit()
    func fleetEnroll(transport: String)          // "tailscale" | "ssh"
    func fleetApprove(peer: String)
    func fleetDeny(peer: String)
    func fleetRevoke(peer: String)
    func fleetSyncNow()
    func fleetResolve(conflict: String, keepLocal: Bool)
    func fleetExcept(address: String, add: Bool)
    func fleetToolApply(_ name: String?)
    func fleetDispatch()
    func fleetShowTask(_ id: String)
    func fleetRetry(task: String)
    func fleetDistribute(task: String, machine: String?)   // nil = whole fleet
    func fleetReconcileTasks()
    func fleetOpenTerminal(_ argv: [String])
}

// MARK: - Root

struct FleetSection: View {
    @ObservedObject var model: PanelModel
    let actions: FleetActions

    private var fleet: FleetData? { model.fleet }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FleetLabel(title: "Fleet", detail: headline)
            if let fleet, fleet.initialized {
                MachinesBlock(fleet: fleet, model: model, actions: actions)
                SyncBlock(fleet: fleet, actions: actions)
                ToolsBlock(fleet: fleet, actions: actions)
                TasksBlock(fleet: fleet, actions: actions)
                NoticesBlock(fleet: fleet, actions: actions)
            } else if fleet == nil {
                Text("Reading fleet state…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                FleetFirstRun(actions: actions)
            }
        }
        .padding(.horizontal, FM.side)
        .padding(.vertical, 11)
    }

    /// The one-line truth at the top: this machine, and how many others answered.
    private var headline: String {
        guard let fleet, fleet.initialized else { return "" }
        let online = fleet.online.count, others = fleet.others.count
        if others == 0 { return "\(fleet.machine) · only machine" }
        return "\(fleet.machine) · \(online)/\(others) online"
    }
}

/// No identity yet. `fleet status` says `uninitialized` and the panel offers to
/// create one rather than drawing an empty fleet that does not exist.
private struct FleetFirstRun: View {
    let actions: FleetActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This Mac is not in a fleet yet.")
                .font(.system(size: 12, weight: .medium))
            Text("Creating an identity generates a key for this machine. Other Macs still have to be approved before they receive profiles or credentials.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Create Fleet Identity") { actions.fleetInit() }
                .buttonStyle(FleetPill(prominent: true))
        }
    }
}

// MARK: - Machines

private struct MachinesBlock: View {
    let fleet: FleetData
    @ObservedObject var model: PanelModel
    let actions: FleetActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Pending first and separately: a machine that reached us is a
            // question, and putting it in the roster would answer it.
            if !fleet.pending.isEmpty {
                FleetLabel(title: "Waiting for approval", detail: "\(fleet.pending.count)")
                ForEach(fleet.pending) { p in
                    PendingRow(pending: p, actions: actions)
                }
            }
            ForEach(fleet.peers) { peer in
                PeerRow(peer: peer, actions: actions)
            }
            HStack(spacing: 6) {
                Button("Enroll over Tailscale") { actions.fleetEnroll(transport: "tailscale") }
                    .buttonStyle(FleetPill())
                Button("Pair over SSH") { actions.fleetEnroll(transport: "ssh") }
                    .buttonStyle(FleetPill())
            }
        }
    }
}

private struct PendingRow: View {
    let pending: FleetPending
    let actions: FleetActions

    var body: some View {
        FleetCard(tint: Color(nsColor: .systemOrange)) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(verbatim: pending.machine.isEmpty ? "unnamed machine" : pending.machine)
                        .font(.system(size: 12, weight: .medium))
                    if !pending.transport.isEmpty {
                        FleetChip(text: pending.transport)
                    }
                    Spacer()
                }
                // The fingerprint is the identity being approved. It is shown
                // in full so the user can compare it with the other machine —
                // approving a truncated prefix is approving a guess.
                Text(verbatim: pending.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                Text("Approving sends this machine shared profiles and credentials.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Approve") { actions.fleetApprove(peer: pending.id) }
                        .buttonStyle(FleetPill(prominent: true))
                    Button("Deny") { actions.fleetDeny(peer: pending.id) }
                        .buttonStyle(FleetPill())
                }
            }
        }
    }
}

private struct PeerRow: View {
    let peer: FleetPeer
    let actions: FleetActions
    @State private var expanded = false

    var body: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: expanded ? 5 : 0) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        ReachDot(peer: peer)
                        Text(verbatim: peer.machine)
                            .font(.system(size: 12, weight: peer.isSelf ? .semibold : .regular))
                        if peer.isSelf { FleetChip(text: "this Mac") }
                        Spacer()
                        Text(verbatim: statusWord)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    Text(verbatim: peer.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    Text(verbatim: "transport: \(peer.transport)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !peer.isSelf && peer.state == .approved {
                        Button("Revoke Access") { actions.fleetRevoke(peer: peer.id) }
                            .buttonStyle(FleetPill(destructive: true))
                    }
                }
            }
        }
    }

    /// Enrollment state and reachability are different facts and the row says
    /// both: a revoked machine that still answers pings is still revoked.
    private var statusWord: String {
        switch peer.state {
        case .approved: return peer.reach == .`self` ? "" : (peer.isOnline ? "online" : "offline")
        case .pending:  return "awaiting approval"
        case .denied:   return "denied"
        case .revoked:  return "revoked"
        }
    }
}

private struct ReachDot: View {
    let peer: FleetPeer

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    private var color: Color {
        guard peer.state == .approved else { return Color(nsColor: .systemGray) }
        return peer.isOnline ? Color(nsColor: .systemGreen) : Color(nsColor: .systemGray)
    }
}

// MARK: - Sync

private struct SyncBlock: View {
    let fleet: FleetData
    let actions: FleetActions
    @State private var showAuth = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FleetLabel(title: "Shared profile", detail: summary)

            // Conflicts are the only thing in this panel that blocks: they are
            // shown before anything else and cannot be dismissed, only answered.
            ForEach(fleet.conflicts) { c in
                ConflictRow(conflict: c, actions: actions)
            }

            if !fleet.exceptions.isEmpty {
                FleetCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kept local on this Mac")
                            .font(.system(size: 11, weight: .medium))
                        ForEach(fleet.exceptions) { e in
                            HStack(spacing: 6) {
                                Text(verbatim: e.label).font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Share") { actions.fleetExcept(address: e.id, add: false) }
                                    .buttonStyle(FleetPill(small: true))
                            }
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Button("Sync Now") { actions.fleetSyncNow() }.buttonStyle(FleetPill())
                Button(showAuth ? "Hide Sign-in Sharing" : "Sign-in Sharing") { showAuth.toggle() }
                    .buttonStyle(FleetPill())
            }

            if showAuth {
                // Provider honesty lives here. The verdict is the CLI's and the
                // app has no path to upgrade it, so an unverified lab cannot be
                // made to look like it syncs by a newer, friendlier UI.
                FleetCard {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(fleet.sync.auth) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(verbatim: row.vendor).font(.system(size: 11, weight: .medium))
                                    FleetChip(text: row.support.rawValue)
                                    Spacer()
                                    Text(verbatim: row.enabled ? "sharing" : "off")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Text(row.explanation)
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private var summary: String {
        let s = fleet.sync
        if s.conflicts > 0 { return "\(s.conflicts) needs you" }
        if s.resources == 0 { return "nothing shared yet" }
        return s.settled ? "in step" : "\(s.agreed)/\(s.resources) in step"
    }
}

private struct ConflictRow: View {
    let conflict: FleetConflict
    let actions: FleetActions

    var body: some View {
        FleetCard(tint: Color(nsColor: .systemOrange)) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: conflict.label).font(.system(size: 12, weight: .medium))
                Text(explanation)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button(conflict.isDeletion ? "Keep This Mac’s Copy" : "Keep This Mac’s") {
                        actions.fleetResolve(conflict: conflict.id, keepLocal: true)
                    }
                    .buttonStyle(FleetPill())
                    Button(conflict.isDeletion ? "Accept the Deletion" : "Take the Other Mac’s") {
                        actions.fleetResolve(conflict: conflict.id, keepLocal: false)
                    }
                    .buttonStyle(FleetPill())
                }
            }
        }
    }

    /// "Keep mine" means something different when the other side deleted it,
    /// so the sentence changes rather than the buttons quietly meaning more.
    private var explanation: String {
        conflict.isDeletion
            ? "This Mac still has this, and another Mac deleted it while disconnected. Nothing is applied until you choose."
            : "This Mac and another Mac both changed this while disconnected. Nothing is applied until you choose."
    }
}

// MARK: - Managed tools

private struct ToolsBlock: View {
    let fleet: FleetData
    let actions: FleetActions

    var body: some View {
        // The block is absent when nothing is designated. An empty "managed
        // tools" list invites adopting whatever is installed, and designation
        // is the user's authorization, not a default.
        if !fleet.tools.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FleetLabel(title: "Fleet-managed tools", detail: pending == 0 ? "up to date" : "\(pending) pending")
                ForEach(fleet.tools) { tool in
                    FleetCard {
                        HStack(spacing: 6) {
                            Text(verbatim: tool.id).font(.system(size: 12))
                            if !tool.want.isEmpty {
                                Text(verbatim: tool.want)
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(verbatim: word(tool)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                if pending > 0 {
                    Button("Apply Pending Updates") { actions.fleetToolApply(nil) }
                        .buttonStyle(FleetPill())
                }
            }
        }
    }

    private var pending: Int { fleet.tools.filter(\.needsWork).count }

    /// A held update reads as held, never as missing: the fleet defers a
    /// disruptive update around live work rather than killing the work.
    private func word(_ tool: FleetTool) -> String {
        if tool.deferred { return "waiting for running work" }
        switch tool.state {
        case .ok:        return "installed"
        case .pendingApproval: return "needs local approval"
        case .install:   return "will install"
        case .update:    return "will update"
        case .unmanaged: return "not managed here"
        case .invalid:   return "malformed designation"
        }
    }
}

// MARK: - Tasks

private struct TasksBlock: View {
    let fleet: FleetData
    let actions: FleetActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FleetLabel(title: "Tasks", detail: fleet.activeTasks.isEmpty ? "" : "\(fleet.activeTasks.count) running")
            ForEach(fleet.tasks.prefix(6)) { task in
                TaskRow(task: task, fleet: fleet, actions: actions)
            }
            Button("Send Work to Another Mac…") { actions.fleetDispatch() }
                .buttonStyle(FleetPill(prominent: fleet.destinations.count > 1))
                .disabled(fleet.destinations.count < 2)
        }
    }
}

private struct TaskRow: View {
    let task: FleetTask
    let fleet: FleetData
    let actions: FleetActions
    @State private var distributing = false

    var body: some View {
        FleetCard(tint: task.isStranded ? Color(nsColor: .systemOrange) : nil) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(verbatim: task.label.isEmpty ? task.id : task.label)
                        .font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(verbatim: stateWord).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if !task.machine.isEmpty { FleetChip(text: task.machine) }
                    if !task.vendor.isEmpty { FleetChip(text: task.vendor) }
                    Spacer()
                }

                if task.isStranded {
                    // No automatic retry: the machine being unreachable is not
                    // proof the work stopped, so the only path forward is a
                    // choice the user makes with that sentence in front of them.
                    Text("This Mac stopped answering. The task may still be running there, so nothing was started anywhere else.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Run It Somewhere Else") { actions.fleetRetry(task: task.id) }
                        .buttonStyle(FleetPill())
                }

                if task.isFinished {
                    HStack(spacing: 6) {
                        Button("Show Result") { actions.fleetShowTask(task.id) }
                            .buttonStyle(FleetPill(small: true))
                        Button(distributing ? "Cancel" : "Copy Result To…") { distributing.toggle() }
                            .buttonStyle(FleetPill(small: true))
                        Spacer()
                    }
                    if distributing {
                        // Outputs stay where the task put them. This list is
                        // the only way one moves, and it is never pre-selected.
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(fleet.destinations) { peer in
                                Button(peer.isSelf ? "This Mac" : peer.machine) {
                                    distributing = false
                                    actions.fleetDistribute(task: task.id, machine: peer.machine)
                                }
                                .buttonStyle(FleetPill(small: true))
                            }
                            Button("Every Mac in the Fleet") {
                                distributing = false
                                actions.fleetDistribute(task: task.id, machine: nil)
                            }
                            .buttonStyle(FleetPill(small: true))
                        }
                    }
                }
            }
        }
    }

    private var stateWord: String {
        switch task.state {
        case .queued:       return "queued"
        case .preparing:    return "preparing"
        case .transferring: return "sending workspace"
        case .running:      return "running"
        case .done:         return task.succeeded ? "finished" : "finished (exit \(task.rc))"
        case .failed:       return "failed"
        case .disconnected: return "unreachable"
        case .unknown:      return "unknown"
        }
    }
}

// MARK: - Notices

private struct NoticesBlock: View {
    let fleet: FleetData
    let actions: FleetActions

    var body: some View {
        // The durable half of a fleet event. A desktop banner can be missed or
        // suppressed by Focus, so the panel reads the feed and never depends on
        // a banner having landed.
        if !fleet.notices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FleetLabel(title: "Fleet activity", detail: "")
                ForEach(fleet.notices.prefix(5)) { n in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: n.title).font(.system(size: 11))
                        Spacer()
                        Text(verbatim: FleetNoticeTime.string(n.at))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Button("Check in") { actions.fleetReconcileTasks() }.buttonStyle(FleetPill(small: true))
            }
        }
    }
}

enum FleetNoticeTime {
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func string(_ date: Date) -> String { clock.string(from: date) }
}

// MARK: - Controls

private struct FleetLabel: View {
    let title: LocalizedStringKey
    let detail: String

    var body: some View {
        HStack {
            Text(title)
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.55)
            Spacer()
            Text(verbatim: detail).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

private struct FleetCard<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FM.radius, style: .continuous)
                    .fill((tint ?? Color.primary).opacity(tint == nil ? 0.04 : 0.10))
            )
    }
}

private struct FleetChip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(.secondary)
    }
}

private struct FleetPill: ButtonStyle {
    var prominent = false
    var destructive = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 10 : 11, weight: .medium))
            .padding(.horizontal, small ? 7 : 9)
            .padding(.vertical, small ? 3 : 4)
            .foregroundStyle(destructive ? Color(nsColor: .systemRed) : (prominent ? Color.white : Color.primary))
            .background(
                Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.08))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
