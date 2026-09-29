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

/// "3:20 PM" today, "Fri 3:20 PM" further out — a weekly window resets days away.
// A weekday names a day only within the week: a monthly reset gets its date.
private func clockTime(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
    if date.timeIntervalSinceNow > 6 * 86400 { return date.formatted(.dateTime.month(.abbreviated).day()) }
    return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
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
                        if data.profiles.count <= 1 {
                            FirstRun(actions: actions)
                        } else {
                            ProfilesSection(data: data, model: model, actions: actions, namespace: slots)
                            if !data.sessions.isEmpty {
                                Divider()
                                SessionsSection(data: data, actions: actions)
                            }
                        }
                        // The fleet sits below this machine's own profiles on
                        // purpose: the local machine is what the panel is for,
                        // and the other Macs are the second question.
                        if let fleetActions = actions as? FleetActions {
                            Divider()
                            FleetSection(model: model, actions: fleetActions)
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
            Button { actions.showSettings() } label: {
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
        return UpdateChannel.isQABuild ? "\(version) · QA build" : "\(version)"
    }

    private var statusSymbol: String? {
        switch model.updateStatus {
        case .upToDate: return "checkmark.circle"
        case .available: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.triangle"
        case nil: return nil
        }
    }

    private var updateHelp: String {
        if UpdateChannel.isQABuild { return "Local QA build — never updates itself" }
        let channel = "\(UpdateChannel.selected().rawValue.capitalized) channel"
        switch model.updateStatus {
        case .upToDate?: return "N2 Agents \(fullVersion) (\(channel)) is up to date"
        case .available?: return "Update available on the \(channel) — click to install"
        case .failed(let reason)?: return "Update check failed: \(reason) Click to retry."
        case nil: return "N2 Agents \(fullVersion) (\(channel)) — check for updates"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { actions.checkForUpdates() } label: {
                HStack(spacing: 4) {
                    Text(versionLine)
                    if !UpdateChannel.isQABuild {
                        let channel = UpdateChannel.selected()
                        Image(systemName: channel.symbol).fontWeight(.light)
                            .accessibilityLabel("\(channel.rawValue.capitalized) channel")
                    }
                    if let statusSymbol { Image(systemName: statusSymbol).accessibilityLabel(updateHelp) }
                }.lineLimit(1)
            }
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
                    Text(verbatim: [data.snapshot.vendor(vendorID)?.label ?? vendorID, profile, used.map { "\($0)% used" } ?? "usage unmeasured"]
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
                row(icon: "clock", iconColor: Ink.red, title: "Everything is maxed") {
                    if let firstBack { Text("first back \(clockTime(firstBack))").foregroundStyle(Ink.red) }
                }
            }
            .buttonStyle(RowButtonStyle(radius: 8, border: true))
        case .usageUnavailable?:
            Button { actions.retryUsage() } label: {
                row(icon: "arrow.clockwise", iconColor: Ink.secondary, title: "Usage unavailable") {
                    Text("Refresh").foregroundStyle(Ink.link)
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
    private var reading: (state: ProfileState, used: Int?) { model.reading(profile, data) }
    private var allOut: Bool { if case .allOut = reading.state { return true }; return false }

    // Persisted unfinished labs, including vendors whose credentials cannot be inspected.
    private var pendingSetup: (labs: [String], done: Int, missing: [String])? {
        guard let labs = model.pendingSetups[profile.name] else { return nil }
        let missing = labs
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
                .fill(allOut ? Ink.red.opacity(0.13) : isActive ? Color.accentColor.opacity(0.16) : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius)
            .strokeBorder(allOut ? Ink.red.opacity(0.5)
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
        case .usageUnknown:      return ("questionmark.circle", "Usage unknown", Ink.amber)
        case .allOut:            return ("clock", "All out", Ink.red)
        case .labsOut(let out, let of, _):
            return ("clock", "\(out) of \(of) out", Ink.amber)
        case .needsSignIn(let n):
            return ("exclamationmark.triangle", n == 1 ? "1 needs sign-in" : "\(n) need sign-in", Ink.amber)
        case .notSignedIn:       return ("exclamationmark.triangle", "Not signed in", Ink.amber)
        }
    }

    private var helpText: String {
        var parts: [String] = [status.text]
        if let used = reading.used { parts.append("\(used)% used in the fullest measured lab") }
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
        }
    }
}

// MARK: - Depth 2: one row per lab

// The lab, its status ring, and what that status means for starting work:
// how much is left and until when, or why nothing is known. The mark arrives
// from the strip rather than fading in, so the row reads as the segment resolved.
private struct SlotRow: View {
    let profile: Profile
    let vendor: Vendor
    let data: PanelData
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var open: Bool { model.selection == Selection(profile: profile.name, vendor: vendor.id) }

    var body: some View {
        let (status, resets) = model.status(profile.name, vendor)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { toggle() } label: {
                    HStack(spacing: 10) {
                        LogoTile(vendor: vendor, status: status)
                            .frame(width: 28, height: 28)
                            .matchedGeometryEffect(id: SlotID.mono(profile.name, vendor.id), in: namespace)
                        Text(verbatim: vendor.label)
                            .font(.system(size: 14, weight: .medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        StatusRing(status: status)
                        HStack(spacing: 6) {
                            Text(verbatim: status.label)
                                .foregroundStyle(status.left != nil || status == .unmetered ? Ink.secondary : status.ink)
                            if let resets { Text(verbatim: SlotStatus.day(resets)).foregroundStyle(Ink.tertiary) }
                        }
                        .font(.system(size: 12.5)).monospacedDigit().lineLimit(1)
                        .frame(minWidth: 88, alignment: .leading)
                        .fixedSize()
                        if status != .checkFailed {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Ink.tertiary)
                                .rotationEffect(.degrees(open ? 90 : 0))
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle(radius: 8, resting: open ? 0.07 : 0))
                .accessibilityLabel("\(vendor.label), \(status.label)")
                if status == .checkFailed {
                    CheckAgainButton(checking: model.usageLoading) { actions.retryUsage() }
                        .padding(.trailing, 6)
                }
            }
            .frame(height: 44)
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
}

// A failed check's retry: a round yellow button beside the row, whose arrow
// turns until the check resolves.
private struct CheckAgainButton: View {
    let checking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.yellow)
                .turning(checking)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Ink.Tone.yellow.wash(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(checking)
        .help(String(localized: "Check again", comment: "Retry a failed usage check"))
        .accessibilityLabel(String(localized: "Check again", comment: "Retry a failed usage check"))
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
    @State private var copied: String?   // which row just copied
    @State private var showOwnership = false

    private var usage: Usage? { model.effectiveUsage(profile.name, vendor.id) }
    private var signedOut: Bool {
        data.snapshot.signedIn[profile.name]?[vendor.id] == false
            || usage?.note == .staleToken || usage?.note == .noToken
    }
    private var blocked: Bool { usage?.maxed ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.usage[vendor.id]?[profile.name]?.note == .sharedLogin {
                Text("Shared login · Default").font(.caption).foregroundStyle(Ink.secondary)
            }
            if let u = usage {
                UsageDetailsView(usage: u)
            }

            if let u = usage, u.showsHistory {
                Text(u.historyLabel).font(.caption).foregroundStyle(Ink.secondary)
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
            if vendor.id == "codex" {
                ActionRow(title: "Account ownership", icon: "person.crop.circle") { showOwnership.toggle() }
                if showOwnership { AccountOwnershipView(profile: profile.name) }
            }
            if !profile.isActive(for: vendor.id) {
                ActionRow(title: "Use for new sessions", icon: "checkmark.circle") {
                    actions.setActive(profile: profile.name, vendor: vendor.id)
                }
            }
            ActionRow(title: "Copy command", icon: "doc.on.doc",
                      trailing: copied == "command" ? "Copied" : "\(vendor.id)-\(profile.name.lowercased())", mono: true) {
                actions.copyCommand(profile: profile.name, vendor: vendor.id)
                flash("command")
            }
            if let dir = data.snapshot.slotDir(profile.name, vendor.id) {
                pathRow("Copy config folder", dir)
            }
            if !vendor.desktopName.isEmpty, let dir = data.snapshot.desktopDir(profile.name, vendor.id) {
                pathRow("Copy \(vendor.desktopName) data folder", dir)
            }
            if vendor.id == "codex" {
                ActionRow(title: "Sign in…", icon: "key") {
                    actions.signIn(profile: profile.name, vendor: vendor.id, confirm: true)
                }
            } else if let account = data.snapshot.account(profile.name, vendor.id) {
                ActionRow(title: account, icon: "person.crop.circle", trailing: "Sign in again…") {
                    actions.signIn(profile: profile.name, vendor: vendor.id, confirm: true)
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

    private func pathRow(_ title: String, _ path: String) -> some View {
        ActionRow(title: title, icon: "folder",
                  trailing: copied == path ? "Copied" : (path as NSString).abbreviatingWithTildeInPath, mono: true) {
            actions.copyPath(path)
            flash(path)
        }
    }

    private func flash(_ row: String) {
        copied = row
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == row { copied = nil } }
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
                        .truncationMode(.middle)
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

// Indeterminate progress: a 40%-wide highlight crossing its track every
// 1.4 s. Under Reduce Motion the track just sits at a static 30% tint.
private struct Sweep: View {
    var period: Double = 1.4
    var strength: Double = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowOnScreen) private var onScreen

    var body: some View {
        if reduceMotion {
            Rectangle().fill(Color.primary.opacity(0.3))
        } else {
            TimelineView(.animation(paused: !onScreen)) { context in
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

// One lab at depth 1: its logo, the value that says where it stands (what's
// left, the day it's back, or why nothing is known) and a bar of what's left.
// Unknown, failed and signed-out slots never show a percentage or a full bar.
private struct CapacitySegment: View {
    let profile: String
    let vendor: Vendor
    let status: SlotStatus
    let namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                LogoTile(vendor: vendor, status: status)
                    .frame(width: 22, height: 22)
                    .matchedGeometryEffect(id: SlotID.mono(profile, vendor.id), in: namespace)
                Text(verbatim: status.stripValue)
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(status.left != nil ? Color.primary.opacity(0.75) : status.ink)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            StatusBar(status: status)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(vendor.label), \(status.label)")
        .help("\(vendor.label) · \(status.label)")
    }
}

// Shared geometry ids, so a lab's mark travels between depth 1 and depth 2
// rather than one view dissolving into another.
private enum SlotID {
    static func mono(_ profile: String, _ vendor: String) -> String { "mono-\(profile)-\(vendor)" }
}

// Every lab the profile holds, in one row: 54 pt per segment, 8 apart, and
// tighter only when a profile holds more labs than the card's width fits.
private struct CapacityStrip: View {
    let profile: Profile
    let data: PanelData
    @ObservedObject var model: PanelModel
    let namespace: Namespace.ID

    var body: some View {
        let labs = data.slotted(profile)
        HStack(spacing: labs.count > 5 ? 4 : 8) {
            ForEach(labs, id: \.id) { v in
                CapacitySegment(profile: profile.name, vendor: v, status: model.status(profile.name, v).status,
                                namespace: namespace)
                    .frame(maxWidth: 54)
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
            ForEach(data.sessions.prefix(2)) { s in
                SessionRow(session: s, data: data, actions: actions)
            }
        }
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, 12)
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

    private static let age: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 1
        f.allowedUnits = [.minute, .hour, .day, .weekOfMonth]
        return f
    }()

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
                    Chip(text: session.profile, symbol: "person.crop.circle",
                         tint: profileColor(session.profile))
                    // The logo is the lab's name; spelling it out again was
                    // costing the title its width.
                    if let v = data.snapshot.vendor(session.vendor) {
                        Chip(vendor: v, tint: Ink.secondary)
                    }
                    Text(Self.age.string(from: session.mtime, to: Date()) ?? "")
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
        .buttonStyle(RowButtonStyle(radius: 7, resting: 0.05))
        .help("Resume in \(session.profile)")
        // Beside the row's button, not inside it: a control nested in a
        // button's label doesn't get its own clicks.
        .overlay(alignment: .topTrailing) {
            Button { popUp(menuItems) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle(radius: 4))
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
    @FocusState private var searching: Bool

    static let identifier = NSUserInterfaceItemIdentifier("sessions")
    private static let width: CGFloat = 560
    private static var listHeight: CGFloat {
        ((NSScreen.main?.visibleFrame.height ?? 800) - 44 - 48) * 0.72
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// Once per render: every part of the window reads the same filtered list.
    private func filtered() -> [SessionInfo] {
        let folded = SessionInfo.fold(trimmed)
        let tokens = folded.split(separator: " ")
        return tokens.isEmpty ? model.allSessions : model.allSessions.filter { $0.matches(tokens) }
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
                    .help("Clear")
                }
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
                Text(trimmed.isEmpty ? "\(rows.count)" : "\(rows.count) of \(model.allSessions.count)")
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
