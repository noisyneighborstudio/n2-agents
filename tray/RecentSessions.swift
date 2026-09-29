import AppKit
import SwiftUI

extension PanelModel {
    /// Sessions to show, newest first: the full list once the window's read
    /// has landed, the panel's own two before that.
    func sessions(profile: String? = nil, vendor: String? = nil) -> [SessionInfo] {
        SessionInfo.filter(allSessions + (data?.sessions ?? []), profile: profile, vendor: vendor)
    }

    func session(_ id: String) -> SessionInfo? {
        (allSessions + (data?.sessions ?? [])).first { $0.id == id }
    }
}

// The newest sessions here, scoped to where it's shown: this Mac on root, a
// profile on its page, a profile's lab on the Provider page. The expand
// button opens every session in its own window.
struct RecentSection: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    var profile: String? = nil
    var vendor: String? = nil
    var limit = 2

    var body: some View {
        let recent = Array(model.sessions(profile: profile, vendor: vendor).prefix(limit))
        if !recent.isEmpty {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .semibold))
                    Text("Recent", comment: "Section: the newest sessions").font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Button { actions.showAllSessions() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(radius: 6))
                    .help(String(localized: "All sessions", comment: "Recent: open the sessions window"))
                    .accessibilityLabel(String(localized: "All sessions", comment: "Recent: open the sessions window"))
                }
                .foregroundStyle(Ink.secondary)
                .padding(.leading, 4)
                ForEach(recent) { s in
                    RecentCard(session: s, model: model, actions: actions)
                }
            }
        }
    }
}

private struct RecentCard: View {
    let session: SessionInfo
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    private var vendor: Vendor? { model.data?.snapshot.vendor(session.vendor) }
    private var place: String? {
        session.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }

    var body: some View {
        Button { actions.resumeSession(session) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: session.title ?? session.snippet)
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(session.mtime, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.tertiary).lineLimit(1)
                    Color.clear.frame(width: 18, height: 1)   // under the menu button
                }
                HStack(spacing: 5) {
                    if let vendor { LabMark(vendor: vendor, size: 10).foregroundStyle(Ink.secondary) }
                    Circle().fill(profileColor(session.profile)).frame(width: 6, height: 6)
                    Text(verbatim: session.profile)
                    if let place {
                        Text(verbatim: "·")
                        Text(verbatim: place).lineLimit(1).truncationMode(.middle)
                    }
                    if let branch = session.branch {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                        Text(verbatim: branch).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressableStyle(radius: 10, fill: Ink.surface, card: true))
        .help(String(localized: "Resume in \(session.profile)", comment: "Recent card: resume the session"))
        .overlay(alignment: .topTrailing) {
            // Beside the card's button, not inside it: a control nested in a
            // button's label doesn't get its own clicks.
            Button { popUp(menu) } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.secondary)
                    .frame(width: 22, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(radius: 5))
            .help(String(localized: "Resume, send, move or copy", comment: "Recent card menu"))
            .padding(.top, 5).padding(.trailing, 5)
        }
    }

    private var menu: [NSMenuItem] {
        let destinations = (model.data?.profiles ?? [])
            .filter { $0.name != session.profile && $0.slots[session.vendor] != nil }.map(\.name)
        var items: [NSMenuItem] = [ClosureItem(String(localized: "Resume", comment: "Session menu"), symbol: "play") {
            actions.resumeSession(session)
        }]
        if session.vendor == "codex" {
            items.append(ClosureItem(String(localized: "Send to Machine…", comment: "Session menu"), symbol: "laptopcomputer") {
                if model.sendDrafts[session.id] == nil { model.sendDrafts[session.id] = SendDraft(cwd: session.cwd ?? "") }
                model.push(.sendSession(session.id))
            })
        }
        let moves: [NSMenuItem] = destinations.isEmpty
            ? [NSMenuItem(title: String(localized: "No other profile has this lab", comment: "Session menu"), action: nil, keyEquivalent: "")]
            : destinations.map { p in ClosureItem(p, symbol: "person.crop.circle") { actions.moveSession(session, to: p) } }
        items.append(submenu(String(localized: "Move to", comment: "Session menu"), symbol: "arrowshape.turn.up.right", moves))
        items.append(ClosureItem(String(localized: "Copy Resume Command", comment: "Session menu"), symbol: "doc.on.doc") {
            actions.copyResumeCommand(session)
        })
        return items
    }
}

