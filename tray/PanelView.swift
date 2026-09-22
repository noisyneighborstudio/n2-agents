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
    percent < 50 ? Ink.green : percent < 80 ? Ink.amber : Ink.red
}

private let maxedRed = Ink.red

/// "3:20 PM" today, "Fri 3:20 PM" further out — a weekly window resets days away.
private func clockTime(_ date: Date) -> String {
    date.formatted(Calendar.current.isDateInToday(date) ? .dateTime.hour().minute()
                                                        : .dateTime.weekday(.abbreviated).hour().minute())
}

// MARK: - Root

// Loading follows one rule: draw at once from what is already known, and let
// only capacity — the one slow, networked reading — arrive later. A blank
// panel is a bug, not a loading state.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A lab's mark and gauge travel between depth 1 and depth 2 rather than
    /// one view dissolving into the other.
    @Namespace private var slots

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
                FittingScroll(maxHeight: Self.bodyLimit, focus: model.expanded) {
                    VStack(spacing: 0) {
                        if data.profiles.count > 1 {
                            // The answer for anyone who doesn't need to choose,
                            // above the diagnostics rather than below them.
                            NextBestButton(pick: model.nextBest, data: data, actions: actions)
                                .padding(.horizontal, Metrics.side)
                                .padding(.vertical, 12)
                        }
                        Banners(data: data, model: model, actions: actions)
                        if data.profiles.count <= 1 {
                            FirstRun(actions: actions)
                        } else {
                            ProfilesSection(data: data, model: model, actions: actions, namespace: slots)
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
            // Mid-animation the frame trails the content, which would read as
            // scrollable and flash the scroller on every card opened. Only a
            // panel taller than the screen scrolls.
            .scrollIndicators(contentHeight > maxHeight ? .automatic : .never)
            .scrollDisabled(contentHeight <= maxHeight)
            // On the content's own curve: set bare, the frame (and the footer
            // under it) would jump to the new height while the cards animate.
            // The first measurement lands as is — the panel opens at size.
            .onPreferenceChange(ContentHeight.self) { height in
                let first = contentHeight == 0
                withAnimation(first || reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)) {
                    contentHeight = height
                }
            }
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
                        Text("Active").foregroundStyle(Ink.secondary)
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
            ClosureItem(p.name, symbol: "person.crop.circle", checked: p.name == data.snapshot.active) {
                actions.setActive(profile: p.name, vendor: nil)
            }
        })
    }

    private func popUpSettingsMenu() {
        var items: [NSMenuItem] = [ClosureItem("New Profile…", symbol: "person.badge.plus") { actions.newProfile() },
                                   .separator()]
        if let terms = model.data?.terminals, terms.count > 1 {
            items.append(submenu("Open Sessions In", symbol: "terminal", terms.enumerated().map { i, name in
                ClosureItem(name, symbol: "terminal", checked: i == 0) { actions.setPreferredTerminal(name) }
            }))
        }
        let channel = UpdateChannel.selected()
        items.append(submenu("Update Channel", symbol: "dial.medium", UpdateChannel.allCases.map { c in
            ClosureItem(c.rawValue.capitalized, symbol: "shippingbox", checked: c == channel) { actions.setUpdateChannel(c) }
        }))
        if let clone = model.data?.cloneVendor {
            if model.data?.desktopInstalled == true {
                items.append(ClosureItem("Auto-repatch \(clone.desktopName) Clones",
                                         symbol: "arrow.triangle.2.circlepath",
                                         checked: actions.autoRepatch) {
                    actions.setAutoRepatch(!actions.autoRepatch)
                })
                items.append(ClosureItem("Re-patch All Clones Now", symbol: "hammer") { actions.repatchAll() })
            }
            items.append(ClosureItem("Locate \(clone.desktopName)…", symbol: "folder.badge.questionmark") { actions.locateClaude() })
        }
        items.append(.separator())
        items.append(ClosureItem("Check for Updates…", symbol: "arrow.down.circle") { actions.checkForUpdates() })
        popUp(items)
    }
}

