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
            if let error = model.fleetNotificationError {
                Text(error + " Task activity remains available below.")
                    .font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = fleet?.readError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error).foregroundStyle(Color(nsColor: .systemOrange))
                    if let observed = fleet?.observedAt {
                        Text("Showing last known state from \(observed.formatted(date: .omitted, time: .shortened)). Sending work is paused.")
                    } else {
                        Text("Fleet state is unavailable. Waiting for a successful refresh.")
                    }
                }
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            }
            if let fleet, fleet.initialized {
                HStack(spacing: 6) {
                    Button("Enroll over Tailscale") { actions.fleetEnroll(transport: "tailscale") }
                        .buttonStyle(FleetPill())
                    Button("Pair over SSH") { actions.fleetEnroll(transport: "ssh") }
                        .buttonStyle(FleetPill())
                }
                SyncBlock(fleet: fleet, actions: actions)
                ToolsBlock(fleet: fleet, actions: actions)
            } else if fleet == nil {
                Text("Reading fleet state…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if fleet?.readError == nil {
                FleetFirstRun(actions: actions)
            }
        }
        .padding(.horizontal, FM.side)
        .padding(.vertical, 11)
    }

    /// The one-line truth at the top: this machine, and how many others answered.
    private var headline: String {
        guard let fleet else { return "" }
        if fleet.readError != nil { return "unavailable" }
        guard fleet.initialized else { return "" }
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

/// A section's own loading or unavailable line. Draws nothing once the
/// section's read has answered.
private struct FleetReadState: View {
    let fleet: FleetData
    let read: FleetRead

    var body: some View {
        if let text = fleet.state(read) {
            HStack(spacing: 6) {
                if fleet.loading.contains(read) { ProgressView().controlSize(.small) }
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
            FleetReadState(fleet: fleet, read: .sync)

            FleetReadState(fleet: fleet, read: .exceptions)
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
        guard fleet.loaded.contains(.sync) else { return "" }
        if s.conflicts > 0 { return "\(s.conflicts) needs you" }
        if s.resources == 0 { return "nothing shared yet" }
        return s.settled ? "in step" : "\(s.agreed)/\(s.resources) in step"
    }
}

struct ConflictRow: View {
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
        if !fleet.tools.isEmpty || fleet.state(.tools) != nil {
            VStack(alignment: .leading, spacing: 6) {
                FleetLabel(title: "Fleet-managed tools", detail: fleet.tools.isEmpty ? "" : pending == 0 ? "up to date" : "\(pending) pending")
                FleetReadState(fleet: fleet, read: .tools)
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

enum FleetNoticeTime {
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func string(_ date: Date) -> String { clock.string(from: date) }
}

// MARK: - Root: banners and Other Macs

// Only what another Mac is waiting on: one asking to join, a sync conflict.
// Each is answered from the banner or the page it opens, never dismissed.
struct FleetBanners: View {
    @ObservedObject var model: PanelModel
    let actions: FleetActions

    var body: some View {
        if let fleet = model.fleet, fleet.initialized {
            VStack(spacing: 8) {
                ForEach(fleet.pending) { p in
                    Banner(symbol: "desktopcomputer.and.arrow.down", ink: Ink.link,
                           title: String(localized: "\(p.machine.isEmpty ? "A Mac" : p.machine) wants to join", comment: "Banner: a Mac asks to join the fleet"),
                           detail: String(localized: "Approving sends it shared profiles and credentials. Approve only if this fingerprint matches the one on that Mac.",
                                          comment: "Banner: what approving does"),
                           code: p.id) {
                        Button(String(localized: "Deny", comment: "Banner: refuse the Mac")) { actions.fleetDeny(peer: p.id) }
                            .buttonStyle(BannerButton())
                        Button(String(localized: "Approve…", comment: "Banner: approve the Mac, after confirming")) { actions.fleetApprove(peer: p.id) }
                            .buttonStyle(BannerButton(prominent: true))
                    }
                }
                ForEach(fleet.tasks.filter(\.isStranded)) { t in
                    Banner(symbol: "wifi.slash", ink: Ink.amber,
                           title: String(localized: "\(t.label.isEmpty ? t.id : t.label) isn’t answering", comment: "Banner: a task's worker stopped answering"),
                           detail: String(localized: "\(t.machine) stopped answering. The task may still be running there, so nothing was started anywhere else.",
                                          comment: "Banner: what not answering means")) {
                        Button(String(localized: "Review", comment: "Banner: open the task")) { model.push(.task(t.id)) }
                            .buttonStyle(BannerButton(prominent: true))
                    }
                }
                if !fleet.conflicts.isEmpty {
                    Banner(symbol: "arrow.triangle.2.circlepath", ink: Ink.amber,
                           title: inflected("^[\(fleet.conflicts.count) sync conflict](inflect: true) to answer", comment: "Banner: sync conflicts"),
                           detail: String(localized: "This Mac and another changed the same thing while apart. Nothing is applied until you choose.",
                                          comment: "Banner: what a conflict is")) {
                        Button(String(localized: "Review", comment: "Banner: open the conflicts")) { model.push(.conflicts) }
                            .buttonStyle(BannerButton(prominent: true))
                    }
                }
            }
        }
    }
}

struct Banner<Actions: View>: View {
    let symbol: String
    let ink: Color
    let title: String
    let detail: String
    /// An identity to compare, in full: approving a truncated one is approving a guess.
    var code: String? = nil
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(ink).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                    Text(verbatim: detail).font(.system(size: 11.5)).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let code {
                        Text(verbatim: code).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 2)
                    }
                }
            }
            HStack(spacing: 8) { Spacer(); actions }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ink.opacity(0.45), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

struct BannerButton: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? .white : destructive ? Ink.red : .primary)
            .padding(.horizontal, 12).frame(height: 26)
            .background(Capsule().fill(prominent ? Ink.chip : Ink.raised))
            .overlay(Capsule().strokeBorder(prominent ? .clear : Ink.raisedEdge, lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// A machine's one line: whether it answers, and what it's doing.
enum MachineWord {
    static func of(_ peer: FleetPeer, tasks: [FleetTask]) -> (text: String, ink: Color) {
        switch peer.state {
        case .pending: return (String(localized: "awaiting approval", comment: "Machine status"), Ink.secondary)
        case .denied: return (String(localized: "denied", comment: "Machine status"), Ink.secondary)
        case .revoked: return (String(localized: "removed", comment: "Machine status"), Ink.secondary)
        case .approved: break
        }
        guard peer.isOnline else { return (String(localized: "offline", comment: "Machine status"), Ink.secondary) }
        let running = tasks.filter { $0.machine == peer.machine && !$0.isFinished && !$0.isStranded }.count
        return running > 0
            ? (inflected("^[\(running) task](inflect: true) running", comment: "Machine status: tasks running there"), Ink.secondary)
            : (String(localized: "online", comment: "Machine status"), Ink.secondary)
    }
}

// The rest of the fleet, one row per Mac; a row opens its Machine page.
struct OtherMacsSection: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if let fleet = model.fleet, fleet.initialized || fleet.readError != nil {
            VStack(spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "desktopcomputer").font(.system(size: 12))
                    Text("Other Macs", comment: "Root: the section for the fleet's other Macs")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.primary.opacity(0.8))
                    Spacer(minLength: 6)
                    Text(verbatim: summary(fleet)).monospacedDigit()
                }
                .font(.system(size: 11.5)).foregroundStyle(Ink.secondary)
                .padding(.horizontal, 4).frame(height: 30)
                if let error = fleet.readError {
                    Text(verbatim: error).font(.system(size: 11.5)).foregroundStyle(Ink.amber)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                }
                if let state = fleet.state(.machines) {
                    Text(verbatim: state).font(.system(size: 11.5)).foregroundStyle(Ink.secondary).padding(.horizontal, 4)
                }
                ForEach(fleet.others.filter { $0.state == .approved || $0.state == .revoked }) { peer in
                    let word = MachineWord.of(peer, tasks: fleet.tasks)
                    Button { model.push(.machine(peer.id)) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer").font(.system(size: 14)).foregroundStyle(Ink.secondary).frame(width: 20)
                            Text(verbatim: peer.machine).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                            Circle().fill(peer.isOnline && peer.state == .approved ? Ink.green : Ink.tertiary).frame(width: 6, height: 6)
                            Text(verbatim: word.text).font(.system(size: 12)).foregroundStyle(word.ink).lineLimit(1)
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.tertiary)
                        }
                        .padding(.horizontal, 10).frame(height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(radius: 8))
                    .accessibilityLabel("\(peer.machine), \(word.text)")
                }
                if fleet.initialized, fleet.others.isEmpty, fleet.readError == nil {
                    Text("No other Macs yet. Add one from the + menu.", comment: "Other Macs: empty")
                        .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).padding(.horizontal, 4)
                }
            }
        }
    }

    private func summary(_ fleet: FleetData) -> String {
        guard fleet.readError == nil else { return String(localized: "unavailable", comment: "Other Macs: the fleet read failed") }
        let approved = fleet.others.filter { $0.state == .approved }
        return String(localized: "\(approved.filter(\.isOnline).count) of \(approved.count) online", comment: "Other Macs: how many answer")
    }
}