// Send one saved session to another Mac: which Mac, and where there. The
// choice waits on the model, so closing the panel loses nothing; the outcome
// is said here, not in an alert.
struct SendSessionPage: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let session: SessionInfo

    private var draft: SendDraft { model.sendDrafts[session.id] ?? SendDraft(cwd: session.cwd ?? "") }
    private var peers: [FleetPeer] { (model.fleet?.peers ?? []).filter { $0.state == .approved && !$0.isSelf } }

    private func update(_ change: (inout SendDraft) -> Void) {
        var d = draft
        change(&d)
        if case .sent = d.state {} else if case .sending = d.state {} else { d.state = .editing }
        model.sendDrafts[session.id] = d
    }

    var body: some View {
        let d = draft
        let chosen = d.peer ?? peers.first(where: \.isOnline)?.id
        VStack(alignment: .leading, spacing: 0) {
            NavBar(title: String(localized: "Send Session", comment: "Send Session page title"), back: { model.pop() }) {
                Text(verbatim: model.parentTitle).font(.system(size: 13)).foregroundStyle(Ink.link).lineLimit(1)
            } trailing: { EmptyView() }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: session.title ?? session.snippet).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text("Copies the saved history and keeps its original account. It does not move a running agent or copy workspace files.",
                         comment: "Send Session: what sending does")
                        .font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Machine", comment: "Send Session: destination machine").textCase(.uppercase)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.tertiary)
                    if peers.isEmpty {
                        Text("No other approved Mac. Add one from the + menu.", comment: "Send Session: no destination")
                            .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    }
                    VStack(spacing: 0) {
                        ForEach(peers) { peer in
                            Button { update { $0.peer = peer.id } } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: chosen == peer.id ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(chosen == peer.id ? Ink.link : Ink.tertiary)
                                    Image(systemName: "desktopcomputer").foregroundStyle(Ink.secondary)
                                    Text(verbatim: peer.machine).font(.system(size: 13))
                                    Spacer()
                                    Circle().fill(peer.isOnline ? Ink.green : Ink.tertiary).frame(width: 6, height: 6)
                                    Text(peer.isOnline ? String(localized: "online", comment: "Machine status")
                                                       : String(localized: "offline", comment: "Machine status"))
                                        .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                                }
                                .padding(.horizontal, 12).frame(height: 40).contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle(radius: 0))
                            .accessibilityAddTraits(chosen == peer.id ? .isSelected : [])
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Ink.surface))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Directory there", comment: "Send Session: destination directory").textCase(.uppercase)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.tertiary)
                    TextField(String(localized: "/Users/you/project", comment: "Send Session: directory placeholder"),
                              text: Binding(get: { draft.cwd }, set: { v in update { $0.cwd = v } }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                }
                outcome(d.state)
                Button {
                    guard let peer = chosen else { return }
                    actions.sendSession(session, to: peer, cwd: d.cwd.trimmingCharacters(in: .whitespaces))
                } label: {
                    HStack(spacing: 8) {
                        if d.state == .sending { ProgressView().controlSize(.small).tint(.white) }
                        Text("Send", comment: "Send Session: send it").font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Ink.chip))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(PressableStyle(radius: 9, scale: 0.97))
                .disabled(chosen == nil || d.cwd.isEmpty || d.state == .sending)
                .opacity(chosen == nil || d.cwd.isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 16)
        }
    }

    @ViewBuilder private func outcome(_ state: SendDraft.State) -> some View {
        switch state {
        case .sent(let message):
            Label { Text(verbatim: message) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.green) }
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.yellow) }
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        case .editing, .sending:
            EmptyView()
        }
    }
}
