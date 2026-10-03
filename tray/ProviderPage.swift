import AppKit
import SwiftUI

// One lab in one profile: where it stands, told once in the hero, then the
// one action that fits that state, the lesser ones as tiles, and the raw
// readings folded away under Diagnostics.
struct ProviderPage: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let data: PanelData
    let profile: Profile
    let vendor: Vendor

    private var usage: Usage? { model.effectiveUsage(profile.name, vendor.id) }
    private var monthly: Bool { vendor.longWindow == "mo" }
    private var suggestion: Suggestion? { model.suggestion(for: profile.name, vendor) }

    var body: some View {
        let (status, resets) = model.status(profile.name, vendor)
        VStack(spacing: 0) {
            NavBar(title: vendor.label, back: { model.pop() }) {
                Text(verbatim: profile.name).font(.system(size: 13)).foregroundStyle(Ink.link).lineLimit(1)
            } trailing: {
                IconButton(symbol: "slider.horizontal.3",
                           label: String(localized: "Configure", comment: "Provider page: open its configuration")) {
                    model.push(.configure(profile: profile.name, vendor: vendor.id))
                }
            }
            FittingScroll(maxHeight: PanelView.bodyLimit) {
                VStack(spacing: 0) {
                    ProviderHero(model: model, actions: actions, vendor: vendor, profile: profile.name,
                                 status: status, resets: resets, usage: usage, monthly: monthly)
                        .padding(.top, 12)
                    if let suggestion {
                        SuggestionCard(suggestion: suggestion, data: data) { model.switchTo(suggestion) }
                            .padding(.horizontal, 16).padding(.top, 16)
                            .staggered(4)
                    }
                    PrimaryAction(status: status, terminals: data.terminals, actions: actions,
                                  profile: profile.name, vendor: vendor, suggested: suggestion != nil)
                        .padding(.horizontal, 16).padding(.top, 14)
                        .staggered(5)
                    ActionTiles(data: data, profile: profile, vendor: vendor, actions: actions)
                        .padding(.horizontal, 16).padding(.top, 8)
                        .staggered(6)
                    RecentSection(model: model, actions: actions, profile: profile.name, vendor: vendor.id, limit: 3)
                        .padding(.horizontal, 16).padding(.top, 14)
                        .staggered(7)
                    DetailList(model: model, actions: actions, profile: profile.name, vendor: vendor, usage: usage)
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
                        .staggered(7)
                }
                // A new subject (Switch) is a new page's worth of content: it restaggers.
                .id("\(profile.name)/\(vendor.id)")
                .transition(.identity)
            }
        }
    }
}

