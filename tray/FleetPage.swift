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
            FleetHeader(model: model, data: data)
            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.horizontal, 14)
            FittingScroll(maxHeight: PanelView.bodyLimit) {
                VStack(spacing: 0) {
                    NextBestButton(pick: model.nextBest, model: model, data: data, actions: actions)
                        .padding(.horizontal, 12)
                        .padding(.top, 10).padding(.bottom, 2)
                    if data.profiles.count <= 1 {
                        FirstRun(actions: actions)
                    } else {
                        MachineHeader(profiles: data.profiles.count)
                            .padding(.top, 8)
                        VStack(spacing: 8) {
                            ForEach(data.profiles, id: \.name) { p in
                                ProfileCard(profile: p, data: data, model: model, actions: actions)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 2)
                    }
                    // Peers, sync and tasks: the rest of the fleet, below this Mac.
                    if let fleetActions = actions as? FleetActions {
                        Rectangle().fill(Ink.hairline).frame(height: 1).padding(.horizontal, 14).padding(.top, 12)
                        FleetSection(model: model, actions: fleetActions)
                    }
                    Color.clear.frame(height: 10)
                }
            }
            FleetFooter(model: model, actions: actions)
        }
    }
}

private struct FleetHeader: View {
    @ObservedObject var model: PanelModel
    let data: PanelData

    var body: some View {
        let tally = model.tally
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Fleet", comment: "Panel title").font(.system(size: 15, weight: .semibold)).tracking(-0.15)
                Text("^[\(1) machine](inflect: true) · ^[\(data.profiles.count) profile](inflect: true)",
                     comment: "Fleet header: machine and profile counts")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Ink.tertiary)
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
        }
        .padding(.leading, 16).padding(.trailing, 14)
        .frame(height: 52)
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

    var body: some View {
        switch pick {
        case .slot(let profile, let vendorID, _)?:
            Button { actions.openSession(profile: profile, vendor: vendorID, terminal: nil) } label: {
                shape(symbol: "bolt.fill", fill: Ink.chip) {
                    if let v = data.snapshot.vendor(vendorID) {
                        LabMark(vendor: v, size: 14).foregroundStyle(Ink.logo)
                    }
                    Text(verbatim: detail(profile, vendorID))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Ink.secondary).lineLimit(1)
                }
            }
            .buttonStyle(PressableStyle(radius: 11, scale: 0.97))
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
                })
            } label: {
                shape(symbol: "hourglass", fill: Ink.amber, title: String(localized: "Everything is out", comment: "Open next best when every lab is out")) {
                    if let firstBack {
                        Text("first back \(clockTime(firstBack))", comment: "Open next best: soonest return")
                            .font(.system(size: 12)).foregroundStyle(Ink.amber).lineLimit(1)
                    }
                }
            }
            .buttonStyle(PressableStyle(radius: 11, scale: 0.97))
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
    private func detail(_ profile: String, _ vendorID: String) -> String {
        let label = data.snapshot.vendor(vendorID)?.label ?? vendorID
        guard let v = data.snapshot.vendor(vendorID), let left = model.status(profile, v).status.left else {
            return "\(label) · \(profile)"
        }
        return "\(label) · \(profile) · \(SlotStatus.percent(left))"
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

private struct MachineHeader: View {
    let profiles: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "laptopcomputer").font(.system(size: 12))
            Text("This Machine", comment: "Fleet page: the section for this Mac's profiles")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.primary.opacity(0.8))
            Circle().fill(Ink.green).frame(width: 6, height: 6).accessibilityHidden(true)
            Text("online", comment: "Machine status")
            Spacer(minLength: 6)
            Text("^[\(profiles) profile](inflect: true)", comment: "Machine section: its profile count").monospacedDigit()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, 16)
        .frame(height: 30)
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
        .contextMenu {
            if !isActive {
                Button { actions.setActive(profile: profile.name, vendor: nil) } label: {
                    Label("Make Active for All Labs", systemImage: "checkmark.circle")
                }
            }
            if addable {
                Button { actions.addVendor(profile: profile.name) } label: { Label("Add Lab…", systemImage: "plus") }
            }
            if !profile.isDefault {
                Divider()
                Button(role: .destructive) { actions.deleteProfile(profile.name) } label: {
                    Label("Delete Profile…", systemImage: "trash")
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

private struct FleetFooter: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 2) {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if let at = model.refreshedAt {
                    Text("Updated \(at, format: .relative(presentation: .numeric, unitsStyle: .wide))",
                         comment: "Footer: when usage was last read")
                } else if model.usageLoading {
                    Text("Reading usage…", comment: "Footer: first usage read running")
                }
            }
            .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).lineLimit(1)
            Spacer(minLength: 6)
            icon("arrow.clockwise", String(localized: "Refresh", comment: "Footer: re-read usage"), turning: model.usageLoading) {
                actions.retryUsage()
            }
            icon("clock.arrow.circlepath", String(localized: "Recent sessions", comment: "Footer: open the sessions window")) {
                actions.showAllSessions()
            }
            icon("plus", String(localized: "New profile", comment: "Footer: create a profile")) { actions.newProfile() }
            icon("slider.horizontal.3", model.updateStatus == .available
                 ? String(localized: "Settings · update available", comment: "Footer: settings, with an update waiting")
                 : String(localized: "Settings", comment: "Footer: open settings")) { actions.showSettings() }
                .overlay(alignment: .topTrailing) {
                    // An update waiting: a dot on Settings, where it installs.
                    if model.updateStatus == .available {
                        Circle().fill(Ink.link).frame(width: 6, height: 6).offset(x: -5, y: 5)
                    }
                }
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1) }
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
