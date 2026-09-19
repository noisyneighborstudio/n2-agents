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

private func profileColor(_ name: String) -> Color { Color(nsColor: ProfileColor.of(name)) }

// Used: under 50 plenty, 50–79 working on it, 80+ nearly gone. Colour only
// reinforces — the length of the fill is the reading.
private func meterColor(_ percent: Int) -> Color {
    percent < 50 ? Color(nsColor: .systemGreen) : percent < 80 ? Color(nsColor: .systemOrange) : Color(nsColor: .systemRed)
}

private let maxedRed = Color(nsColor: .systemRed)

private let clockTime: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f
}()

// MARK: - Root

// Loading follows one rule: draw at once from what is already known, and let
// only capacity — the one slow, networked reading — arrive later. A blank
// panel is a bug, not a loading state.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The screen's height less the menu bar gap, header, footer and a margin.
    static var bodyLimit: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 44 - 31 - 48
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(model: model, actions: actions)
            Divider()
            if let data = model.data {
                // Header and footer stay put; everything between grows with
                // its content and scrolls once the panel would outgrow the
                // screen — more profiles, an open drawer, a banner.
                FittingScroll(maxHeight: Self.bodyLimit, focus: model.selection?.profile) {
                    VStack(spacing: 0) {
                        Banners(data: data, model: model, actions: actions)
                        if data.profiles.count <= 1 {
                            FirstRun(actions: actions)
                        } else {
                            ProfilesSection(data: data, model: model, actions: actions)
                            if !data.sessions.isEmpty {
                                Divider()
                                SessionsSection(data: data, actions: actions)
                            }
                        }
                    }
                }
            } else {
                ColdStart()
            }
            Divider()
            PanelFooter(model: model, actions: actions)
        }
        .frame(width: Metrics.width)
        // Every open: the content rises 4 pt and fades in — one move for the
        // whole panel, not a cascade of elements.
        .opacity(model.presented ? 1 : 0)
        .offset(y: model.presented || reduceMotion ? 0 : 4)
        .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.16), value: model.presented)
    }
}

// A ScrollView that is only as tall as its content, up to a limit. A bare
// ScrollView takes all the height it's offered, which would pin the panel at
// its maximum; this one measures its content and asks for exactly that. When
// `focus` changes (a drawer opened), that card scrolls into view.
private struct FittingScroll<Content: View>: View {
    let maxHeight: CGFloat
    let focus: String?
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content.background(GeometryReader { g in
                    Color.clear.preference(key: ContentHeight.self, value: g.size.height)
                })
            }
            .frame(height: min(contentHeight, maxHeight))
            .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
            .onChange(of: focus) { profile in
                guard let profile else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo(profile) }
            }
        }
    }
}

private struct ContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
            if model.data == nil {
                Pulse(width: 58, height: 8)
            } else if let data = model.data, data.profiles.count > 1 {
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
        if let clone = model.data?.cloneVendor {
            if model.data?.desktopInstalled == true {
                items.append(ClosureItem("Auto-repatch \(clone.desktopName) Clones", checked: actions.autoRepatch) {
                    actions.setAutoRepatch(!actions.autoRepatch)
                })
                items.append(ClosureItem("Re-patch All Clones Now") { actions.repatchAll() })
            }
            items.append(ClosureItem("Locate \(clone.desktopName)…") { actions.locateClaude() })
        }
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
        case .failed: return "\(version) · \(channel) · update check failed"
        case nil: return "\(version) · \(channel)"
        }
    }

    private var updateHelp: String {
        if case .failed(let reason)? = model.updateStatus { return "Update check failed: \(reason) Click to retry." }
        return "Check for updates"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(versionLine) { actions.checkForUpdates() }
                .buttonStyle(.plain)
                .help(updateHelp)
                .foregroundStyle(model.updateStatus == .available ? Color.accentColor : .secondary)
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
        if !data.desktopInstalled, let clone = data.cloneVendor {
            Banner(icon: "exclamationmark.triangle", text: "\(clone.desktopName) not found — CLI profiles still work") {
                Button("Locate…") { actions.locateClaude() }
                Button("Download…") { actions.downloadClaude() }
            }
        }
        let clones = Set(data.staleClones.keys).union(model.repatching)
        if let version = data.desktopVersion, let clone = data.cloneVendor, !clones.isEmpty {
            Banner(icon: "arrow.up.to.line",
                   text: model.repatching.isEmpty
                       ? "\(clone.desktopName) \(version) — \(clones.count) clone(s) behind"
                       : "\(clone.desktopName) \(version) — rebuilding \(model.repatching.count) of \(clones.count) clones") {
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
            ForEach(Array(data.profiles.enumerated()), id: \.element.name) { index, p in
                ProfileCard(profile: p, index: index, data: data, model: model, actions: actions)
                    .id(p.name)
            }
            NextBestButton(pick: model.nextBest, data: data, actions: actions)
        }
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, 12)
    }
}

