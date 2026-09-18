import AppKit
import SwiftUI

// The menu bar panel: profiles with their quota and vendor slots, the best
// profile to start in, and recent sessions. Metrics follow the design spec —
// 360 pt wide, 13 pt section padding, 9 pt card radius — and every value on
// screen comes from PanelModel, never from the view reaching into the system.

private enum Metrics {
    static let width: CGFloat = 360
    static let side: CGFloat = 13
    static let cardRadius: CGFloat = 9
}

private func meterColor(_ percent: Int) -> Color {
    percent < 50 ? Color(nsColor: .systemGreen) : percent <= 80 ? Color(nsColor: .systemOrange) : Color(nsColor: .systemRed)
}

private func profileColor(_ name: String) -> Color { Color(nsColor: ProfileColor.of(name)) }

// MARK: - Root

struct PanelView: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(model: model, actions: actions)
            Divider()
            if let data = model.data {
                Banners(data: data, model: model, actions: actions)
                if data.profiles.count <= 1 {
                    FirstRun(actions: actions)
                } else {
                    // The panel grows with the profile count up to a point,
                    // then scrolls rather than running off the screen.
                    if data.profiles.count > 5 {
                        ScrollView { ProfilesSection(data: data, model: model, actions: actions) }
                            .frame(height: 520)
                    } else {
                        ProfilesSection(data: data, model: model, actions: actions)
                    }
                    if !data.sessions.isEmpty {
                        Divider()
                        SessionsSection(data: data, actions: actions)
                    }
                }
            } else {
                ProgressView().controlSize(.small).padding(24)
            }
            Divider()
            PanelFooter(model: model, actions: actions)
        }
        .frame(width: Metrics.width)
    }
}

// MARK: - Header + footer

private struct PanelHeader: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 18, height: 18)
            Text("N2 Agents").font(.system(size: 13, weight: .semibold))
            Spacer()
            if let data = model.data, data.profiles.count > 1 {
                Button { popUpActiveMenu(data) } label: {
                    HStack(spacing: 5) {
                        Text("Active").foregroundStyle(.secondary)
                        if data.snapshot.active != "mixed" {
                            Circle().fill(profileColor(data.snapshot.active)).frame(width: 6, height: 6)
                        }
                        Text(data.snapshot.active == "mixed" ? "Mixed" : data.snapshot.active)
                    }
                    .font(.system(size: 11.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Switch every lab to one profile")
            }
            Button { popUpSettingsMenu() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, Metrics.side)
        .frame(height: 44)
    }

    private func popUpActiveMenu(_ data: PanelData) {
        popUp(data.profiles.map { p in
            ClosureItem(p.name, checked: p.name == data.snapshot.active) {
                actions.setActive(profile: p.name, vendor: nil)
            }
        })
    }

    private func popUpSettingsMenu() {
        var items: [NSMenuItem] = [ClosureItem("New Profile…") { actions.newProfile() }, .separator()]
        if let terms = model.data?.terminals, terms.count > 1 {
            items.append(submenu("Open Sessions In", terms.enumerated().map { i, name in
                ClosureItem(name, checked: i == 0) { actions.setPreferredTerminal(name) }
            }))
        }
        let channel = UpdateChannel.selected()
        items.append(submenu("Update Channel", UpdateChannel.allCases.map { c in
            ClosureItem(c.rawValue.capitalized, checked: c == channel) { actions.setUpdateChannel(c) }
        }))
        if model.data?.desktopInstalled == true {
            items.append(ClosureItem("Auto-repatch Claude Desktop Clones", checked: actions.autoRepatch) {
                actions.setAutoRepatch(!actions.autoRepatch)
            })
            items.append(ClosureItem("Re-patch All Clones Now") { actions.repatchAll() })
        }
        items.append(ClosureItem("Locate Claude Desktop…") { actions.locateClaude() })
        items.append(.separator())
        items.append(ClosureItem("Check for Updates…") { actions.checkForUpdates() })
        popUp(items)
    }
}

private struct PanelFooter: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    private var versionLine: LocalizedStringKey {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        let channel = UpdateChannel.selected().rawValue.capitalized
        switch model.updateStatus {
        case .upToDate: return "\(version) · \(channel) · up to date"
        case .available: return "\(version) · \(channel) · update available"
        case nil: return "\(version) · \(channel)"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(versionLine) { actions.checkForUpdates() }
                .buttonStyle(.plain)
                .foregroundStyle(model.updateStatus == .available ? Color.accentColor : .secondary)
                .help("Check for updates")
            Spacer()
            Button("Report a Bug") { actions.reportBug() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            Button("Quit") { actions.quit() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
        }
        .font(.system(size: 11))
        .padding(.horizontal, Metrics.side)
        .frame(height: 31)
    }
}

// MARK: - Banners

private struct Banners: View {
    let data: PanelData
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    var body: some View {
        if !data.desktopInstalled, data.snapshot.vendor("claude")?.installed == true {
            Banner(icon: "exclamationmark.triangle", text: "Claude Desktop not found — CLI profiles still work") {
                Button("Locate…") { actions.locateClaude() }
                Button("Download…") { actions.downloadClaude() }
            }
        }
        let clones = Set(data.staleClones.keys).union(model.repatching)
        if let version = data.desktopVersion, !clones.isEmpty {
            Banner(icon: "arrow.up.to.line",
                   text: model.repatching.isEmpty
                       ? "Claude \(version) — \(clones.count) clone(s) behind"
                       : "Claude \(version) — rebuilding \(model.repatching.count) of \(clones.count) clones") {
                Button("Details") { actions.showCloneDetails() }
            }
        }
    }
}

private struct Banner<Buttons: View>: View {
    let icon: String
    let text: LocalizedStringKey
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Color(nsColor: .systemOrange))
                Text(text).font(.system(size: 11.5))
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) { buttons }
                .buttonStyle(PillButtonStyle(tint: Color(nsColor: .systemOrange)))
                .padding(.leading, 22)
        }
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .systemOrange).opacity(0.16))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Profiles