private struct PanelFooter: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    private var fullVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    // "1.2.0 (16)": the channel already says "continuous", and a prerelease
    // counter resets with every stable release; the build number always climbs.
    private var versionLine: LocalizedStringKey {
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
        let version = "\(fullVersion.prefix { $0 != "-" }) (\(build))"
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
        return "N2 Agents \(fullVersion) — check for updates"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(versionLine) { actions.checkForUpdates() }
                .buttonStyle(.plain)
                .help(updateHelp)
                .foregroundStyle(model.updateStatus == .available ? Ink.link : Ink.secondary)
            Spacer()
            Button { actions.reportBug() } label: {
                Label("Report a Bug", systemImage: "ladybug")
            }.buttonStyle(.plain).foregroundStyle(Ink.link)
            Button { actions.quit() } label: {
                Label("Quit", systemImage: "power")
            }.buttonStyle(.plain).foregroundStyle(Ink.link)
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
                Button { actions.locateClaude() } label: {
                    Label("Locate…", systemImage: "folder.badge.questionmark")
                }
                Button { actions.downloadClaude() } label: {
                    Label("Download…", systemImage: "arrow.down.circle")
                }
            }
        }
        let clones = Set(data.staleClones.keys).union(model.repatching)
        if let version = data.desktopVersion, let clone = data.cloneVendor, !clones.isEmpty {
            Banner(icon: "arrow.up.to.line",
                   text: model.repatching.isEmpty
                       ? "\(clone.desktopName) \(version) — \(clones.count) clone(s) behind"
                       : "\(clone.desktopName) \(version) — rebuilding \(model.repatching.count) of \(clones.count) clones") {
                Button { actions.showCloneDetails() } label: {
                    Label("Details", systemImage: "list.bullet")
                }
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
                Image(systemName: icon).foregroundStyle(Ink.amber)
                Text(text).font(.system(size: 11.5))
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) { buttons }
                .buttonStyle(PillButtonStyle(tint: Ink.amber))
                .padding(.leading, 22)
        }
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.amber.opacity(0.16))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Profiles

private struct SectionLabel: View {
    let title: LocalizedStringKey
    let detail: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(title)
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.55)
            Spacer()
            Text(verbatim: detail).font(.system(size: 11))
        }
        .foregroundStyle(Ink.secondary)
    }
}

private struct ProfilesSection: View {
    let data: PanelData
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    let namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Profiles", detail: "\(data.profiles.count)", symbol: "person.2")
            ForEach(data.profiles, id: \.name) { p in
                ProfileCard(profile: p, data: data, model: model, actions: actions, namespace: namespace)
                    .id(p.name)
            }
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
                row(icon: "bolt", iconColor: Ink.link, title: "Open next best") {
                    Text(verbatim: [data.snapshot.vendor(vendorID)?.label ?? vendorID, profile, used.map { "\($0)% used" }]
                            .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(Ink.secondary)
                }
            }
            .buttonStyle(RowButtonStyle(radius: 8, border: true))
            .help("The next signed-in slot with room, in rotation — no lab is favoured")
        case .allMaxed(let firstBack)?:
            Button {
                popUp(data.profiles.flatMap { p in
                    data.snapshot.installedVendors.filter { p.slots[$0.id] != nil }.map { v in
                        ClosureItem("Open \(v.label) in “\(p.name)” anyway", symbol: "terminal") {
                            actions.openSession(profile: p.name, vendor: v.id, terminal: nil)
                        }
                    }
                })
            } label: {
                row(icon: "clock", iconColor: maxedRed, title: "Everything is maxed") {
                    if let firstBack { Text("first back \(clockTime(firstBack))").foregroundStyle(maxedRed) }
                }
            }
            .buttonStyle(RowButtonStyle(radius: 8, border: true))
        case .nothingSignedIn?:
            row(icon: "bolt.slash", iconColor: Ink.secondary, title: "Nothing is signed in") { EmptyView() }
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                .foregroundStyle(Ink.secondary)
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
    let data: PanelData
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { data.snapshot.active == profile.name }
    private var slotted: [Vendor] { data.slotted(profile) }
    private var addable: Bool { data.snapshot.installedVendors.contains { profile.slots[$0.id] == nil } }
    private var open: Bool { model.expanded == profile.name }
    private var repatching: Bool { model.repatching.contains(profile.name) }
    private var stale: Bool { data.staleClones[profile.name] != nil }
    private var reading: (state: ProfileState, used: Int?) { model.reading(profile, data) }
    private var allOut: Bool { if case .allOut = reading.state { return true }; return false }

