import AppKit
import SwiftUI

// The panel's root page: every machine, every profile on it, and every lab in
// each profile with what's left — one glance, no scrolling sideways. A card
// opens its profile's page. Only this Mac's profiles are known to the panel
// today, so it draws one machine section (open question Q1).
struct FleetPage: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let data: PanelData

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(model: model, actions: actions, data: data)
            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.horizontal, 14)
            FittingScroll(maxHeight: PanelView.bodyLimit) {
                VStack(spacing: 0) {
                    if let fleetActions = actions as? FleetActions {
                        FleetBanners(model: model, actions: fleetActions)
                            .padding(.horizontal, 12).padding(.top, 10)
                    }
                    NextBestButton(pick: model.nextBest, model: model, data: data, actions: actions)
                        .padding(.horizontal, 12)
                        .padding(.top, 10).padding(.bottom, 2)
                    if data.profiles.count <= 1 {
                        FirstRun(actions: actions)
                    } else {
                        MachineHeader(model: model, actions: actions, profiles: data.profiles.count)
                            .padding(.top, 8)
                        VStack(spacing: 8) {
                            ForEach(data.profiles, id: \.name) { p in
                                ProfileCard(profile: p, data: data, model: model, actions: actions)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 2)
                        RecentSection(model: model, actions: actions)
                            .padding(.horizontal, 12).padding(.top, 10)
                    }
                    OtherMacsSection(model: model)
                        .padding(.horizontal, 12).padding(.top, 8)
                    if let fleetActions = actions as? FleetActions {
                        TasksSection(model: model, actions: fleetActions)
                            .padding(.horizontal, 12).padding(.top, 8)
                    }
                    Color.clear.frame(height: 10)
                }
            }
            FleetFooter(model: model, actions: actions)
        }
    }
}

// The app, then where new sessions go: the Active profile on a second line,
// a menu to change it for every lab or one lab. Trailing: the tally across
// this Mac's slots, and Settings.
private struct AppHeader: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let data: PanelData
    @State private var activeMenu = MenuAnchor()

    var body: some View {
        let tally = model.tally
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "N2 Agents").font(.system(size: 15, weight: .semibold)).tracking(-0.15)
                Button(action: popUpActive) {
                    HStack(spacing: 5) {
                        Text("Active", comment: "App header: the profile new sessions use").foregroundStyle(Ink.tertiary)
                        if let active = ActiveMenu.title(data.snapshot) {
                            Circle().fill(profileColor(active)).frame(width: 6, height: 6)
                            Text(verbatim: active).foregroundStyle(Ink.secondary)
                        } else {
                            Text("Mixed", comment: "App header: labs use different profiles").foregroundStyle(Ink.secondary)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.tertiary)
                    }
                    .font(.system(size: 12)).lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuAnchor(activeMenu)
                .help(String(localized: "Choose the profile new sessions use", comment: "App header: Active switch help"))
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                pair("checkmark", tally.ready, Ink.green,
                     String(localized: "\(tally.ready) ready", comment: "Fleet tally: slots that can start work"))
                if tally.out > 0 {
                    pair("hourglass", tally.out, Ink.amber,
                         String(localized: "\(tally.out) out of allowance", comment: "Fleet tally: slots that are out"))
                }
                if tally.attention > 0 {
                    pair("exclamationmark.triangle", tally.attention, Ink.yellow,
                         String(localized: "\(tally.attention) need attention", comment: "Fleet tally: failed checks and sign-outs"))
                }
            }
            IconButton(symbol: "gearshape", label: String(localized: "Settings", comment: "App header: open settings")) {
                actions.showSettings()
            }
            .contextMenu {
                if UpdateChannel.isQABuild {
                    Button("Play the Week (Debug)") { actions.playUsageWeek() }
                }
            }
            .padding(.leading, 6)
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(height: 56)
    }

    /// Per profile, then a submenu per lab; the native menu, under the switch.
    private func popUpActive() {
        let menu = ActiveMenu(snapshot: data.snapshot, profiles: data.profiles)
        var items: [NSMenuItem] = menu.profiles.map { c in
            ClosureItem(c.profile, symbol: "person.crop.circle", checked: c.checked) {
                actions.setActive(profile: c.profile, vendor: nil)
            }
        }
        if !menu.labs.isEmpty {
            items.append(.separator())
            items += menu.labs.map { lab in
                submenu(lab.label, symbol: "square.stack.3d.up", lab.choices.map { c in
                    ClosureItem(c.profile, checked: c.checked) { actions.setActive(profile: c.profile, vendor: lab.vendor) }
                })
            }
        }
        popUp(items, under: activeMenu)
    }

    private func pair(_ symbol: String, _ count: Int, _ ink: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
            Text(verbatim: count.formatted())
        }
        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
        .foregroundStyle(ink)
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