private struct ProviderHero: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let vendor: Vendor
    let profile: String
    let status: SlotStatus
    let resets: Date?
    let usage: Usage?
    let monthly: Bool
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                StatusRing(status: status, diameter: 112, stroke: 8, glyph: false, drawn: drawn)
                LogoTile(vendor: vendor, status: status)
                    .frame(width: 48, height: 48)
                    .overlay(alignment: .bottomTrailing) { badge.offset(x: 8, y: 8) }
                    .glyph(.hero, profile: profile, vendor: vendor.id)
            }
            .frame(width: 112, height: 112)
            .onAppear {
                // The ring draws in once the glyph has landed; the number beside it doesn't count.
                if reduceMotion { drawn = 1 } else { withAnimation(Motion.reveal) { drawn = 1 } }
            }
            Text(verbatim: status.headline(monthly: monthly))
                .font(.system(size: 17, weight: .semibold)).tracking(-0.25)
                .opacity(status == .checking ? 0.6 : 1)
                .padding(.top, 14)
                .staggered(0)
            if let sub = status.sub(provider: vendor.label, resets: resets, monthly: monthly) {
                Text(verbatim: sub)
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28).padding(.top, 3)
                    .staggered(1)
            }
            capsule.staggered(2)
            HStack(spacing: 6) {
                ForEach(status.chips(usage, monthly: monthly), id: \.text) { chip in
                    HStack(spacing: 5) {
                        Image(systemName: chip.symbol).font(.system(size: 10.5, weight: .semibold))
                        Text(verbatim: chip.text)
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Ink.chipFill))
                }
            }
            .padding(.top, 12).padding(.horizontal, 16)
            .staggered(3)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var badge: some View {
        if let symbol = status.badge {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Ink.badgeGlyph)
                .frame(width: 20, height: 20)
                .background(Circle().fill(status.ink))
                .overlay(Circle().strokeBorder(Ink.page, lineWidth: 3).padding(-3))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var capsule: some View {
        switch status {
        case .out(let back?):
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let left = Duration.seconds(max(0, back.timeIntervalSince(context.date)))
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 11, weight: .semibold))
                    Text("in \(left.formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)))",
                         comment: "Provider hero: time until allowance returns")
                }
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Ink.amber)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(Ink.Tone.amber.wash(0.14)))
            }
            .padding(.top, 10)
        case .checkFailed:
            Button { actions.retryUsage() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold)).turning(model.usageLoading)
                    Text(model.usageLoading ? String(localized: "Checking…", comment: "A usage check is running")
                                            : String(localized: "Check again", comment: "Retry a failed usage check"))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.yellow)
                .padding(.horizontal, 12).frame(height: 26)
                .background(Capsule().fill(Ink.Tone.yellow.wash(0.14)))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle(radius: 13, scale: 0.97))
            .disabled(model.usageLoading)
            .padding(.top, 10)
        default:
            EmptyView()
        }
    }
}

// "Cursor has room": a lab with a fresh, ready reading, offered in place of
// one that's out or low. Switch goes to its page; Start there opens it.
private struct SuggestionCard: View {
    let suggestion: Suggestion
    let data: PanelData
    let switchTo: () -> Void