    // A setup left unfinished: labs chosen, and some known to be signed out.
    private var pendingSetup: (labs: [String], done: Int, missing: [String])? {
        guard let labs = model.pendingSetups[profile.name] else { return nil }
        let missing = labs.filter { data.snapshot.signedIn[profile.name]?[$0] == false }
        return missing.isEmpty ? nil : (labs, labs.count - missing.count, missing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Depth 1: whose it is, whether you can work, where. At rest the
            // card is these two rows and nothing else, so three profiles read
            // as a column rather than three shapes.
            Button { toggle() } label: {
                VStack(alignment: .leading, spacing: 7) {
                    nameRow
                    if !open {
                        CapacityStrip(profile: profile, data: data, model: model, namespace: namespace)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)

            fixStrip

            // Depth 2: the strip resolved into one row per lab.
            if open {
                VStack(spacing: 1) {
                    ForEach(slotted, id: \.id) { v in
                        SlotRow(profile: profile, vendor: v, data: data, model: model,
                                actions: actions, namespace: namespace)
                    }
                    if addable {
                        Button { actions.addVendor(profile: profile.name) } label: {
                            Label("Add a lab…", systemImage: "plus")
                                .font(.system(size: 11))
                                .foregroundStyle(Ink.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 3)
                                .frame(height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle(radius: 5))
                    }
                }
                .padding(.top, 7)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Ink.surface)
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .fill(allOut ? maxedRed.opacity(0.13) : isActive ? Color.accentColor.opacity(0.16) : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius)
            .strokeBorder(allOut ? maxedRed.opacity(0.5)
                          : isActive ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08)))
        .contextMenu {
            if !isActive {
                Button { actions.setActive(profile: profile.name, vendor: nil) } label: {
                    Label("Make Active for All Labs", systemImage: "checkmark.circle")
                }
            }
            if addable {
                Button { actions.addVendor(profile: profile.name) } label: {
                    Label("Add Lab…", systemImage: "plus")
                }
            }
            if profile.hasApp, let clone = data.cloneVendor {
                Button { actions.revealData(profile: profile.name) } label: {
                    Label("Reveal \(clone.desktopName) Data", systemImage: "folder")
                }
            }
            if !profile.isDefault {
                Divider()
                Button(role: .destructive) { actions.deleteProfile(profile.name) } label: {
                    Label("Delete Profile…", systemImage: "trash")
                }
            }
        }
    }

    /// One profile open at a time: the panel's height stays bounded, which is
    /// what lets depth 3 open in place instead of floating over everything.
    private func toggle() {
        withAnimation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)) {
            model.selection = nil
            model.expanded = open ? nil : profile.name
        }
    }