private struct SectionLabel: View {
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

private struct ProfilesSection: View {
    let data: PanelData
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Profiles", detail: "\(data.profiles.count)")
            ForEach(data.profiles, id: \.name) { p in
                ProfileCard(profile: p, data: data, model: model, actions: actions)
            }
            if let best = model.best, let v = data.quotaVendor {
                Button { actions.openSession(profile: best.name, vendor: v.id, terminal: nil) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt").foregroundStyle(Color.accentColor)
                        Text("Open \(v.label) in best profile").font(.system(size: 12.5))
                        Spacer()
                        Text("\(best.name) · \(best.fiveHour)%").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle(radius: 8, border: true))
            } else if model.rankingBlocked {
                Text("Ranking is unavailable while any profile is unreadable — “best” is hidden rather than guessed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, 12)
    }
}

private struct ProfileCard: View {
    let profile: Profile
    let data: PanelData
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    private var isActive: Bool { data.snapshot.active == profile.name }
    private var repatching: Bool { model.repatching.contains(profile.name) }
    private var stale: Bool { data.staleClones[profile.name] != nil }
    private var selected: Vendor? {
        guard let s = model.selection, s.profile == profile.name, profile.slots[s.vendor] != nil else { return nil }
        return data.snapshot.vendor(s.vendor)
    }
    private var addable: Bool { data.snapshot.installedVendors.contains { profile.slots[$0.id] == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            nameRow
            detailRow
            FlowLayout(spacing: 4) {
                ForEach(data.snapshot.installedVendors.filter { profile.slots[$0.id] != nil }, id: \.id) { v in
                    VendorChip(vendor: v, active: profile.isActive(for: v.id), selected: selected?.id == v.id,
                               remaining: v.id == data.quotaVendor?.id ? model.usage[profile.name]?.remaining : nil) {
                        model.selection = selected?.id == v.id ? nil : Selection(profile: profile.name, vendor: v.id)
                    }
                }
                if addable {
                    Button { actions.addVendor(profile: profile.name) } label: {
                        Image(systemName: "plus").font(.system(size: 9, weight: .semibold)).frame(width: 17, height: 17)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Add a lab to \(profile.name)")
                }
            }
            if let v = selected {
                VendorDrawer(profile: profile, vendor: v, data: data, model: model, actions: actions)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius)
            .fill(isActive ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius)
            .strokeBorder(isActive ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08)))
        .contextMenu {
            if !isActive { Button("Make Active for All Labs") { actions.setActive(profile: profile.name, vendor: nil) } }
            if addable { Button("Add Lab…") { actions.addVendor(profile: profile.name) } }
            if profile.hasApp { Button("Reveal Claude Desktop Data") { actions.revealData(profile: profile.name) } }
            if !profile.isDefault {
                Divider()
                Button("Delete Profile…") { actions.deleteProfile(profile.name) }
            }
        }
    }