// One Mac: whether it answers and how, its identity, the work on it, what
// it did lately. Check In asks every unfinished task what it's doing.
struct MachinePage: View {
    @ObservedObject var model: PanelModel
    let actions: FleetActions
    let peer: FleetPeer

    var body: some View {
        let fleet = model.fleet ?? FleetData()
        let word = MachineWord.of(peer, tasks: fleet.tasks)
        let tasks = fleet.tasks.filter { $0.machine == peer.machine }
        let activity = fleet.notices.filter { $0.machine == peer.machine }.prefix(5)
        VStack(alignment: .leading, spacing: 0) {
            NavBar(title: peer.machine, back: { model.pop() }) {
                Text(verbatim: model.parentTitle).font(.system(size: 13)).foregroundStyle(Ink.link).lineLimit(1)
            } trailing: { EmptyView() }
            FittingScroll(maxHeight: PanelView.bodyLimit) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.system(size: 22)).foregroundStyle(Ink.logo)
                            .frame(width: 48, height: 48)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.tile))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: peer.machine).font(.system(size: 17, weight: .semibold))
                            HStack(spacing: 6) {
                                Circle().fill(peer.isOnline && peer.state == .approved ? Ink.green : Ink.tertiary).frame(width: 6, height: 6)
                                Text(verbatim: word.text)
                                Text(verbatim: "·")
                                Text(verbatim: peer.transport)
                            }
                            .font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                        }
                    }
                    group(String(localized: "Identity", comment: "Machine page section")) {
                        Text(verbatim: peer.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !tasks.isEmpty {
                        group(String(localized: "Tasks", comment: "Machine page section")) {
                            ForEach(tasks.prefix(5)) { t in
                                HStack {
                                    Text(verbatim: t.label.isEmpty ? t.id : t.label).font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                    Text(verbatim: t.state.rawValue).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                                }
                                .padding(.horizontal, 12).frame(height: 36)
                            }
                        }
                    }
                    group(String(localized: "Recent activity", comment: "Machine page section")) {
                        if activity.isEmpty {
                            Text("Nothing lately.", comment: "Machine page: no activity").font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(Array(activity)) { n in
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: n.title).font(.system(size: 12.5)).lineLimit(1)
                                Spacer()
                                Text(verbatim: FleetNoticeTime.string(n.at)).font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                            }
                            .padding(.horizontal, 12).frame(height: 32)
                        }
                    }
                    HStack(spacing: 8) {
                        // Re-probes unfinished tasks; it can add activity, and never clears any.
                        Button(String(localized: "Check In", comment: "Machine page: ask unfinished tasks for their state")) {
                            actions.fleetReconcileTasks()
                        }
                        .buttonStyle(BannerButton())
                        Spacer()
                        if peer.state == .approved {
                            Button(String(localized: "Remove from Fleet…", comment: "Machine page: revoke this Mac")) {
                                actions.fleetRevoke(peer: peer.id)
                            }
                            .buttonStyle(BannerButton(destructive: true))
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).textCase(.uppercase).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.tertiary)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10).fill(Ink.surface))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