    private var nameRow: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(profileColor(profile.name)).frame(width: 3, height: 18)
            Text(profile.name).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 6)
            statusLabel
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .frame(height: 18)
    }

    // The status slot answers one question — can I work here — in a closed
    // vocabulary, with the profile's capacity beside it. A desktop app's
    // process state and a pending rebuild are not capacity; they live deeper
    // and in the banner respectively.
    @ViewBuilder private var statusLabel: some View {
        let s = status
        HStack(spacing: 4) {
            if case .ready = reading.state {
                Circle().fill(Ink.green).frame(width: 6, height: 6)
            } else if let icon = s.icon {
                Image(systemName: icon)
            }
            Text(s.text)
            if let used = reading.used {
                Text(verbatim: "· \(used)% used").monospacedDigit().fontWeight(.semibold).foregroundStyle(.primary)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(s.tint)
        .lineLimit(1)
    }

    private var status: (icon: String?, text: String, tint: Color) {
        switch reading.state {
        case .ready:             return (nil, "Ready", Ink.secondary)
        case .checking:          return (nil, "Checking…", Ink.secondary)
        case .allOut:            return ("clock", "All out", maxedRed)
        case .labsOut(let out, let of, _):
            return ("clock", "\(out) of \(of) out", Ink.amber)
        case .needsSignIn(let n):
            return ("exclamationmark.triangle", n == 1 ? "1 needs sign-in" : "\(n) need sign-in", Ink.amber)
        case .notSignedIn:       return ("exclamationmark.triangle", "Not signed in", Ink.amber)
        }
    }

    private var helpText: String {
        var parts: [String] = [status.text]
        if let used = reading.used { parts.append("\(used)% used across \(slotted.count) labs") }
        switch reading.state {
        case .allOut(let until), .labsOut(_, _, let until):
            if let until { parts.append("first back \(clockTime(until))") }
        default: break
        }
        return parts.joined(separator: " · ")
    }

    // Only present when there is something to act on.
    @ViewBuilder private var fixStrip: some View {
        if let setup = pendingSetup {
            let names = setup.missing.compactMap { data.snapshot.vendor($0)?.label }
            InlineStatus(text: "\(names.joined(separator: ", ")) never finished signing in",
                         button: "Finish setup", symbol: "key") { actions.finishSetup(profile: profile.name) }
                .padding(.top, 7)
        } else if repatching {
            ProgressView().progressViewStyle(.linear).controlSize(.small).tint(Ink.amber)
                .padding(.top, 7)
        } else if stale {
            InlineStatus(text: profile.running ? "Waiting — clone is in use"
                                               : actions.autoRepatch ? "Queued for rebuild" : "Auto-repatch is off",
                         button: "Rebuild Now", symbol: "hammer") { actions.rebuildClone(profile.name) }
                .padding(.top, 7)
        }
    }
}

// MARK: - Depth 2: one row per lab

// The lab, its binding window, and when that window comes back. The mark and
// the gauge arrive from the strip rather than fading in, so the row reads as
// the same segment resolved.
private struct SlotRow: View {
    let profile: Profile
    let vendor: Vendor
    let data: PanelData
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usage: Usage? { model.usage[vendor.id]?[profile.name] }
    private var signedOut: Bool { data.snapshot.signedIn[profile.name]?[vendor.id] == false }
    private var open: Bool { model.selection == Selection(profile: profile.name, vendor: vendor.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { toggle() } label: {
                HStack(spacing: 7) {
                    LabMark(vendor: vendor)
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
                        .matchedGeometryEffect(id: SlotID.mono(profile.name, vendor.id), in: namespace)
                    Text(vendor.label)
                        .font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                        .frame(width: 74, alignment: .leading)
                    detail
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 3)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle(radius: 5, resting: open ? 0.07 : 0))
            if open {
                SlotActions(profile: profile, vendor: vendor, data: data, model: model, actions: actions)
            }
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)) {
            model.selection = open ? nil : Selection(profile: profile.name, vendor: vendor.id)
        }
    }

    @ViewBuilder private var detail: some View {
        if !vendor.hasUsageAPI {
            flat("minus.circle", "no quota API", Ink.secondary)
        } else if signedOut {
            flat("exclamationmark.triangle", "not signed in", Ink.amber)
        } else if let u = usage, let b = u.binding {
            Gauge(percent: b.percent)
                .frame(height: 4)
                .matchedGeometryEffect(id: SlotID.gauge(profile.name, vendor.id), in: namespace)
            Text(verbatim: "\(b.percent)% used")
                .font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(u.maxed ? maxedRed : .primary)
                .frame(width: 56, alignment: .trailing)
            meta(u, b)
        } else if let note = usage?.note {
            flat(note == .staleToken ? "exclamationmark.triangle" : "arrow.clockwise", label(for: note), Ink.amber)
        } else if model.usageSlow {
            flat(nil, "checking…", Ink.secondary)
        } else {
            Sweep().clipShape(Capsule())
                .frame(height: 4)
                .matchedGeometryEffect(id: SlotID.gauge(profile.name, vendor.id), in: namespace)
            Text(verbatim: "").frame(width: 30)
            Text(verbatim: "").frame(width: 88)
        }
    }

    // The window tag rides with the time: depth 2 has one bar, so a separate
    // column for "5h" was spending width the gauge needed.
    private func meta(_ u: Usage, _ b: (tag: String, percent: Int, resets: Date?)) -> some View {
        HStack(spacing: 3) {
            if u.maxed { Image(systemName: "clock").font(.system(size: 8)) }
            Text(u.maxed ? (u.maxedUntil.map(clockTime) ?? "out")
                         : b.resets.map { "\(b.tag) · \(clockTime($0))" } ?? b.tag)
        }
        .font(.system(size: 10))
        .foregroundStyle(u.maxed ? maxedRed : Ink.secondary)
        .lineLimit(1)
        .frame(width: 88, alignment: .trailing)
    }

    private func flat(_ icon: String?, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if let icon { Image(systemName: icon).font(.system(size: 8)) }
            Text(text)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(tint)
        .lineLimit(1)
    }

    private func label(for note: Usage.Note) -> String {
        switch note {
        case .noToken:     return "not signed in"
        case .staleToken:  return "token expired"
        case .rateLimited: return "rate-limited"
        case .fetchError:  return "check failed"
        default:           return "no reading"
        }
    }
}