    private var nameRow: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(profileColor(profile.name)).frame(width: 3, height: 18)
            Text(profile.name).font(.system(size: 13, weight: .medium))
            Spacer()
            Group {
                if repatching {
                    Text("Rebuilding…").foregroundStyle(.secondary)
                } else if stale {
                    Text("Update pending").foregroundStyle(Color(nsColor: .systemOrange))
                } else if profile.hasApp {
                    HStack(spacing: 5) {
                        if profile.running { Circle().fill(Color(nsColor: .systemGreen)).frame(width: 6, height: 6) }
                        Text(profile.running ? "Desktop running" : "Desktop idle")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
        }
        .frame(height: 18)
    }

    // Clone state outranks quota: while a clone is behind, that is the thing
    // to act on.
    @ViewBuilder private var detailRow: some View {
        if repatching {
            ProgressView().progressViewStyle(.linear).controlSize(.small).tint(Color(nsColor: .systemOrange))
        } else if stale {
            InlineStatus(text: profile.running ? "Waiting — clone is in use"
                                               : actions.autoRepatch ? "Queued for rebuild" : "Auto-repatch is off",
                         button: "Rebuild Now") { actions.rebuildClone(profile.name) }
        } else if let v = data.quotaVendor, profile.slots[v.id] != nil {
            QuotaRow(vendor: v, usage: model.usage[profile.name], loading: model.usageLoading) {
                actions.openSession(profile: profile.name, vendor: v.id, terminal: nil)
            } retry: {
                actions.retryUsage()
            }
        }
    }
}

private struct QuotaRow: View {
    let vendor: Vendor
    let usage: Usage?
    let loading: Bool
    let logIn: () -> Void
    let retry: () -> Void

    var body: some View {
        switch usage?.note {
        case .ok?:
            HStack(spacing: 10) {
                Meter(label: "5h", percent: usage?.fiveHour)
                Meter(label: "7d", percent: usage?.sevenDay)
            }
        case .noToken?:
            InlineStatus(text: "\(vendor.label) quota unavailable — not signed in", button: "Log In", action: logIn)
        case .staleToken?:
            InlineStatus(text: "\(vendor.label) quota unavailable — token expired", button: "Log In", action: logIn)
        case .fetchError?:
            InlineStatus(text: "Quota check failed", button: "Retry", action: retry)
        case .noUsageAPI?:
            EmptyView()
        case nil:
            if loading { Text("Checking quota…").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}

private struct Meter: View {
    let label: String
    let percent: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    if let p = percent {
                        Capsule().fill(meterColor(p)).frame(width: g.size.width * CGFloat(min(max(p, 0), 100)) / 100)
                    }
                }
            }
            .frame(height: 4)
            Text(percent.map { "\($0)%" } ?? "–").monospacedDigit().frame(width: 30, alignment: .trailing)
        }
        .font(.system(size: 10.5))
        .frame(height: 11)
    }
}

private struct InlineStatus: View {
    let text: LocalizedStringKey
    let button: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button(button, action: action).buttonStyle(PillButtonStyle())
        }
    }
}