// Never disappears, never lies. Next best is any lab, in any profile — the
// same rotation `agents run` uses when you don't say. Dimmed with no pick
// while the pick hangs on a quota reading; the pick, named, once it's known;
// the soonest return when every signed-in slot is out, and clicking that one
// offers to open anyway.
private struct NextBestButton: View {
    let pick: NextBest?
    @ObservedObject var model: PanelModel
    let data: PanelData
    let actions: PanelActions
    @State private var anytimeMenu = MenuAnchor()

    var body: some View {
        switch pick {
        case .slot(let profile, let vendorID, _)?:
            Button { actions.openSession(profile: profile, vendor: vendorID, terminal: nil) } label: {
                shape(symbol: "bolt.fill", fill: Ink.chip) {
                    if let v = data.snapshot.vendor(vendorID) {
                        LabMark(vendor: v, size: 14).foregroundStyle(Ink.logo)
                    }
                    Text(verbatim: detail(profile, vendorID, lab: false))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Ink.secondary).lineLimit(1)
                }
            }
            .buttonStyle(PressableStyle(radius: 11, scale: 0.97))
            .accessibilityLabel(String(localized: "Open next best, \(detail(profile, vendorID))", comment: "Open next best: VoiceOver"))
            .help(String(localized: "The next signed-in slot with room, in rotation — no lab is favoured",
                         comment: "Open next best help"))
        case .allMaxed(let firstBack)?:
            Button {
                popUp(data.profiles.flatMap { p in
                    data.slotted(p).map { v in
                        ClosureItem(String(localized: "Open \(v.label) in “\(p.name)” anyway", comment: "Menu item when every lab is out"),
                                    symbol: "terminal") {
                            actions.openSession(profile: p.name, vendor: v.id, terminal: nil)
                        }
                    }
                }, under: anytimeMenu)
            } label: {
                shape(symbol: "hourglass", fill: Ink.amber, title: String(localized: "Everything is out", comment: "Open next best when every lab is out")) {
                    if let firstBack {
                        Text("first back \(clockTime(firstBack))", comment: "Open next best: soonest return")
                            .font(.system(size: 12)).foregroundStyle(Ink.amber).lineLimit(1)
                    }
                }
            }
            .buttonStyle(PressableStyle(radius: 11, scale: 0.97))
            .menuAnchor(anytimeMenu)
        case .usageUnavailable?:
            Button { actions.retryUsage() } label: {
                shape(symbol: "arrow.clockwise", fill: Ink.secondary, title: String(localized: "Usage unavailable", comment: "Open next best when nothing could be read")) {
                    Text("Refresh", comment: "Retry reading usage").font(.system(size: 12)).foregroundStyle(Ink.link)
                }
            }
            .buttonStyle(PressableStyle(radius: 11, scale: 0.97))
        case .nothingSignedIn?:
            shape(symbol: "bolt.slash.fill", fill: Ink.secondary, title: String(localized: "Nothing is signed in", comment: "Open next best with no login")) {
                EmptyView()
            }
        case nil:
            shape(symbol: "bolt.fill", fill: Ink.chip) { EmptyView() }.opacity(0.5)
        }
    }

    /// "Cursor · Default · 100%": the lab, where, and what's left when known.
    /// On screen the logo already names the lab; a lab name and a profile
    /// don't both fit beside the title.
    private func detail(_ profile: String, _ vendorID: String, lab: Bool = true) -> String {
        let label = data.snapshot.vendor(vendorID)?.label ?? vendorID
        let parts = (lab ? [label] : []) + [profile]
        guard let v = data.snapshot.vendor(vendorID), let left = model.status(profile, v).status.left else {
            return parts.joined(separator: " · ")
        }
        return (parts + [SlotStatus.percent(left)]).joined(separator: " · ")
    }

    private func shape<Trailing: View>(symbol: String, fill: Color,
                                       title: String = String(localized: "Open next best", comment: "Start work in the best slot"),
                                       @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(fill))
            Text(verbatim: title).font(.system(size: 13, weight: .semibold)).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 4)
            trailing()
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 11).fill(Ink.Tone.chip.wash(dark: 0.14, light: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Ink.Tone.chip.wash(dark: 0.45, light: 0.32), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

// This Mac: its sync word when it's in a fleet, its profile count, and `+`
// for a new profile or another Mac.
private struct MachineHeader: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let profiles: Int
    @State private var addMenu = MenuAnchor()

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "laptopcomputer").font(.system(size: 12))
            Text("This Machine", comment: "Root: the section for this Mac's profiles")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.primary.opacity(0.8))
            if let word = SyncWord(model.fleet) {
                Circle().fill(word.ink).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(verbatim: word.text)
            }
            Spacer(minLength: 6)
            Text("^[\(profiles) profile](inflect: true)", comment: "Machine section: its profile count").monospacedDigit()
            Button {
                popUp([ClosureItem(String(localized: "New Profile…", comment: "Add menu"), symbol: "person.badge.plus") { actions.newProfile() },
                       ClosureItem(String(localized: "Add a Mac…", comment: "Add menu: pair another Mac, in Settings"), symbol: "desktopcomputer") {
                           actions.showSettings()
                       }], under: addMenu)
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(radius: 6))
            .menuAnchor(addMenu)
            .help(String(localized: "New profile or another Mac", comment: "Machine header: add menu"))
            .accessibilityLabel(String(localized: "Add", comment: "Machine header: add menu"))
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Ink.secondary)
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(height: 30)
    }
}

