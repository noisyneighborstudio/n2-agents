import AppKit
import SwiftUI

// A lab's settings in one profile: whose account it reads, how it launches,
// where its files are, and signing in again. Paths and the command are
// values with Reveal and Copy beside them, never rows that only copy.
struct ConfigurePage: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let data: PanelData
    let profile: Profile
    let vendor: Vendor
    @State private var showOwnership = false
    @State private var terminalMenu = MenuAnchor()

    private var usage: Usage? { model.effectiveUsage(profile.name, vendor.id) }
    private var command: String { Clipboard.command(profile: profile.name, vendor: vendor.id) }
    private var terminal: String { data.terminals.first ?? "Terminal" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavBar(title: String(localized: "Configure", comment: "Configure page title"), back: { model.pop() }) {
                Text(verbatim: vendor.label).font(.system(size: 13)).foregroundStyle(Ink.link).lineLimit(1)
            } trailing: { EmptyView() }
            FittingScroll(maxHeight: PanelView.bodyLimit) {
                VStack(alignment: .leading, spacing: 0) {
                    header(String(localized: "Account", comment: "Configure section"), top: 6)
                    group { account }
                    header(String(localized: "Launch", comment: "Configure section"), top: 16)
                    group {
                        row("apple.terminal", String(localized: "Terminal", comment: "Configure row: which terminal opens")) {
                            Button(action: chooseTerminal) {
                                HStack(spacing: 6) {
                                    Text(verbatim: terminal)
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
                                }
                                .font(.system(size: 12.5))
                                .padding(.leading, 10).padding(.trailing, 6).frame(height: 24)
                                .contentShape(Rectangle())
                            }
                            .menuAnchor(terminalMenu)
                            .buttonStyle(PressableStyle(radius: 6, fill: Ink.tile, scale: 0.97))
                            .accessibilityLabel(String(localized: "Terminal, \(terminal)", comment: "Configure: terminal picker"))
                        }
                        divider
                        row("chevron.left.forwardslash.chevron.right", String(localized: "Command", comment: "Configure row: the launch command")) {
                            Text(verbatim: command).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Ink.secondary).lineLimit(1).textSelection(.enabled)
                            CopyButton(label: String(localized: "Copy command", comment: "Configure: copy the launch command")) {
                                actions.copyCommand(profile: profile.name, vendor: vendor.id)
                            }
                        }
                        if !profile.isActive(for: vendor.id) {
                            divider
                            Button { actions.setActive(profile: profile.name, vendor: vendor.id) } label: {
                                row("checkmark.circle", String(localized: "Use on This Mac", comment: "Configure: make this profile the lab's active one on this Mac")) {
                                    EmptyView()
                                }
                                .foregroundStyle(Ink.link)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle(radius: 0))
                        }
                    }
                    if !files.isEmpty {
                        header(String(localized: "Files", comment: "Configure section"), top: 16)
                        group {
                            ForEach(Array(files.enumerated()), id: \.offset) { i, file in
                                if i > 0 { divider }
                                fileRow(file.name, file.path)
                            }
                        }
                    }
                    group {
                        Button { actions.signIn(profile: profile.name, vendor: vendor.id, confirm: true) } label: {
                            row("key", String(localized: "Sign in again…", comment: "Configure: sign this slot in again")) { EmptyView() }
                                .foregroundStyle(Ink.link)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle(radius: 0))
                    }
                    .padding(.top, 16).padding(.bottom, 16)
                }
            }
        }
    }

    private var files: [(name: String, path: String)] {
        var files: [(String, String)] = []
        if let dir = data.snapshot.slotDir(profile.name, vendor.id) {
            files.append((String(localized: "Config", comment: "Configure: the slot's config folder"), dir))
        }
        if !vendor.desktopName.isEmpty, let dir = data.snapshot.desktopDir(profile.name, vendor.id) {
            files.append((String(localized: "App data", comment: "Configure: the desktop app's data folder"), dir))
        }
        return files
    }

    // The account this slot's usage is read from. Codex's owner binding opens beneath it.
    @ViewBuilder private var account: some View {
        let id = usage?.accountHash.map { "\($0.prefix(4))…\($0.suffix(5))" }
            ?? data.snapshot.account(profile.name, vendor.id)
        let content = HStack(spacing: 10) {
            Image(systemName: "person.crop.circle").font(.system(size: 16)).foregroundStyle(Ink.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage account", comment: "Configure row").font(.system(size: 13))
                if let id {
                    Text(verbatim: id).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Ink.tertiary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Text("Owned by \(profile.name)", comment: "Configure: the profile this account belongs to")
                .font(.system(size: 12)).foregroundStyle(Ink.tertiary).lineLimit(1)
            if vendor.id == "codex" {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.tertiary)
                    .rotationEffect(.degrees(showOwnership ? 90 : 0))
            }
        }
        .padding(.leading, 12).padding(.trailing, 12)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        if vendor.id == "codex" {
            Button { withAnimation(Motion.nav(reduce: Motion.reduced)) { showOwnership.toggle() } } label: { content }
                .buttonStyle(PressableStyle(radius: 0))
            if showOwnership {
                AccountOwnershipView(profile: profile.name)
                    .padding(.leading, 40).padding(.trailing, 12).padding(.bottom, 10)
                    .transition(.opacity)
            }
        } else {
            content
        }
    }

    private func fileRow(_ name: String, _ path: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(Ink.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(.system(size: 13))
                Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.tertiary)
                    .lineLimit(1).truncationMode(.middle).help(path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "arrow.up.forward.square",
                       label: String(localized: "Reveal \(name) in Finder", comment: "Configure: show the folder in Finder")) {
                actions.revealPath(path)
            }
            CopyButton(label: String(localized: "Copy \(name) path", comment: "Configure: copy the folder's path")) {
                actions.copyPath(path)
            }
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: 52)
    }

    private func header(_ title: String, top: CGFloat) -> some View {
        Text(verbatim: title).textCase(.uppercase)
            .font(.system(size: 11, weight: .semibold)).tracking(0.22)
            .foregroundStyle(Ink.tertiary)
            .padding(.horizontal, 16).padding(.top, top).padding(.bottom, 6)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.cardEdge, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
    }

    private var divider: some View { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 40) }

    private func row<Trailing: View>(_ symbol: String, _ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 18)
                .foregroundStyle(Ink.secondary)
            Text(verbatim: title).font(.system(size: 13))
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: 44)
    }

    /// The system's own menu, the current terminal checked; a pick persists.
    private func chooseTerminal() {
        popUp(data.terminals.map { name in
            ClosureItem(name, checked: name == terminal) { actions.setPreferredTerminal(name) }
        }, under: terminalMenu)
    }
}

/// Copy as an icon: it turns into a green checkmark for 1.4 s, and
/// VoiceOver hears "Copied".
struct CopyButton: View {
    let label: String
    let copy: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            copy()
            copied = true
            Clipboard.announceCopied()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: copied ? .bold : .regular))
                .foregroundStyle(copied ? Ink.green : Ink.secondary)
                .replacingSymbol()
                .animation(.easeOut(duration: 0.15), value: copied)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(radius: 7))
        .help(label)
        .accessibilityLabel(label)
    }
}