// Never disappears, never lies. Next best is any lab, in any profile — the
// same rotation `agents run` uses when you don't say. Dimmed with no pick
// while the pick hangs on a quota reading; the pick, named, once it's known;
// flat, naming the soonest reset, when every signed-in slot is out — and
// clicking that one offers to open anyway.
private struct NextBestButton: View {
    let pick: NextBest?
    let data: PanelData
    let actions: PanelActions

    var body: some View {
        switch pick {
        case .slot(let profile, let vendorID, let used)?:
            Button { actions.openSession(profile: profile, vendor: vendorID, terminal: nil) } label: {
                row(icon: "bolt", iconColor: .accentColor, title: "Open next best") {
                    Text(verbatim: [data.snapshot.vendor(vendorID)?.label ?? vendorID, profile, used.map { "\($0)%" }]
                            .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(RowButtonStyle(radius: 8, border: true))
            .help("The next signed-in slot with room, in rotation — no lab is favoured")
        case .allMaxed(let firstBack)?:
            Button {
                popUp(data.profiles.flatMap { p in
                    data.snapshot.installedVendors.filter { p.slots[$0.id] != nil }.map { v in
                        ClosureItem("Open \(v.label) in “\(p.name)” anyway") {
                            actions.openSession(profile: p.name, vendor: v.id, terminal: nil)
                        }
                    }
                })
            } label: {
                row(icon: "clock", iconColor: maxedRed, title: "Everything is maxed") {
                    if let firstBack { Text("first back \(clockTime.string(from: firstBack))").foregroundStyle(maxedRed) }
                }
            }
            .buttonStyle(RowButtonStyle(radius: 8, border: true))
        case .nothingSignedIn?:
            row(icon: "bolt.slash", iconColor: .secondary, title: "Nothing is signed in") { EmptyView() }
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                .foregroundStyle(.secondary)
        case nil:
            row(icon: "bolt", iconColor: .primary, title: "Open next best") { EmptyView() }
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                .opacity(0.5)
        }
    }

    private func row<Trailing: View>(icon: String, iconColor: Color, title: LocalizedStringKey,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(iconColor)
            Text(title).font(.system(size: 12.5))
            Spacer()
            trailing().font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .contentShape(Rectangle())
    }
}

private struct ProfileCard: View {
    let profile: Profile
    let index: Int
    let data: PanelData
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    @State private var expanded = false

    private var isActive: Bool { data.snapshot.active == profile.name }
    // The card speaks for the whole profile, so its capacity treatment comes
    // from every lab it holds, not one. A lab with no usage reading is never
    // "out" — nothing says it is — so a profile only reads as maxed when each
    // of its labs is. Labs that are out on their own are named instead, and
    // their chips carry the maxed state.
    private func usage(for v: Vendor) -> Usage? { v.id == data.quotaVendor?.id ? quotaUsage : nil }
    private var labsOut: [(vendor: Vendor, until: Date?)] {
        slotted.compactMap { v in usage(for: v).flatMap { $0.maxed ? (v, $0.maxedUntil) : nil } }
    }
    /// Every lab out: the whole card tints so it's found at a glance.
    private var maxed: Bool { !slotted.isEmpty && labsOut.count == slotted.count }
    private var repatching: Bool { model.repatching.contains(profile.name) }
    private var stale: Bool { data.staleClones[profile.name] != nil }
    private var selected: Vendor? {
        guard let s = model.selection, s.profile == profile.name, profile.slots[s.vendor] != nil else { return nil }
        return data.snapshot.vendor(s.vendor)
    }
    private var slotted: [Vendor] { data.snapshot.installedVendors.filter { profile.slots[$0.id] != nil } }
    private var addable: Bool { data.snapshot.installedVendors.contains { profile.slots[$0.id] == nil } }

    // One row of chips keeps every card the same height; the rest sit behind
    // a +N chip. The selected lab is always on show.
    private static let chipLimit = 4
    private var showAll: Bool {
        expanded || slotted.count <= Self.chipLimit
            || (selected.map { v in !slotted.prefix(Self.chipLimit).contains { $0.id == v.id } } ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            nameRow
            detailRow
            FlowLayout(spacing: 4) {
                ForEach(showAll ? slotted : Array(slotted.prefix(Self.chipLimit)), id: \.id) { v in
                    VendorChip(vendor: v, active: profile.isActive(for: v.id), selected: selected?.id == v.id,
                               gauge: gauge(for: v),
                               signedOut: signedOut(v),
                               account: data.snapshot.account(profile.name, v.id)) {
                        model.selection = selected?.id == v.id ? nil : Selection(profile: profile.name, vendor: v.id)
                    }
                    .contextMenu {
                        if data.hasDesktop(v, for: profile) {
                            Button("Open \(v.desktopName)") { actions.openDesktop(profile: profile.name, vendor: v.id) }
                        }
                        Button("Sign In Again…") { actions.signIn(profile: profile.name, vendor: v.id, confirm: true) }
                    }
                }
                if !showAll {
                    SmallChip(title: "+\(slotted.count - Self.chipLimit)") { expanded = true }
                        .help("Show all \(slotted.count) labs")
                } else if expanded {
                    SmallChip(title: "−") { expanded = false }.help("Show fewer")
                }
                if addable && showAll {
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
            .fill(maxed ? maxedRed.opacity(0.13) : isActive ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius)
            .strokeBorder(maxed ? maxedRed.opacity(0.5) : isActive ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08)))
        .contextMenu {
            if !isActive { Button("Make Active for All Labs") { actions.setActive(profile: profile.name, vendor: nil) } }
            if addable { Button("Add Lab…") { actions.addVendor(profile: profile.name) } }
            Menu("Sign In Again") {
                ForEach(slotted, id: \.id) { v in
                    Button("\(v.label)…") { actions.signIn(profile: profile.name, vendor: v.id, confirm: true) }
                }
            }
            if profile.hasApp, let clone = data.cloneVendor {
                Button("Reveal \(clone.desktopName) Data") { actions.revealData(profile: profile.name) }
            }
            if !profile.isDefault {
                Divider()
                Button("Delete Profile…") { actions.deleteProfile(profile.name) }
            }
        }
    }

    private var quotaUsage: Usage? { model.usage[profile.name] }

    private func signedOut(_ v: Vendor) -> Bool {
        v.id == data.quotaVendor?.id && (quotaUsage?.note == .noToken || quotaUsage?.note == .staleToken)
    }

    // Four pictures that never look alike: a reading (track + fill), no
    // reading yet or a failed one (empty track), loading (sweep), and no
    // quota API at all (no track).
    private func gauge(for v: Vendor) -> ChipGauge? {
        guard v.id == data.quotaVendor?.id else { return nil }
        if let used = quotaUsage?.used { return .used(used) }
        if quotaUsage == nil && !model.usageSlow { return .loading }
        return .noReading
    }

    private var nameRow: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(profileColor(profile.name)).frame(width: 3, height: 18)
            Text(profile.name).font(.system(size: 13, weight: .medium))
            Spacer()
            Group {
                if let setup = pendingSetup {
                    Text("\(setup.done) of \(setup.labs.count) signed in").foregroundStyle(Color(nsColor: .systemOrange))
                } else if maxed {
                    // Back when the first lab is back.
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text(labsOut.compactMap(\.until).min().map { "Maxed until \(clockTime.string(from: $0))" } ?? "Maxed")
                    }
                    .foregroundStyle(maxedRed)
                } else if let out = labsOut.first {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        if labsOut.count == 1 {
                            Text(out.until.map { "\(out.vendor.label) out until \(clockTime.string(from: $0))" }
                                 ?? "\(out.vendor.label) out")
                        } else {
                            Text("\(labsOut.count) of \(slotted.count) labs out")
                        }
                    }
                    .foregroundStyle(Color(nsColor: .systemOrange))
                } else if repatching {
                    Text("Rebuilding…").foregroundStyle(.secondary)
                } else if stale {
                    Text("Update pending").foregroundStyle(Color(nsColor: .systemOrange))
                } else if let clone = data.cloneVendor, data.hasDesktop(clone, for: profile) {
                    // The profile's own desktop app: its state, and a click opens it.
                    Button { actions.openDesktop(profile: profile.name, vendor: clone.id) } label: {
                        HStack(spacing: 5) {
                            if profile.running { Circle().fill(Color(nsColor: .systemGreen)).frame(width: 6, height: 6) }
                            Text(profile.running ? "\(clone.desktopName) running" : "\(clone.desktopName) idle")
                            Image(systemName: "arrow.up.forward.app").font(.system(size: 9))
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(profile.running ? "Bring \(profile.name)'s \(clone.desktopName) forward" : "Open \(profile.name)'s \(clone.desktopName)")
                }
            }
            .font(.system(size: 10.5))
        }
        .frame(height: 18)
    }

    // Clone state outranks capacity: while a clone is behind, that is the
    // thing to act on. Otherwise the card carries the most constrained lab's
    // capacity — Claude's, as the only lab with a usage API today.
    // A setup left unfinished: labs chosen, and some known to be signed out.
    // (A lab that keeps its login out of sight counts as done, as in setup.)
    private var pendingSetup: (labs: [String], done: Int, missing: [String])? {
        guard let labs = model.pendingSetups[profile.name] else { return nil }
        let missing = labs.filter { data.snapshot.signedIn[profile.name]?[$0] == false }
        return missing.isEmpty ? nil : (labs, labs.count - missing.count, missing)
    }

    @ViewBuilder private var detailRow: some View {
        if let setup = pendingSetup {
            let names = setup.missing.compactMap { data.snapshot.vendor($0)?.label }
            InlineStatus(text: "\(names.joined(separator: ", ")) never finished signing in",
                         button: "Finish setup") { actions.finishSetup(profile: profile.name) }
        } else if repatching {
            ProgressView().progressViewStyle(.linear).controlSize(.small).tint(Color(nsColor: .systemOrange))
        } else if stale {
            InlineStatus(text: profile.running ? "Waiting — clone is in use"
                                               : actions.autoRepatch ? "Queued for rebuild" : "Auto-repatch is off",
                         button: "Rebuild Now") { actions.rebuildClone(profile.name) }
        } else if let v = data.quotaVendor, profile.slots[v.id] != nil {
            QuotaRegion(vendor: v, usage: quotaUsage, slow: model.usageSlow, index: index) {
                actions.signIn(profile: profile.name, vendor: v.id, confirm: false)
            } retry: {
                actions.retryUsage()
            }
        }
    }
}

// The card's capacity readout. Fixed height in every state — sweeping,
// filled, or a note with its action — so nothing below it moves when the
// reading lands.
private struct QuotaRegion: View {
    let vendor: Vendor
    let usage: Usage?
    let slow: Bool
    let index: Int
    let logIn: () -> Void
    let retry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let resetTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private var stateKey: String { usage?.note.rawValue ?? (slow ? "slow" : "loading") }

    var body: some View {
        ZStack(alignment: .leading) {
            content.transition(.opacity)
        }
        .frame(height: 29)
        .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.18), value: stateKey)
    }