// MARK: - Depth 3: everything for one slot

// Both windows in full, then the actions in one order that never varies:
// Start, then Fix when something is actually broken, then Configure. The
// primary action is the only filled control.
private struct SlotActions: View {
    let profile: Profile
    let vendor: Vendor
    let data: PanelData
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    @State private var copied = false

    private var usage: Usage? { model.usage[vendor.id]?[profile.name] }
    private var signedOut: Bool {
        data.snapshot.signedIn[profile.name]?[vendor.id] == false
            || usage?.note == .staleToken || usage?.note == .noToken
    }
    private var blocked: Bool { usage?.maxed ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let u = usage, u.note == .ok {
                if let five = u.fiveHour {
                    MeterRow(label: "5h", percent: five,
                             meta: u.resets.map(clockTime) ?? "", delay: 0)
                }
                if let seven = u.sevenDay {
                    MeterRow(label: "7d", percent: seven,
                             meta: u.sevenResets.map(clockTime) ?? "", delay: 0)
                }
            }

            group("Start", "bolt")
            OpenButton(terminals: data.terminals, blocked: blocked) { terminal in
                actions.openSession(profile: profile.name, vendor: vendor.id, terminal: terminal)
            }
            if data.hasDesktop(vendor, for: profile) {
                ActionRow(title: "Open \(vendor.desktopName)", icon: "macwindow") {
                    actions.openDesktop(profile: profile.name, vendor: vendor.id)
                }
            }

            if signedOut {
                group("Fix", "wrench.adjustable")
                ActionRow(title: "Sign in…", icon: "key", tint: Ink.amber) {
                    actions.signIn(profile: profile.name, vendor: vendor.id, confirm: false)
                }
            }

            group("Configure", "slider.horizontal.3")
            if !profile.isActive(for: vendor.id) {
                ActionRow(title: vendor.isolation == "swap" ? "Switch to this profile" : "Use for new sessions",
                          icon: vendor.isolation == "swap" ? "arrow.left.arrow.right" : "checkmark.circle",
                          trailing: vendor.isolation == "swap" ? "changes it everywhere" : nil) {
                    actions.setActive(profile: profile.name, vendor: vendor.id)
                }
            }
            ActionRow(title: "Copy command", icon: "doc.on.doc",
                      trailing: copied ? "Copied" : "\(vendor.id)-\(profile.name.lowercased())", mono: true) {
                actions.copyCommand(profile: profile.name, vendor: vendor.id)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            if let account = data.snapshot.account(profile.name, vendor.id) {
                ActionRow(title: account, icon: "person.crop.circle", trailing: "Sign in again…") {
                    actions.signIn(profile: profile.name, vendor: vendor.id, confirm: true)
                }
            }
            if vendor.hasSessions {
                ActionRow(title: "Transfer session…", icon: "arrowshape.turn.up.right") {
                    actions.transferSession(profile: profile.name, vendor: vendor.id)
                }
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.14)).frame(width: 2)
        }
        .padding(.leading, 12)
        .padding(.top, 3)
        .padding(.bottom, 5)
    }

    private func group(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 8))
            Text(title).textCase(.uppercase).tracking(0.5)
        }
        .font(.system(size: 8.5, weight: .semibold))
        .foregroundStyle(Ink.secondary)
        .padding(.top, 4)
    }
}

private struct ActionRow: View {
    let title: String
    let icon: String
    var tint: Color = .primary
    var trailing: String? = nil
    var mono = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 10)).frame(width: 12)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10.5, design: mono ? .monospaced : .default))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .frame(height: 23)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(radius: 5))
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
            Text(label).foregroundStyle(Ink.secondary).frame(width: 15, alignment: .leading)
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
            Text(meta).foregroundStyle(Ink.secondary).lineLimit(1).frame(width: 84, alignment: .trailing)
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
            SectionLabel(title: "Profiles", detail: "", symbol: "person.2")
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
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Ink.surface))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.primary.opacity(0.08)))
            }
            Text("Reading profiles…").font(.system(size: 11)).foregroundStyle(Ink.secondary)
        }
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, 12)
    }
}

private struct InlineStatus: View {
    let text: LocalizedStringKey
    let button: LocalizedStringKey
    var symbol: String = "wrench.adjustable"
    let action: () -> Void