private struct VendorChip: View {
    let vendor: Vendor
    let active: Bool
    let selected: Bool
    /// Quota left, 0–100. Nil for labs with no usage API — no line is drawn
    /// rather than a guessed one.
    let remaining: Int?
    let action: () -> Void

    // Filled = active for this lab, outlined = holds a slot, dashed = a swap
    // vendor, where switching is a global side effect.
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                chip
                if let r = remaining { RemainingLine(percent: r) }
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        let state = active ? "\(vendor.label) — active in this profile" : "\(vendor.label) — slot ready"
        return remaining.map { "\(state) · \($0)% quota left" } ?? state
    }

    private var chip: some View {
            HStack(spacing: 3) {
                if vendor.isolation == "swap" { Image(systemName: "arrow.left.arrow.right").font(.system(size: 8)) }
                Text(vendor.label)
            }
            .font(.system(size: 10.5))
            .padding(.horizontal, 6)
            .frame(height: 17)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(selected ? Color.accentColor : active ? Color.primary.opacity(0.14) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(selected ? Color.clear : Color.primary.opacity(active ? 0 : 0.25),
                              style: StrokeStyle(lineWidth: 1, dash: vendor.isolation == "swap" ? [2.5, 2] : [])))
    }
}

// Quota left under a chip: green while there is room, then amber, orange and
// red as it runs out.
private struct RemainingLine: View {
    let percent: Int

    private var color: Color {
        switch percent {
        case 51...: return Color(nsColor: .systemGreen)
        case 26...50: return Color(nsColor: .systemYellow)
        case 11...25: return Color(nsColor: .systemOrange)
        default: return Color(nsColor: .systemRed)
        }
    }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color).frame(width: g.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
            }
        }
        .frame(height: 2)
    }
}

// What used to be a profile submenu: every action for one (profile, lab).
private struct VendorDrawer: View {
    let profile: Profile
    let vendor: Vendor
    let data: PanelData
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    @State private var copied = false

    private var usage: Usage? { data.quotaVendor?.id == vendor.id ? model.usage[profile.name] : nil }
    private var command: String { "\(vendor.id)-\(profile.name.lowercased())" }

    private var summary: String {
        var parts = [vendor.label, vendor.isolation == "swap" ? "one profile at a time" : "pinned per process"]
        if usage?.note == .ok, let five = usage?.fiveHour { parts.append("\(five)% of 5h used") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 3)
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                OpenButton(terminals: data.terminals) { terminal in
                    actions.openSession(profile: profile.name, vendor: vendor.id, terminal: terminal)
                }
                if usage?.note == .noToken || usage?.note == .staleToken {
                    Button("Log In…") { actions.openSession(profile: profile.name, vendor: vendor.id, terminal: nil) }
                        .buttonStyle(PillButtonStyle(height: 22))
                }
                // Make this profile the lab's default. A swap lab has one
                // global login, so it "switches"; an env lab only changes what
                // new sessions use.
                if !profile.isActive(for: vendor.id) {
                    Button(vendor.isolation == "swap" ? "Switch to" : "Use") {
                        actions.setActive(profile: profile.name, vendor: vendor.id)
                    }
                    .buttonStyle(PillButtonStyle(height: 22))
                    .help(vendor.isolation == "swap"
                          ? "Switch \(vendor.label)'s one login to \(profile.name)"
                          : "Use \(profile.name) for new \(vendor.label) sessions")
                }
            }
            .padding(.vertical, 2)
            DrawerRow(title: "Copy command") {
                actions.copyCommand(profile: profile.name, vendor: vendor.id)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } trailing: {
                HStack(spacing: 5) {
                    Text(copied ? "Copied" : command).font(.system(size: 11, design: .monospaced))
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
            }
            if vendor.clonesDesktopApp && data.desktopInstalled && profile.hasApp {
                DrawerRow(title: "Claude Desktop") {
                    actions.openDesktop(profile: profile.name)
                } trailing: {
                    HStack(spacing: 5) {
                        Text(profile.isDefault ? "installed" : data.staleClones[profile.name] == nil ? "clone current" : "clone behind")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                }
            }
            if vendor.id == "claude" {
                DrawerRow(title: "Transfer session…") { actions.transferSession(profile: profile.name) }
            }
        }
    }
}