    @ViewBuilder private var content: some View {
        switch usage?.note {
        case .ok?:
            // Fills rise from zero, cards 80 ms apart.
            let delay = reduceMotion ? 0 : Double(index) * 0.08
            VStack(spacing: 7) {
                MeterRow(label: "5h", percent: usage?.fiveHour,
                         meta: usage?.resets.map { "resets \(Self.resetTime.string(from: $0))" } ?? "", delay: delay)
                MeterRow(label: "7d", percent: usage?.sevenDay, meta: sevenDayMeta, delay: delay)
            }
        case .noToken?:
            InlineStatus(text: "\(vendor.label) quota unavailable — not signed in", button: "Log In", action: logIn)
        case .staleToken?:
            InlineStatus(text: "\(vendor.label) quota unavailable — token expired", button: "Log In", action: logIn)
        case .rateLimited?:
            InlineStatus(text: "\(vendor.label) quota check rate-limited", button: "Retry", action: retry)
        case .fetchError?:
            InlineStatus(text: "\(vendor.label) quota check failed", button: "Retry", action: retry)
        case .noUsageAPI?:
            EmptyView()
        case nil:
            if slow {
                Text("Checking quota…").font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) {
                    MeterRow(label: "5h", percent: nil, meta: "", delay: 0)
                    MeterRow(label: "7d", percent: nil, meta: "", delay: 0)
                }
            }
        }
    }

    // Which lab the bars belong to — or, when the last read failed and these
    // are the previous numbers, how old they are.
    private var sevenDayMeta: String {
        if let at = usage?.fetchedAt, Date().timeIntervalSince(at) > 360 {
            return "as of \(Int(Date().timeIntervalSince(at) / 60))m ago"
        }
        return vendor.label
    }
}