    var body: some View {
        HStack {
            Text(text).font(.system(size: 11)).foregroundStyle(Ink.secondary)
            Spacer(minLength: 6)
            Button(action: action) { Label(button, systemImage: symbol) }
                .buttonStyle(PillButtonStyle())
        }
    }
}

// MARK: - Depth 1: the capacity strip

// The lab's two-letter mark, as ProfileSetup already draws it. Fixed width is
// the whole point: seven labs fit one row with no overflow control, where word
// chips wrapped and needed a +N to hide the rest.
// One lab at depth 1: its mark over its headroom. Four pictures that never look
// alike — a reading, no quota API at all (dashed), signed out (amber), and a
// reading still on its way (sweep).
private struct CapacitySegment: View {
    let profile: String
    let vendor: Vendor
    let usage: Usage?
    let signedOut: Bool
    let slow: Bool
    let namespace: Namespace.ID

    private var used: Int? { usage?.used }
    private var maxed: Bool { (used ?? 0) >= Usage.maxedAt }

    var body: some View {
        VStack(spacing: 3) {
            LabMark(vendor: vendor)
                .foregroundStyle(maxed ? maxedRed : signedOut ? Ink.amber : Ink.secondary)
                .opacity(vendor.hasUsageAPI ? 1 : 0.5)
                .matchedGeometryEffect(id: SlotID.mono(profile, vendor.id), in: namespace)
            track
                .frame(height: 4)
                .matchedGeometryEffect(id: SlotID.gauge(profile, vendor.id), in: namespace)
        }
        .help(helpText)
    }

    private var helpText: String {
        var parts = [vendor.label]
        if !vendor.hasUsageAPI { parts.append("no quota API") }
        else if signedOut { parts.append("not signed in") }
        else if let u = used { parts.append(u >= Usage.maxedAt ? "maxed" : "\(u)% used") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var track: some View {
        if !vendor.hasUsageAPI {
            Capsule().strokeBorder(Color.primary.opacity(0.22),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        } else if signedOut {
            Capsule().fill(Ink.amber.opacity(0.18))
                .overlay(Capsule().strokeBorder(Ink.amber.opacity(0.45)))
        } else if let u = used {
            Gauge(percent: u)
        } else if slow {
            Capsule().fill(Color.primary.opacity(0.16))
        } else {
            Sweep().clipShape(Capsule())
        }
    }
}

// Track plus fill. The length is the reading; colour only reinforces it.
private struct Gauge: View {
    let percent: Int

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.16))
                Capsule().fill(percent >= Usage.maxedAt ? maxedRed : meterColor(percent))
                    .frame(width: g.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
            }
        }
    }
}

// Shared geometry ids, so a lab's mark and gauge travel between depth 1 and
// depth 2 rather than one view dissolving into another.
private enum SlotID {
    static func mono(_ profile: String, _ vendor: String) -> String { "mono-\(profile)-\(vendor)" }
    static func gauge(_ profile: String, _ vendor: String) -> String { "gauge-\(profile)-\(vendor)" }
}

// Every lab the profile holds, in one fixed-height row. Segments share the
// width but never stretch past 52 pt, so a profile with two labs doesn't draw
// two bars across half the panel.
private struct CapacityStrip: View {
    let profile: Profile
    let data: PanelData
    @ObservedObject var model: PanelModel
    let namespace: Namespace.ID

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(data.slotted(profile), id: \.id) { v in
                CapacitySegment(profile: profile.name, vendor: v,
                                usage: model.usage[v.id]?[profile.name],
                                signedOut: data.snapshot.signedIn[profile.name]?[v.id] == false,
                                slow: model.usageSlow, namespace: namespace)
                    .frame(maxWidth: 52)
            }
            Spacer(minLength: 0)
        }
    }
}

// "Open in <terminal>" with a chevron for picking another terminal this once.
private struct OpenButton: View {
    let terminals: [String]
    /// Every window is spent; opening anyway is still allowed, and says so.
    var blocked = false
    let open: (String?) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { open(nil) } label: {
                Label(blocked ? "Open in \(terminals.first ?? "Terminal") anyway"
                              : "Open in \(terminals.first ?? "Terminal")", systemImage: "terminal")
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 9)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if terminals.count > 1 {
                Divider().frame(height: 14)
                Button {
                    popUp(terminals.map { name in ClosureItem(name, symbol: "terminal") { open(name) } })
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

// A small tag. Takes a monogram when the thing has one, a symbol otherwise —
// never bare text, so a row can be scanned rather than read.
private struct Chip: View {
    var text: String? = nil
    var vendor: Vendor? = nil
    var symbol: String? = nil
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 3) {
            if let vendor {
                LabMark(vendor: vendor, size: 9)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
            }
            if let text { Text(text).font(.system(size: 10)) }
        }
        .padding(.horizontal, text == nil ? 3.5 : 5)
        .frame(height: 16)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.28)))
        .fixedSize()
    }
}