extension FleetTask.Look {
    var ink: Color {
        switch self {
        case .done: return Ink.green
        case .doneWithExit: return Ink.yellow
        case .failed: return Ink.red
        case .notAnswering: return Ink.amber
        case .running, .moving: return Ink.link
        case .waiting, .unknown: return Ink.secondary
        }
    }
}

// The fleet's newest work: three rows, each a status shape and a word; the
// header counts what's live and links to sending more.
struct TasksSection: View {
    @ObservedObject var model: PanelModel
    let actions: FleetActions

    var body: some View {
        if let fleet = model.fleet, fleet.initialized {
            VStack(spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "paperplane").font(.system(size: 12))
                    Text("Tasks", comment: "Root: the fleet's tasks").font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.8))
                    Text(verbatim: fleet.taskSummary.map { "\($0.count) \(Self.noun($0.look))" }.joined(separator: " · "))
                        .monospacedDigit().lineLimit(1)
                    Spacer(minLength: 6)
                    Button(String(localized: "Send Work…", comment: "Tasks: compose work for another Mac")) { actions.fleetDispatch() }
                        .buttonStyle(.plain).foregroundStyle(Ink.link)
                        .disabled(fleet.destinations.count < 2)
                        .opacity(fleet.destinations.count < 2 ? 0.5 : 1)
                        .help(fleet.destinations.count < 2
                              ? String(localized: "No other Mac can take work right now", comment: "Send Work help, disabled")
                              : String(localized: "Send work to another Mac", comment: "Send Work help"))
                }
                .font(.system(size: 11.5)).foregroundStyle(Ink.secondary)
                .padding(.horizontal, 4).frame(height: 30)
                if let error = model.fleetNotificationError {
                    Text(verbatim: error).font(.system(size: 11.5)).foregroundStyle(Ink.amber)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                }
                if let state = fleet.state(.tasks) {
                    Text(verbatim: state).font(.system(size: 11.5)).foregroundStyle(Ink.secondary).padding(.horizontal, 4)
                }
                ForEach(fleet.tasks.prefix(3)) { t in
                    Button { model.push(.task(t.id)) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: t.symbol).font(.system(size: 15)).foregroundStyle(t.look.ink).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: t.label.isEmpty ? t.id : t.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                HStack(spacing: 4) {
                                    if !t.machine.isEmpty { Text("on \(t.machine)", comment: "Task row: where it runs") }
                                    if let at = fleet.lastSeen(t) { Text(verbatim: "· \(FleetNoticeTime.string(at))") }
                                }
                                .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(verbatim: t.word).font(.system(size: 12)).foregroundStyle(t.look.ink).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.tertiary)
                        }
                        .padding(.horizontal, 10).frame(height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(radius: 8))
                    .accessibilityLabel("\(t.label.isEmpty ? t.id : t.label), \(t.word)")
                }
            }
        }
    }

    static func noun(_ look: FleetTask.Look) -> String {
        switch look {
        case .running, .moving: return String(localized: "running", comment: "Tasks header count")
        case .waiting: return String(localized: "queued", comment: "Tasks header count")
        case .notAnswering: return String(localized: "not answering", comment: "Tasks header count")
        case .failed: return String(localized: "failed", comment: "Tasks header count")
        case .doneWithExit: return String(localized: "exited", comment: "Tasks header count")
        case .done, .unknown: return ""
        }
    }
}

