import AppKit
import SwiftUI

// The menu bar panel: a stack of pages, Fleet → Profile → Provider →
// Configure, each answering one question. Every value on screen comes from
// PanelModel, never from the view reaching into the system; every action
// goes back through PanelActions.

enum Metrics {
    static let width: CGFloat = 360
    static let side: CGFloat = 13
    static let cardRadius: CGFloat = 9
}

func profileColor(_ name: String) -> Color { Color(nsColor: ProfileColor.of(name)) }

/// "3:20 PM" today, "Fri 3:20 PM" further out — a weekly window resets days away.
// A weekday names a day only within the week: a monthly reset gets its date.
func clockTime(_ date: Date) -> String {
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

    /// The screen's height less the menu bar gap, a page's bars and a margin.
    static var bodyLimit: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 52 - 40 - 48
    }

    var body: some View {
        Group {
            if let data = model.data {
                PageStack(model: model) { route in page(route, data) }
            } else {
                ColdStart().background(Ink.page)
            }
        }
        .frame(width: Metrics.width)
        // Every open: the content rises 4 pt and fades in — one move for the
        // whole panel, not a cascade of elements.
        .opacity(model.presented ? 1 : 0)
        .offset(y: model.presented || reduceMotion ? 0 : 4)
        .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.16), value: model.presented)
    }

    @ViewBuilder private func page(_ route: PanelRoute?, _ data: PanelData) -> some View {
        switch route {
        case nil:
            FleetPage(model: model, actions: actions, data: data)
        case .profile(let name)?:
            if let profile = data.profiles.first(where: { $0.name == name }) {
                ProfilePage(model: model, actions: actions, data: data, profile: profile)
            }
        case .provider?, .configure?:
            EmptyView()
        }
    }
}

// Content at its own height, scrolling only past a limit. A bare ScrollView
// takes all the height it's offered and measures nothing on its first pass,
// which would pin the panel at its maximum or collapse a page as it's pushed;
// this draws the content plainly and wraps it in a scroll view only once it
// has measured taller than the limit.
struct FittingScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let measured = content.background(GeometryReader { g in
            Color.clear.preference(key: ContentHeight.self, value: g.size.height)
        })
        Group {
            if contentHeight > maxHeight {
                ScrollView(.vertical) { measured }.frame(height: maxHeight)
            } else {
                measured
            }
        }
        .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
    }
}

private struct ContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Depth 3: everything for one slot

// Both windows in full, then the actions in one order that never varies:
// Start, then Fix when something is actually broken, then Configure. The
// primary action is the only filled control.
struct SlotActions: View {
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
        .buttonStyle(PressableStyle(radius: 5))
    }
}

// Indeterminate progress: a 40%-wide highlight crossing its track every
// 1.4 s. Under Reduce Motion the track just sits at a static 30% tint.
struct Sweep: View {
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
struct Pulse: View {
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

// Cold start only: the first launch before any snapshot was saved. Fleet's
// shape with two placeholder cards — never a profile count guessed from nothing.
struct ColdStart: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Fleet", comment: "Panel title").font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 16).frame(height: 52)
            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<2, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Pulse(width: 9, height: 9)
                            Pulse(width: 72, height: 10)
                        }
                        HStack(spacing: 8) {
                            ForEach(0..<3, id: \.self) { _ in
                                Sweep(period: 1.6, strength: 0.07).frame(width: 54, height: 3).clipShape(Capsule())
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Ink.surface))
                }
                Text("Reading profiles…", comment: "Cold start: first read running")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).padding(.leading, 4)
            }
            .padding(12)
        }
    }
}

struct InlineStatus: View {
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


// MARK: - First run

struct FirstRun: View {
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
struct PillButtonStyle: ButtonStyle {
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

// Every row, card, tile and icon button: a fill under the pointer, a darker
// one and a slight shrink while pressed. The action commits on release, so
// dragging off cancels it.
struct PressableStyle: ButtonStyle {
    let radius: CGFloat
    /// The fill at rest: clear for a row, the surface for a card.
    var fill: Color = .clear
    /// A card: its edge, soft shadow, and a hairline stroke under the pointer.
    var card = false
    var scale: CGFloat = 0.985

    func makeBody(configuration: Configuration) -> some View {
        Pressable(style: self, pressed: configuration.isPressed) { configuration.label }
    }
}

private struct Pressable<Content: View>: View {
    let style: PressableStyle
    let pressed: Bool
    @ViewBuilder let content: Content
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radius)
        content
            .background(shape.fill(pressed ? Ink.pressed : hovering ? Ink.hover : .clear))
            .background(shape.fill(style.fill).shadow(color: style.card ? Ink.cardShadow : .clear, radius: 1, y: 1))
            .overlay(shape.strokeBorder(style.card ? (hovering ? Ink.hairline : Ink.cardEdge) : .clear, lineWidth: 0.5))
            .scaleEffect(pressed && !reduceMotion ? style.scale : 1)
            .animation(Motion.press, value: pressed)
            .animation(Motion.hover, value: hovering)
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

func submenu(_ title: String, symbol: String? = nil, _ items: [NSMenuItem]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    let menu = NSMenu()
    items.forEach(menu.addItem)
    item.submenu = menu
    return item
}

func popUp(_ items: [NSMenuItem]) {
    let menu = NSMenu()
    items.forEach(menu.addItem)
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
}