// "Open in <terminal>" with a chevron for picking another terminal this once.
private struct OpenButton: View {
    let terminals: [String]
    let open: (String?) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { open(nil) } label: {
                Text("Open in \(terminals.first ?? "Terminal")")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 9)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if terminals.count > 1 {
                Divider().frame(height: 14)
                Button {
                    popUp(terminals.map { name in ClosureItem(name) { open(name) } })
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in another terminal")
            }
        }
        .font(.system(size: 11.5))
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
    }
}

private struct DrawerRow<Trailing: View>: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @ViewBuilder let trailing: Trailing

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 11.5))
                Spacer()
                trailing.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 5)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(radius: 5))
    }
}

extension DrawerRow where Trailing == EmptyView {
    init(title: LocalizedStringKey, action: @escaping () -> Void) {
        self.init(title: title, action: action) { EmptyView() }
    }
}

// MARK: - Sessions

private struct SessionsSection: View {
    let data: PanelData
    let actions: PanelActions

    private static let age: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 1
        f.allowedUnits = [.minute, .hour, .day, .weekOfMonth]
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Recent sessions", detail: data.sessionVendor?.label ?? "")
            ForEach(data.sessions.prefix(2), id: \.id) { s in
                Button { actions.resumeSession(s) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(profileColor(s.profile)).frame(width: 6, height: 6).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.cwd.map { ($0 as NSString).lastPathComponent } ?? s.projectSlug)
                                .font(.system(size: 12.5))
                            Text(s.snippet).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(Self.age.string(from: s.mtime, to: Date()) ?? "")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle(radius: 7, resting: 0.05))
                .help("Resume in \(s.profile)")
            }
        }
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, 12)
    }
}

// MARK: - First run

private struct FirstRun: View {
    let actions: PanelActions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "asterisk").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
            Text("No profiles yet").font(.system(size: 13, weight: .semibold))
            Text("A profile is one identity holding a slot per lab — Claude, Codex, Grok and the rest move together when you switch.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("New Profile…") { actions.newProfile() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            Text("Your current logins stay put as “Default”.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }
}

// MARK: - Controls

// In-card action: Log In, Retry, Rebuild Now, banner buttons.
private struct PillButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var height: CGFloat = 19

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(configuration.isPressed ? 0.22 : 0.1)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(0.35)))
    }
}

// Full-width row that highlights under the pointer, like a menu item.
private struct RowButtonStyle: ButtonStyle {
    let radius: CGFloat
    var border = false
    var resting: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        HoverBackground(radius: radius, border: border, resting: resting, pressed: configuration.isPressed) {
            configuration.label
        }
    }
}

private struct HoverBackground<Content: View>: View {
    let radius: CGFloat
    let border: Bool
    let resting: Double
    let pressed: Bool
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: radius)
                .fill(Color.primary.opacity(pressed ? 0.16 : hovering ? 0.09 : resting)))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color.primary.opacity(border ? 0.12 : 0)))
            .onHover { hovering = $0 }
    }
}

// Chips wrap onto a second line when a profile holds many labs.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, point) in arrange(width: bounds.width, subviews: subviews).origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, maxX, y + rowHeight)
    }
}

// MARK: - AppKit menus

// SwiftUI's Menu flattens custom labels on macOS, so the panel's menus are
// plain NSMenus popped at the pointer.
final class ClosureItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let menu = NSMenu()
    items.forEach(menu.addItem)
    item.submenu = menu
    return item
}

private func popUp(_ items: [NSMenuItem]) {
    let menu = NSMenu()
    items.forEach(menu.addItem)
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
}