// label · bar · percent · meta. A nil percent is a reading still on its way:
// the bar sweeps and the number stays blank, in the same frame it will fill.
private struct MeterRow: View {
    let label: String
    let percent: Int?
    let meta: String
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 15, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    if let p = percent {
                        Capsule().fill(Color.primary.opacity(0.16))
                        Capsule().fill(p >= Usage.maxedAt ? maxedRed : meterColor(p))
                            .frame(width: g.size.width * CGFloat(min(max(p, 0), 100)) / 100)
                            .scaleEffect(x: filled ? 1 : 0, anchor: .leading)
                    } else {
                        Sweep().clipShape(Capsule())
                    }
                }
            }
            .frame(height: 4)
            Text(percent.map { "\($0)%" } ?? "").monospacedDigit().frame(width: 30, alignment: .trailing)
            Text(meta).foregroundStyle(.secondary).lineLimit(1).frame(width: 84, alignment: .trailing)
        }
        .font(.system(size: 10.5))
        .frame(height: 11)
        .animation(.easeOut(duration: 0.3), value: percent)
        .onAppear {
            guard percent != nil else { return }
            if reduceMotion {
                filled = true
            } else {
                withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42).delay(delay)) { filled = true }
            }
        }
    }
}

// Indeterminate progress: a 40%-wide highlight crossing its track every
// 1.4 s. Under Reduce Motion the track just sits at a static 30% tint.
private struct Sweep: View {
    var period: Double = 1.4
    var strength: Double = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Rectangle().fill(Color.primary.opacity(0.3))
        } else {
            TimelineView(.animation) { context in
                GeometryReader { g in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period) / period
                    let width = g.size.width * 0.4
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(strength), .white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                        .offset(x: width * (-1.2 + 4.4 * phase))
                }
            }
            .background(Color.primary.opacity(0.16))
            .clipped()
        }
    }
}

