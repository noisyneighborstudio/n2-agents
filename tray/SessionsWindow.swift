import AppKit
import SwiftUI

// A small tag. Takes a mark when the thing has one — a lab's logo, a
// profile's colour as a dot — never bare text, so a row can be scanned rather
// than read. The words stay in label colour: a profile's colour as text on
// the glass is too faint to read.
private struct Chip: View {
    var text: String? = nil
    var vendor: Vendor? = nil
    var dot: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let vendor {
                LabMark(vendor: vendor, size: 9)
            } else if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            if let text { Text(text).font(.system(size: 10.5)) }
        }
        .padding(.horizontal, text == nil ? 3.5 : 6)
        .frame(height: 16)
        .foregroundStyle(Ink.secondary)
        .background(Capsule().fill(Ink.Tone.neutral.wash(dark: 0.08, light: 0.06)))
        .overlay(Capsule().strokeBorder(Ink.cardEdge, lineWidth: 0.5))
        .fixedSize()
    }
}

// A week later a session is recognised by what it was about, then where:
// the lab's name for it (or the prompt, when it has none) leads; the folder
// and branch say which checkout — the only way to tell apart the worktrees a
// loop fans out into; the prompt follows when the name didn't already say it.
private struct SessionRow: View {
    let session: SessionInfo
    let data: PanelData
    let actions: PanelActions
    var promptLines = 1
    @State private var menuAnchor = MenuAnchor()

    private var place: String {
        guard let cwd = session.cwd else { return "—" }
        let home = NSHomeDirectory()
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    /// Profiles that hold a slot for this session's lab.
    private var destinations: [String] {
        data.profiles.filter { $0.name != session.profile && $0.slots[session.vendor] != nil }.map(\.name)
    }

    private var lab: String { data.snapshot.vendor(session.vendor)?.label ?? session.vendor }

    var body: some View {
        Button { actions.resumeSession(session) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(session.title ?? session.snippet)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    Chip(text: session.profile, dot: profileColor(session.profile))
                    // The logo is the lab's name; spelling it out again was
                    // costing the title its width.
                    if let v = data.snapshot.vendor(session.vendor) {
                        Chip(vendor: v)
                    }
                    sessionAge(session.mtime)
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(Ink.secondary)
                        .frame(minWidth: 22, alignment: .trailing)
                    Color.clear.frame(width: 18, height: 1)   // under the menu button
                }
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 9))
                    Text(place).lineLimit(1).truncationMode(.middle)
                    if let branch = session.branch {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9)).padding(.leading, 4)
                        Text(branch).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Ink.secondary)
                if session.title != nil {
                    Text(session.snippet)
                        .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                        .lineLimit(promptLines).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(radius: 7, fill: Ink.hover))
        .help("Resume in \(session.profile)")
        // Beside the row's button, not inside it: a control nested in a
        // button's label doesn't get its own clicks.
        .overlay(alignment: .topTrailing) {
            Button { popUp(menuItems, under: menuAnchor) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(radius: 4))
            .menuAnchor(menuAnchor)
            .help("Send to another machine, move to another profile, or copy the resume command")
            .padding(.top, 6)
            .padding(.trailing, 5)
        }
        .contextMenu {
            Button { actions.resumeSession(session) } label: { Label("Resume", systemImage: "play") }
            if session.vendor == "codex" {
                Button { actions.sendSession(session) } label: { Label("Send to Machine…", systemImage: "laptopcomputer") }
            }
            Menu("Move to") {
                ForEach(destinations, id: \.self) { p in
                    Button(p) { actions.moveSession(session, to: p) }
                }
            }
            .disabled(destinations.isEmpty)
            Button { actions.copyResumeCommand(session) } label: {
                Label("Copy Resume Command", systemImage: "doc.on.doc")
            }
        }
    }

    private var menuItems: [NSMenuItem] {
        let moves: [NSMenuItem] = destinations.isEmpty
            ? [NSMenuItem(title: "No other profile has \(lab)", action: nil, keyEquivalent: "")]
            : destinations.map { p in
                ClosureItem(p, symbol: "person.crop.circle") { actions.moveSession(session, to: p) }
            }
        let send: [NSMenuItem] = session.vendor == "codex"
            ? [ClosureItem("Send to Machine…", symbol: "laptopcomputer") { actions.sendSession(session) }] : []
        return [ClosureItem("Resume", symbol: "play") { actions.resumeSession(session) }] + send + [
                submenu("Move to", symbol: "arrowshape.turn.up.right", moves),
                ClosureItem("Copy Resume Command", symbol: "doc.on.doc") { actions.copyResumeCommand(session) }]
    }
}