// MARK: - Sessions

private struct SessionsSection: View {
    let data: PanelData
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { actions.showAllSessions() } label: {
                HStack(spacing: 5) {
                    SectionLabel(title: "Recent sessions", detail: "", symbol: "clock.arrow.circlepath")
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open all sessions")
            ForEach(data.sessions.prefix(2), id: \.id) { s in
                SessionRow(session: s, data: data, actions: actions)
            }
        }
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, 12)
    }
}

// Where it was and what it was doing are two different questions, so they get
// two lines. The tags ride with the folder; the summary — the line you
// actually recognise a session by — gets the full width instead of the scraps
// left over beside them.
private struct SessionRow: View {
    let session: SessionInfo
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
        Button { actions.resumeSession(session) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.cwd.map { ($0 as NSString).lastPathComponent } ?? "—")
                        .font(.system(size: 12.5))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Chip(text: session.profile, symbol: "person.crop.circle",
                         tint: profileColor(session.profile))
                    // The logo is the lab's name; spelling it out again was
                    // costing the summary its width.
                    if let v = data.snapshot.vendor(session.vendor) {
                        Chip(vendor: v, tint: Ink.secondary)
                    }
                    Text(Self.age.string(from: session.mtime, to: Date()) ?? "")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(Ink.secondary)
                        .frame(minWidth: 22, alignment: .trailing)
                }
                Text(session.snippet)
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    .lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(minHeight: 56, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(radius: 7, resting: 0.05))
        .help("Resume in \(session.profile)")
    }
}

// The panel keeps two sessions. This is the rest of the list, in a window of
// its own: same rows, wide enough that the prompt can actually be read.
struct SessionsWindowView: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    private static let width: CGFloat = 560
    private static var listLimit: CGFloat {
        ((NSScreen.main?.visibleFrame.height ?? 800) - 44 - 48) * 0.72
    }

    private var rows: [SessionInfo] {
        model.allSessions.isEmpty ? (model.data?.sessions ?? []) : model.allSessions
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                Text("Recent sessions").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !rows.isEmpty {
                    Text("\(rows.count)")
                        .font(.system(size: 11))
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
            Divider()
            if let data = model.data, !rows.isEmpty {
                FittingScroll(maxHeight: Self.listLimit, focus: nil) {
                    VStack(spacing: 6) {
                        ForEach(rows, id: \.id) { s in
                            SessionRow(session: s, data: data, actions: actions)
                        }
                    }
                    .padding(Metrics.side)
                }
            } else {
                Text("No sessions yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
        }
        .frame(width: Self.width)
    }
}

// MARK: - First run

private struct FirstRun: View {
    let actions: PanelActions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "asterisk").font(.system(size: 28, weight: .light)).foregroundStyle(Ink.secondary)
            Text("No profiles yet").font(.system(size: 13, weight: .semibold))
            Text("A profile is one identity holding a slot per lab — they all move together when you switch.")
                .font(.system(size: 11.5))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { actions.newProfile() } label: {
                Label("New Profile…", systemImage: "person.badge.plus")
            }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            Text("Your current logins stay put as “Default”.")
                .font(.system(size: 11))
                .foregroundStyle(Ink.secondary)
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
            // Rows that stand alone (bordered, or resting with a fill) sit on
            // the card surface; rows inside a card already have it.
            .background(RoundedRectangle(cornerRadius: radius).fill(border || resting > 0 ? Ink.surface : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color.primary.opacity(border ? 0.12 : 0)))
            .onHover { hovering = $0 }
    }
}

// MARK: - AppKit menus

// SwiftUI's Menu flattens custom labels on macOS, so the panel's menus are
// plain NSMenus popped at the pointer.
final class ClosureItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, checked: Bool = false,
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

private func submenu(_ title: String, symbol: String? = nil, _ items: [NSMenuItem]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
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