    var body: some View {
        let label = data.snapshot.vendor(suggestion.vendor)?.label ?? suggestion.vendor
        HStack(spacing: 10) {
            if let v = data.snapshot.vendor(suggestion.vendor) {
                LogoTile(vendor: v)
                    .frame(width: 28, height: 28)
                    .glyph(.suggestion, profile: suggestion.profile, vendor: v.id)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: suggestion.sameProfile
                     ? String(localized: "\(label) has room", comment: "Suggestion: a lab in this profile with allowance left")
                     : String(localized: "\(label) in \(suggestion.profile) has room", comment: "Suggestion: a lab in another profile with allowance left"))
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(verbatim: sub).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(action: switchTo) {
                Text("Switch", comment: "Suggestion: go to the suggested lab")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(Ink.chip))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle(radius: 14, scale: 0.97))
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.Tone.chip.wash(dark: 0.12, light: 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.Tone.chip.wash(dark: 0.4, light: 0.3), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    private var sub: String {
        let left = SlotStatus.percent(suggestion.left)
        guard let resets = suggestion.resets else {
            return String(localized: "\(left) left", comment: "Suggestion: allowance left, reset unknown")
        }
        return String(localized: "\(left) left · resets \(SlotStatus.day(resets))", comment: "Suggestion: allowance left and reset day")
    }
}

// The one action that fits the state, and the terminal it opens in. Filled
// when it's the thing to do; bordered when out, where starting anyway is the
// lesser choice beside a suggestion.
struct PrimaryAction: View {
    let status: SlotStatus
    let terminals: [String]
    let actions: PanelActions
    let profile: String
    let vendor: Vendor
    /// A lab with room was suggested, so starting here anyway steps down.
    var suggested = false

    private var terminal: String { terminals.first ?? "Terminal" }
    private var prominent: Bool {
        if case .out = status { return !suggested }
        return true
    }

    var body: some View {
        let ink: Color = prominent ? .white : .primary
        HStack(spacing: 0) {
            Button(action: primary) {
                HStack(spacing: 8) {
                    Image(systemName: status == .signedOut ? "key" : "apple.terminal")
                        .font(.system(size: 14, weight: .medium))
                    Text(verbatim: title).font(.system(size: 13.5, weight: .semibold))
                    if status != .signedOut {
                        Text("in \(terminal)", comment: "Primary action: the terminal it opens in")
                            .font(.system(size: 13.5, weight: .medium)).opacity(0.6)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(radius: 9, scale: 0.97))
            if status != .signedOut {
                Rectangle().fill(ink.opacity(0.22)).frame(width: 1).padding(.vertical, 9)
                Button(action: chooseTerminal) {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(radius: 9, scale: 0.97))
                .help(String(localized: "Choose terminal", comment: "Primary action: terminal menu"))
                .accessibilityLabel(String(localized: "Choose terminal", comment: "Primary action: terminal menu"))
            }
        }
        .foregroundStyle(ink)
        .background(RoundedRectangle(cornerRadius: 9).fill(prominent ? Ink.chip : Ink.raised))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(prominent ? .clear : Ink.raisedEdge, lineWidth: 1))
    }

    private var title: String {
        switch status {
        case .signedOut: return String(localized: "Sign in…", comment: "Primary action: sign in to this lab")
        case .out: return String(localized: "Start anyway", comment: "Primary action: start though out of allowance")
        default: return String(localized: "Start session", comment: "Primary action: open a session")
        }
    }

    private func primary() {
        if status == .signedOut {
            actions.signIn(profile: profile, vendor: vendor.id, confirm: false)
        } else {
            actions.openSession(profile: profile, vendor: vendor.id, terminal: nil)
        }
    }

    /// The system's own menu: "Open in", then every installed terminal with
    /// the current one checked. A pick becomes the preferred terminal.
    private func chooseTerminal() {
        let header = NSMenuItem(title: String(localized: "Open in", comment: "Terminal menu header"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        popUp([header] + terminals.map { name in
            ClosureItem(name, checked: name == terminal) { actions.setPreferredTerminal(name) }
        })
    }
}

private struct ActionTiles: View {
    let data: PanelData
    let profile: Profile
    let vendor: Vendor
    let actions: PanelActions

    private var sessions: [SessionInfo] {
        data.sessions.filter { $0.profile == profile.name && $0.vendor == vendor.id }
    }

    var body: some View {
        HStack(spacing: 8) {
            if data.hasDesktop(vendor, for: profile) {
                tile("macwindow", String(localized: "Open app", comment: "Provider tile: open the desktop app")) {
                    actions.openDesktop(profile: profile.name, vendor: vendor.id)
                }
            }
            tile("arrow.left.arrow.right", String(localized: "Switch account", comment: "Provider tile: sign in as another account")) {
                actions.signIn(profile: profile.name, vendor: vendor.id, confirm: true)
            }
            tile("arrow.right.doc.on.clipboard", String(localized: "Move session", comment: "Provider tile: move or send a recent session")) {
                popUp(moveItems)
            }
        }
    }

    /// Recent sessions in this slot, each offering the profiles it can move
    /// to and, for Codex, another machine.
    private var moveItems: [NSMenuItem] {
        let recent = sessions.prefix(8)
        guard !recent.isEmpty else {
            let none = NSMenuItem(title: String(localized: "No recent \(vendor.label) sessions in \(profile.name)",
                                                comment: "Move session menu, empty"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            return [none]
        }
        let destinations = data.profiles.filter { $0.name != profile.name && $0.slots[vendor.id] != nil }.map(\.name)
        return recent.map { s in
            var items: [NSMenuItem] = destinations.map { p in
                ClosureItem(p, symbol: "person.crop.circle") { actions.moveSession(s, to: p) }
            }
            if s.vendor == "codex" {
                items.append(ClosureItem(String(localized: "Send to Machine…", comment: "Move session menu"), symbol: "laptopcomputer") {
                    actions.sendSession(s)
                })
            }
            if items.isEmpty {
                let none = NSMenuItem(title: String(localized: "No other profile has \(vendor.label)", comment: "Move session menu"),
                                      action: nil, keyEquivalent: "")
                none.isEnabled = false
                items = [none]
            }
            return submenu(s.title ?? s.snippet, symbol: "text.bubble", items)
        }
    }

    private func tile(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Symbols differ in height; a fixed box keeps the labels on one line.
                Image(systemName: symbol).font(.system(size: 17)).frame(height: 20)
                Text(verbatim: label).font(.system(size: 11.5)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(.primary.opacity(0.8))
            .frame(maxWidth: .infinity).frame(height: 58)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressableStyle(radius: 10, fill: Ink.raised, card: true, scale: 0.96))
    }
}

// Configure, and the raw readings behind the hero, folded until asked for.
private struct DetailList: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    let profile: String
    let vendor: Vendor
    let usage: Usage?
    @State private var open = false
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            row("slider.horizontal.3", String(localized: "Configure", comment: "Provider page row")) {
                Text(verbatim: Clipboard.command(profile: profile, vendor: vendor.id))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.tertiary).lineLimit(1)
                chevron(0)
            } action: {
                model.push(.configure(profile: profile, vendor: vendor.id))
            }
            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 38)
            row("info.circle", String(localized: "Diagnostics", comment: "Provider page row")) {
                if let u = usage, u.hasObservationTime {
                    Text("checked \(clockTime(u.fetchedAt))", comment: "Diagnostics row: when usage was read")
                        .font(.system(size: 12)).foregroundStyle(Ink.tertiary).lineLimit(1)
                }
                chevron(open ? 90 : 0)
            } action: {
                withAnimation(Motion.nav(reduce: reduceMotion)) { open.toggle() }
            }
            .accessibilityValue(open ? String(localized: "Expanded", comment: "Disclosure state")
                                     : String(localized: "Collapsed", comment: "Disclosure state"))
            if open {
                disclosure
                    .transition(.opacity.animation(reduceMotion ? Motion.fade : .easeOut(duration: 0.3)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.cardEdge, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var facts: [(key: String, value: String)] { Diagnostics.facts(usage, shared: model.usage[vendor.id]?[profile]?.note == .sharedLogin) }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(facts, id: \.key) { fact in
                HStack(spacing: 12) {
                    Text(verbatim: fact.key).foregroundStyle(Ink.tertiary)
                    Spacer(minLength: 8)
                    Text(verbatim: fact.value).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.75)).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(.system(size: 11.5))
                .frame(height: 22)
            }
            HStack(spacing: 8) {
                Button {
                    actions.copyPath(facts.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                    copied = true
                    Clipboard.announceCopied()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    small(copied ? "checkmark" : "doc.on.doc", String(localized: "Copy report", comment: "Diagnostics: copy these facts"),
                          tint: copied ? Ink.green : nil)
                }
                .buttonStyle(PressableStyle(radius: 7, fill: Ink.chipFill, scale: 0.97))
                Button { actions.retryUsage() } label: {
                    small("arrow.clockwise", String(localized: "Check now", comment: "Diagnostics: read usage again"), turning: model.usageLoading)
                }
                .buttonStyle(PressableStyle(radius: 7, fill: Ink.chipFill, scale: 0.97))
                .disabled(model.usageLoading)
            }
            .padding(.top, 10)
        }
        .padding(.leading, 38).padding(.trailing, 12).padding(.top, 2).padding(.bottom, 12)
    }

    private func small(_ symbol: String, _ label: String, tint: Color? = nil, turning: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? .primary)
                .replacingSymbol()
                .turning(turning)
            Text(verbatim: label)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).frame(height: 26)
    }

    private func chevron(_ degrees: Double) -> some View {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Ink.tertiary).rotationEffect(.degrees(degrees))
    }

    private func row<Trailing: View>(_ symbol: String, _ title: String, @ViewBuilder trailing: () -> Trailing,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Ink.secondary).frame(width: 16)
                Text(verbatim: title).font(.system(size: 13))
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 12).frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(radius: 0))
    }
}

/// A 28 pt icon-only button: labelled for VoiceOver, named on hover.
struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Ink.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(radius: 7))
        .help(label)
        .accessibilityLabel(label)
    }
}