// Every session, searchable, in a window of its own. Its size is fixed: a
// window that followed its rows would resize on every keystroke, and on
// every open as the list arrived.
struct SessionsWindowView: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    @State private var query = ""
    /// Scope to one profile and one lab; nil is every one.
    @State private var profile: String?
    @State private var vendor: String?
    @FocusState private var searching: Bool

    static let identifier = NSUserInterfaceItemIdentifier("sessions")
    private static let width: CGFloat = 560
    private static var listHeight: CGFloat {
        ((NSScreen.main?.visibleFrame.height ?? 800) - 44 - 48) * 0.72
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// Once per render: every part of the window reads the same filtered list.
    private func filtered() -> [SessionInfo] {
        // Already newest first and unique; a keystroke only filters.
        let tokens = SessionInfo.fold(trimmed).split(separator: " ")
        return model.recentSessions.filter { s in
            (profile == nil || s.profile == profile) && (vendor == nil || s.vendor == vendor)
                && (tokens.isEmpty || s.matches(tokens))
        }
    }

    var body: some View {
        let rows = filtered()
        return VStack(spacing: 0) {
            header(rows)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                TextField("Search title, folder, branch, prompt", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searching)
                    .onSubmit { if let first = rows.first { actions.resumeSession(first) } }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
                filterMenu(String(localized: "Profile", comment: "Sessions window: profile filter"), selection: $profile,
                           options: (model.data?.profiles ?? []).map { ($0.name, $0.name) })
                filterMenu(String(localized: "Lab", comment: "Sessions window: lab filter"), selection: $vendor,
                           options: (model.data?.snapshot.installedVendors ?? []).filter(\.hasSessions).map { ($0.id, $0.label) })
            }
            .padding(.horizontal, Metrics.side)
            .frame(height: 34)
            Divider()
            list(rows).frame(height: Self.listHeight)
        }
        .frame(width: Self.width)
        // Typing should search without a click first, on every open. A turn
        // late: present() clears the first responder after ordering front.
        .onAppear(perform: focusSearch)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow)?.identifier == Self.identifier { focusSearch() }
        }
    }

    /// "All" or one value, as a native pop-up menu.
    private func filterMenu(_ title: String, selection: Binding<String?>, options: [(id: String, label: String)]) -> some View {
        Menu {
            Button(String(localized: "All", comment: "Sessions window: no filter")) { selection.wrappedValue = nil }
            Divider()
            ForEach(options, id: \.id) { option in
                Button(option.label) { selection.wrappedValue = option.id }
            }
        } label: {
            Text(verbatim: options.first { $0.id == selection.wrappedValue }?.label ?? title).font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func focusSearch() {
        DispatchQueue.main.async { searching = true }
    }

    private func header(_ rows: [SessionInfo]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.secondary)
            Text("Recent sessions").font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.sessionsLoading { ProgressView().controlSize(.small) }
            if !model.allSessions.isEmpty {
                Text(trimmed.isEmpty && profile == nil && vendor == nil ? "\(rows.count)" : "\(rows.count) of \(model.allSessions.count)")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Ink.secondary)
            }
            Button { actions.closeSessions() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, Metrics.side)
        .frame(height: 44)
    }

    @ViewBuilder private func list(_ rows: [SessionInfo]) -> some View {
        if let data = model.data, !rows.isEmpty {
            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(rows) { s in
                        SessionRow(session: s, data: data, actions: actions, promptLines: 2)
                    }
                }
                .padding(Metrics.side)
            }
        } else {
            VStack(spacing: 8) {
                if model.sessionsLoading { ProgressView().controlSize(.small) }
                Text(model.sessionsLoading ? "Reading sessions…"
                     : trimmed.isEmpty ? "No sessions yet" : "No sessions match “\(trimmed)”")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
