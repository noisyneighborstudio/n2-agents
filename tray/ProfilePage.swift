import SwiftUI

// A profile's page: one row per lab, each with its status ring and what that
// status means for starting work. A row opens that lab.
struct ProfilePage: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let data: PanelData
    let profile: Profile
    @FocusState private var focusedRow: String?

    private var addable: Bool { data.snapshot.installedVendors.contains { profile.slots[$0.id] == nil } }

    var body: some View {
        let note = model.note(profile)
        VStack(spacing: 0) {
            NavBar(height: 52, back: { model.pop() }) {
                HStack(spacing: 7) {
                    Circle().fill(profileColor(profile.name)).frame(width: 9, height: 9).padding(.leading, 5)
                    Text(verbatim: profile.name).font(.system(size: 15, weight: .semibold)).tracking(-0.15)
                        .foregroundStyle(.primary).lineLimit(1)
                }
            } trailing: {
                Text(verbatim: note.text).font(.system(size: 12)).foregroundStyle(note.ink).lineLimit(1)
                    .padding(.trailing, 6)
            }
            .accessibilityLabel(String(localized: "Back to Fleet", comment: "Profile page back button"))
            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.horizontal, 14)
            FittingScroll(maxHeight: PanelView.bodyLimit) {
                VStack(spacing: 0) {
                    if let labs = model.pendingSetups[profile.name], !labs.isEmpty {
                        let names = labs.compactMap { data.snapshot.vendor($0)?.label }
                        InlineStatus(text: "\(names.joined(separator: ", ")) never finished signing in",
                                     button: "Finish setup", symbol: "key") { actions.finishSetup(profile: profile.name) }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    ForEach(data.slotted(profile), id: \.id) { v in
                        SlotRow(profile: profile, vendor: v, data: data, model: model, actions: actions,
                                focus: $focusedRow)
                    }
                    if addable {
                        Button { actions.addVendor(profile: profile.name) } label: {
                            Label("Add a lab…", systemImage: "plus")
                                .font(.system(size: 12))
                                .foregroundStyle(Ink.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle(radius: 8))
                    }
                    RecentSection(model: model, actions: actions, profile: profile.name, limit: 3)
                        .padding(.horizontal, 4).padding(.top, 8)
                }
                .padding(.horizontal, 8).padding(.top, 5).padding(.bottom, 7)
                .arrowFocus(data.slotted(profile).map(\.id), $focusedRow)
            }
        }
    }
}

// The lab, its status ring, and what that status means for starting work:
// how much is left and until when, or why nothing is known. The mark arrives
// from the strip rather than fading in, so the row reads as the segment resolved.
private struct SlotRow: View {
    let profile: Profile
    let vendor: Vendor
    let data: PanelData
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    var focus: FocusState<String?>.Binding

    var body: some View {
        let (status, resets) = model.status(profile.name, vendor)
        HStack(spacing: 4) {
            Button { model.push(.provider(profile: profile.name, vendor: vendor.id)) } label: {
                HStack(spacing: 10) {
                    LogoTile(vendor: vendor, status: status)
                        .frame(width: 28, height: 28)
                        .glyph(.row, profile: profile.name, vendor: vendor.id)
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
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(radius: 8))
            .opens { model.push(.provider(profile: profile.name, vendor: vendor.id)) }
            .focused(focus, equals: vendor.id)
            .accessibilityLabel("\(vendor.label), \(status.label)")
            if status == .checkFailed {
                CheckAgainButton(checking: model.usageLoading) { actions.retryUsage() }
                    .padding(.trailing, 6)
            }
        }
        .frame(height: 44)
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