// Placeholder block for the very first launch, before anything was read.
private struct Pulse: View {
    let width: CGFloat?
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.primary.opacity(0.14))
            .frame(width: width, height: height)
            .opacity(reduceMotion ? 0.7 : bright ? 0.9 : 0.45)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

// Cold start only: the first launch before any snapshot was saved. Two
// placeholder cards — never a profile count guessed from nothing.
private struct ColdStart: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Profiles", detail: "")
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 7) {
                        Pulse(width: 3, height: 14)
                        Pulse(width: 58, height: 8)
                    }
                    Sweep(period: 1.6, strength: 0.07).frame(height: 3).clipShape(Capsule())
                    Sweep(period: 1.6, strength: 0.07).frame(height: 3).clipShape(Capsule())
                    HStack(spacing: 4) {
                        Pulse(width: 64, height: 17)
                        Pulse(width: 40, height: 17)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.primary.opacity(0.08)))
            }
            Text("Reading profiles…").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, 12)
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

enum ChipGauge: Equatable {
    case used(Int)    // 0–100 of the tighter window
    case noReading    // has a quota API; token stale or fetch failed
    case loading

    var maxed: Bool { if case .used(let u) = self { return u >= Usage.maxedAt }; return false }
}

private struct VendorChip: View {
    let vendor: Vendor
    let active: Bool
    let selected: Bool
    /// Nil for labs with no usage API — no gauge is drawn rather than a guessed one.
    let gauge: ChipGauge?
    let signedOut: Bool
    let account: String?
    let action: () -> Void