/// This Mac's one word about sync, with its dot; nil outside a fleet or
/// before the sync state has been read.
struct SyncWord {
    let text: String
    let ink: Color

    init?(_ fleet: FleetData?) {
        guard let fleet, fleet.initialized, fleet.loaded.contains(.sync) else { return nil }
        let s = fleet.sync
        if fleet.unavailable.contains(.sync) {
            (text, ink) = (String(localized: "sync unknown", comment: "Sync word: the sync read failed"), Ink.secondary)
        } else if s.conflicts > 0 {
            (text, ink) = (inflected("^[\(s.conflicts) conflict](inflect: true)", comment: "Sync word: conflicts to answer"), Ink.amber)
        } else if s.resources == 0 {
            (text, ink) = (String(localized: "not sharing", comment: "Sync word: nothing shared yet"), Ink.secondary)
        } else if s.settled {
            (text, ink) = (String(localized: "in sync", comment: "Sync word: every shared item agrees"), Ink.green)
        } else {
            (text, ink) = (String(localized: "syncing", comment: "Sync word: shared items still settling"), Ink.secondary)
        }
    }
}

// One profile: whose it is, where it stands, and a strip with every lab's
// logo, value and bar. The whole card is one button to the profile's page.
private struct ProfileCard: View {
    let profile: Profile
    let data: PanelData
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    private var isActive: Bool { data.snapshot.active == profile.name }
    private var addable: Bool { data.snapshot.installedVendors.contains { profile.slots[$0.id] == nil } }

    var body: some View {
        let note = model.note(profile)
        Button { model.push(.profile(profile.name)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProfileDot(name: profile.name)
                    Text(verbatim: profile.name).font(.system(size: 14, weight: .semibold)).tracking(-0.14).lineLimit(1)
                    if isActive {
                        Text("Active", comment: "The profile new sessions use")
                            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Ink.secondary)
                            .padding(.horizontal, 6).frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Ink.Tone.neutral.wash(dark: 0.08, light: 0.06)))
                    }
                    Spacer(minLength: 6)
                    Text(verbatim: note.text).font(.system(size: 11.5)).foregroundStyle(note.ink).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.tertiary)
                }
                .frame(height: 20)
                CapacityStrip(profile: profile, data: data, model: model)
            }
            .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressableStyle(radius: 12, fill: Ink.surface, card: true))
        .accessibilityLabel(String(localized: "\(profile.name) profile, \(note.text)", comment: "Profile card"))
        // Every item names the profile: the menu opens at the pointer, which
        // may have left the card it came from by the time you read it.
        .contextMenu {
            if !isActive {
                Button { actions.setActive(profile: profile.name, vendor: nil) } label: {
                    Label("Make “\(profile.name)” Active for All Labs", systemImage: "checkmark.circle")
                }
            }
            if addable {
                Button { actions.addVendor(profile: profile.name) } label: {
                    Label("Add a Lab to “\(profile.name)”…", systemImage: "plus")
                }
            }
            if !profile.isDefault {
                Divider()
                Button(role: .destructive) { actions.deleteProfile(profile.name) } label: {
                    Label("Delete “\(profile.name)”…", systemImage: "trash")
                }
            }
        }
    }
}

