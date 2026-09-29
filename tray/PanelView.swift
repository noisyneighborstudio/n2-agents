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
        case .provider(let name, let id)?:
            if let profile = data.profiles.first(where: { $0.name == name }), let vendor = data.snapshot.vendor(id) {
                ProviderPage(model: model, actions: actions, data: data, profile: profile, vendor: vendor)
            }
        case .sendSession(let id)?:
            if let session = model.session(id) {
                SendSessionPage(model: model, actions: actions, session: session)
            }
        case .machine(let id)?:
            if let fleetActions = actions as? FleetActions, let peer = model.fleet?.peers.first(where: { $0.id == id }) {
                MachinePage(model: model, actions: fleetActions, peer: peer)
            }
        case .task(let id)?:
            if let fleetActions = actions as? FleetActions, let task = model.fleet?.tasks.first(where: { $0.id == id }) {
                TaskPage(model: model, actions: fleetActions, task: task)
            }
        case .sendWork?:
            if let fleetActions = actions as? FleetActions { SendWorkPage(model: model, actions: fleetActions) }
        case .conflicts?:
            if let fleetActions = actions as? FleetActions { ConflictsPage(model: model, actions: fleetActions) }
        case .configure(let name, let id)?:
            if let profile = data.profiles.first(where: { $0.name == name }), let vendor = data.snapshot.vendor(id) {
                ConfigurePage(model: model, actions: actions, data: data, profile: profile, vendor: vendor)
            }
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
                // No scroller gutter: legacy scrollers would narrow every card.
                ScrollView(.vertical) { measured }.frame(height: maxHeight).scrollIndicators(.never)
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