// One task: what it is and where, the action that fits its state first,
// what happened to it, and its raw facts.
struct TaskPage: View {
    @ObservedObject var model: PanelModel
    let actions: FleetActions
    let task: FleetTask

    var body: some View {
        let fleet = model.fleet ?? FleetData()
        let timeline = fleet.notices.filter { $0.task == task.id }.sorted { $0.at > $1.at }
        VStack(alignment: .leading, spacing: 0) {
            NavBar(title: String(localized: "Task", comment: "Task page title"), back: { model.pop() }) {
                Text(verbatim: model.parentTitle).font(.system(size: 13)).foregroundStyle(Ink.link).lineLimit(1)
            } trailing: { EmptyView() }
            FittingScroll(maxHeight: PanelView.bodyLimit) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 8) {
                        Image(systemName: task.symbol).font(.system(size: 26)).foregroundStyle(task.look.ink)
                            .frame(width: 56, height: 56)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Ink.tile))
                        Text(verbatim: task.label.isEmpty ? task.id : task.label)
                            .font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center)
                        HStack(spacing: 4) {
                            Text(verbatim: task.word).foregroundStyle(task.look.ink)
                            if !task.machine.isEmpty { Text("on \(task.machine)", comment: "Task page: where it runs") }
                            if let vendor = model.data?.snapshot.vendor(task.vendor)?.label ?? (task.vendor.isEmpty ? nil : task.vendor) {
                                Text(verbatim: "· \(vendor)")
                            }
                        }
                        .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                        if task.isStranded {
                            Text("\(task.machine) stopped answering. The task may still be running there, so nothing was started anywhere else.",
                                 comment: "Task page: what not answering means")
                                .font(.system(size: 12)).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    actionsBlock(fleet)
                    section(String(localized: "Timeline", comment: "Task page section")) {
                        if timeline.isEmpty {
                            Text("Nothing recorded yet.", comment: "Task page: empty timeline").font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(timeline) { n in
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: n.title).font(.system(size: 12.5)).lineLimit(1)
                                Spacer()
                                Text(verbatim: FleetNoticeTime.string(n.at)).font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                            }
                            .padding(.horizontal, 12).frame(height: 32)
                        }
                    }
                    section(String(localized: "Diagnostics", comment: "Task page section")) {
                        ForEach(facts, id: \.0) { key, value in
                            HStack {
                                Text(verbatim: key).foregroundStyle(Ink.tertiary)
                                Spacer()
                                Text(verbatim: value).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            }
                            .font(.system(size: 11.5)).padding(.horizontal, 12).frame(height: 24)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
            }
        }
    }

    private var facts: [(String, String)] {
        [(String(localized: "Task", comment: "Task diagnostics key"), task.id),
         (String(localized: "State", comment: "Task diagnostics key"), task.state.rawValue),
         (String(localized: "Exit", comment: "Task diagnostics key"), task.rc),
         (String(localized: "Agent", comment: "Task diagnostics key"), task.vendor),
         (String(localized: "Machine", comment: "Task diagnostics key"), task.machine),
         (String(localized: "Role", comment: "Task diagnostics key"), task.role)].filter { !$0.1.isEmpty }
    }

    /// Ranked for the state: a stranded task's way forward first, a finished
    /// one's result first. Retrying is always a new task, never automatic.
    @ViewBuilder private func actionsBlock(_ fleet: FleetData) -> some View {
        VStack(spacing: 8) {
            if task.isStranded, task.canRetry {
                Button(String(localized: "Run It Somewhere Else…", comment: "Task page: start a second task elsewhere")) {
                    actions.fleetRetry(task: task.id)
                }
                .buttonStyle(WideButton(prominent: true)).disabled(!fleet.tasksCurrent)
            }
            if task.isFinished {
                Button(String(localized: "Show Result", comment: "Task page: the task's output")) { actions.fleetShowTask(task.id) }
                    .buttonStyle(WideButton(prominent: true))
                if task.canFetch {
                    Button(String(localized: "Copy Result To…", comment: "Task page: distribute its outputs")) { popUp(copyTargets(fleet)) }
                        .buttonStyle(WideButton())
                }
            }
            if !task.isFinished && !task.isStranded {
                Button(String(localized: "Check In", comment: "Task page: ask it for its state")) { actions.fleetReconcileTasks() }
                    .buttonStyle(WideButton())
            }
        }
    }

    /// Outputs stay where the task put them; this list is the only way one
    /// moves, and nothing is chosen for you.
    private func copyTargets(_ fleet: FleetData) -> [NSMenuItem] {
        fleet.destinations.map { peer in
            ClosureItem(peer.isSelf ? String(localized: "This Mac", comment: "Copy result target") : peer.machine,
                        symbol: peer.isSelf ? "laptopcomputer" : "desktopcomputer") {
                actions.fleetDistribute(task: task.id, machine: peer.machine)
            }
        } + [.separator(), ClosureItem(String(localized: "Every Mac in the Fleet", comment: "Copy result target"), symbol: "square.stack.3d.up") {
            actions.fleetDistribute(task: task.id, machine: nil)
        }]
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).textCase(.uppercase).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.tertiary)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10).fill(Ink.surface))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct WideButton: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(prominent ? .white : .primary)
            .frame(maxWidth: .infinity).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(prominent ? Ink.chip : Ink.raised))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(prominent ? .clear : Ink.raisedEdge, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

// Every sync conflict, each answered on its own; nothing is applied until chosen.
struct ConflictsPage: View {
    @ObservedObject var model: PanelModel
    let actions: FleetActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavBar(title: String(localized: "Conflicts", comment: "Conflicts page title"), back: { model.pop() }) {
                Text(verbatim: model.parentTitle).font(.system(size: 13)).foregroundStyle(Ink.link).lineLimit(1)
            } trailing: { EmptyView() }
            FittingScroll(maxHeight: PanelView.bodyLimit) {
                VStack(alignment: .leading, spacing: 8) {
                    if let fleet = model.fleet {
                        FleetReadState(fleet: fleet, read: .conflicts)
                        if fleet.conflicts.isEmpty {
                            Text("Nothing to answer.", comment: "Conflicts page: empty").font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                        }
                        ForEach(fleet.conflicts) { c in ConflictRow(conflict: c, actions: actions) }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
            }
        }
    }
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
    @Environment(\.isEnabled) private var isEnabled
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
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}