    // Filled accent = active for this lab, outlined = holds a slot, dashed =
    // a swap lab, where switching is a global side effect. The open drawer's
    // chip carries an accent ring.
    var body: some View {
        Button(action: action) {
            chip.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        // Blue = this profile is the lab's active one: what a plain run of the
        // lab's CLI in any terminal signs in as. Outlined = a slot held here,
        // with another profile active for the lab.
        var parts = [active ? "\(vendor.label) — active: a plain terminal session uses this profile"
                            : "\(vendor.label) — held by this profile; another profile is active for it"]
        if let account { parts.append(account) }
        if signedOut {
            parts.append("signed out")
        } else if case .used(let u)? = gauge {
            parts.append(u >= Usage.maxedAt ? "maxed" : "\(u)% used")
        }
        return parts.joined(separator: " · ")
    }

    // Maxed is a state, not a hue: clock glyph, dimmed label, full red bar.
    private var maxed: Bool { gauge?.maxed ?? false }

    private var chip: some View {
        HStack(spacing: 3) {
            if maxed {
                Image(systemName: "clock").font(.system(size: 8)).foregroundStyle(maxedRed)
            }
            if signedOut {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                    .foregroundStyle(active ? Color.white : Color(nsColor: .systemOrange))
            }
            if vendor.isolation == "swap" { Image(systemName: "arrow.left.arrow.right").font(.system(size: 8)) }
            Text(vendor.label).opacity(maxed ? 0.55 : 1)
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 6)
        .frame(height: 17)
        .foregroundStyle(active && !maxed ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(maxed ? maxedRed.opacity(0.15) : active ? Color.accentColor : Color.clear))
        .overlay(alignment: .bottom) {
            switch gauge {
            case .used(let u)?: UsageLine(percent: u)
            case .noReading?: Rectangle().fill(Color.primary.opacity(0.16)).frame(height: 2)
            case .loading?: Sweep().frame(height: 2)
            case nil: EmptyView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(maxed ? maxedRed.opacity(0.7)
                          : active ? Color.white.opacity(vendor.isolation == "swap" ? 0.6 : 0) : Color.primary.opacity(0.25),
                          style: StrokeStyle(lineWidth: 1, dash: vendor.isolation == "swap" ? [2.5, 2] : [])))
        .overlay(RoundedRectangle(cornerRadius: 5.5)
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
            .padding(-2)
            .opacity(selected ? 1 : 0))
    }
}

// +N / − beside the chips.
private struct SmallChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 10.5))
                .padding(.horizontal, 6)
                .frame(height: 17)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.25)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

// Used, along a chip's bottom edge. The track is always drawn and the fill
// is the number — length carries it, colour only reinforces. Maxed fills
// the whole track red.
private struct UsageLine: View {
    let percent: Int

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.16))
                Rectangle()
                    .fill(percent >= Usage.maxedAt ? maxedRed : meterColor(percent))
                    .frame(width: percent >= Usage.maxedAt ? g.size.width
                                                          : g.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
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
        // Capacity is on the card; the drawer says how the lab runs.
        [vendor.label, vendor.isolation == "swap" ? "one profile at a time" : "pinned per process"]
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 3)
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                OpenButton(terminals: data.terminals) { terminal in
                    actions.openSession(profile: profile.name, vendor: vendor.id, terminal: terminal)
                }
                if data.hasDesktop(vendor, for: profile) {
                    Button { actions.openDesktop(profile: profile.name, vendor: vendor.id) } label: {
                        Label(vendor.desktopName, systemImage: "macwindow").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(PillButtonStyle(height: 22))
                    .help(vendor.clonesDesktopApp ? "Open \(profile.name)'s \(vendor.desktopName)"
                                                  : "Open \(vendor.desktopName) — one app, signed in as the active profile")
                }
                if usage?.note == .noToken || usage?.note == .staleToken {
                    Button("Log In…") { actions.signIn(profile: profile.name, vendor: vendor.id, confirm: false) }
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
            DrawerRow(title: "Sign in again…") {
                actions.signIn(profile: profile.name, vendor: vendor.id, confirm: true)
            } trailing: {
                if let account = data.snapshot.account(profile.name, vendor.id) {
                    Text(account).lineLimit(1).truncationMode(.middle)
                }
            }
            .help("Sign this profile's \(vendor.label) out and back in, e.g. after using the wrong account")
            if vendor.hasSessions {
                DrawerRow(title: "Transfer session…") { actions.transferSession(profile: profile.name, vendor: vendor.id) }
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
            SectionLabel(title: "Recent sessions", detail: "")
            ForEach(data.sessions.prefix(2), id: \.id) { s in
                Button { actions.resumeSession(s) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(profileColor(s.profile)).frame(width: 6, height: 6).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.cwd.map { ($0 as NSString).lastPathComponent } ?? "—")
                                .font(.system(size: 12.5))
                            Text(s.snippet).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(data.snapshot.vendor(s.vendor)?.label ?? s.vendor) · \(Self.age.string(from: s.mtime, to: Date()) ?? "")")
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
            Text("A profile is one identity holding a slot per lab — they all move together when you switch.")
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