/// A profile's colour: a 9 pt dot in a 3 pt halo of itself.
struct ProfileDot: View {
    let name: String

    var body: some View {
        Circle().fill(profileColor(name)).frame(width: 9, height: 9)
            .padding(3).background(Circle().fill(profileColor(name).opacity(0.2)))
            .padding(-3)
            .accessibilityHidden(true)
    }
}

// Every lab the profile holds, in one row: 54 pt per segment, 8 apart, and
// tighter only when a profile holds more labs than the card's width fits.
private struct CapacityStrip: View {
    let profile: Profile
    let data: PanelData
    @ObservedObject var model: PanelModel

    var body: some View {
        let labs = data.slotted(profile)
        HStack(spacing: labs.count > 5 ? 4 : 8) {
            ForEach(labs, id: \.id) { v in
                CapacitySegment(profile: profile.name, vendor: v, status: model.status(profile.name, v).status)
                    .frame(maxWidth: 54)
            }
            Spacer(minLength: 0)
        }
    }
}

// One lab at depth 1: its logo, the value that says where it stands (what's
// left, the day it's back, or why nothing is known) and a bar of what's left.
// Unknown, failed and signed-out slots never show a percentage or a full bar.
private struct CapacitySegment: View {
    let profile: String
    let vendor: Vendor
    let status: SlotStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                LogoTile(vendor: vendor, status: status)
                    .frame(width: 22, height: 22)
                    .glyph(.strip, profile: profile, vendor: vendor.id)
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

// Refresh and when it last read; the version and its channel, speaking up
// only for an update or a failed check; Report a bug and Quit.
private struct FleetFooter: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    private var version: String {
        let short = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0").prefix { $0 != "-" }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        HStack(spacing: 2) {
            icon("arrow.clockwise", String(localized: "Refresh", comment: "Footer: re-read usage"), turning: model.usageLoading) {
                actions.retryUsage()
            }
            // A fixed origin: a schedule started at .now restarts on every
            // re-render, and the label never moves while the panel is busy.
            TimelineView(.periodic(from: .distantPast, by: 15)) { context in
                if let at = model.refreshedAt {
                    Text(verbatim: updatedAgo(at, now: context.date))
                } else if model.usageLoading {
                    Text("Reading usage…", comment: "Footer: first usage read running")
                }
            }
            .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).lineLimit(1)
            Spacer(minLength: 6)
            Button { actions.checkForUpdates() } label: {
                HStack(spacing: 4) {
                    Text(verbatim: version).monospacedDigit()
                    if UpdateChannel.isQABuild {
                        Text("QA", comment: "Footer: a local QA build").fontWeight(.semibold)
                    } else {
                        Image(systemName: UpdateChannel.selected().symbol).fontWeight(.light)
                    }
                    status
                }
                .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                .padding(.horizontal, 4).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(radius: 7))
            .help(updateHelp)
            icon("ladybug", String(localized: "Report a bug", comment: "Footer: file an issue")) { actions.reportBug() }
            icon("power", String(localized: "Quit N2 Agents", comment: "Footer: quit the app")) { actions.quit() }
        }
        .padding(.leading, 8).padding(.trailing, 8)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1) }
    }

    /// Up to date says nothing; an update is a capsule, a failed check a warning.
    @ViewBuilder private var status: some View {
        switch model.updateStatus {
        case .available?:
            Text("Update Available", comment: "Footer: an update is ready to install")
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 7).frame(height: 18)
                .background(Capsule().fill(Ink.chip))
        case .failed?:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Ink.yellow)
        case .upToDate?, nil:
            EmptyView()
        }
    }

    private var updateHelp: String {
        if UpdateChannel.isQABuild { return String(localized: "Local QA build — never updates itself", comment: "Footer version help") }
        switch model.updateStatus {
        case .available?: return String(localized: "Update available — click to install", comment: "Footer version help")
        case .failed(let reason)?: return String(localized: "Update check failed: \(reason) Click to retry.", comment: "Footer version help")
        case .upToDate?, nil: return String(localized: "Check for updates", comment: "Footer version help")
        }
    }

    private func icon(_ symbol: String, _ label: String, turning: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .turning(turning)
                .foregroundStyle(Ink.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(radius: 7))
        .help(label)
        .accessibilityLabel(label)
    }
}
