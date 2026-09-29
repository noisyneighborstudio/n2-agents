import AppKit
import SwiftUI

// The panel is a stack of pages: Fleet at the bottom, then a profile, one of
// its labs, and that lab's configuration. Only the top two are drawn. A push
// slides the new page in from the trailing edge over the old one, which
// drifts 30% left and fades; a pop runs the same move backwards. Pages are
// opaque, so the incoming one covers the outgoing one rather than mixing with
// it. Under Reduce Motion both are a 0.2 s crossfade.
//
// A lab's logo tile flies between pages instead of dissolving: each tile
// reports its frame here, and while a flight runs a copy of the tile travels
// above both pages and the real ones wait, hidden, until it lands.

extension PanelModel {
    func push(_ route: PanelRoute) {
        withAnimation(Motion.nav(reduce: Self.reduceMotion)) { path.append(route) }
    }

    func pop() {
        guard !path.isEmpty else { return }
        withAnimation(Motion.nav(reduce: Self.reduceMotion)) { _ = path.removeLast() }
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Where a lab's tile sits on each page it appears on.
enum GlyphRole: String {
    case strip, row, hero
}

private struct TileFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension EnvironmentValues {
    /// The tiles ("profile/vendor") in flight: their real copies stay hidden.
    @Entry var flyingGlyphs: Set<String> = []
}

private let stackSpace = "page-stack"

private func glyphKey(_ profile: String, _ vendor: String) -> String { "\(profile)/\(vendor)" }

extension View {
    /// A lab's tile that flies between pages: reports where it is, and hides
    /// while its copy is in the air.
    func glyph(_ role: GlyphRole, profile: String, vendor: String) -> some View {
        modifier(GlyphTile(role: role, key: glyphKey(profile, vendor)))
    }
}

private struct GlyphTile: ViewModifier {
    let role: GlyphRole
    let key: String
    @Environment(\.flyingGlyphs) private var flying

    func body(content: Content) -> some View {
        content
            .opacity(flying.contains(key) ? 0 : 1)
            .background(GeometryReader { g in
                Color.clear.preference(key: TileFrames.self,
                                       value: ["\(role.rawValue)|\(key)": g.frame(in: .named(stackSpace))])
            })
    }
}

private struct Flight: Identifiable {
    let id: String          // glyph key
    let vendor: Vendor
    let status: SlotStatus
    let from: CGRect
    let to: String          // frame key of the destination, read as it lays out
    let index: Int
}

struct PageStack<Page: View>: View {
    @ObservedObject var model: PanelModel
    @ViewBuilder let page: (PanelRoute?) -> Page
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heights: [String: CGFloat] = [:]
    @State private var frames: [String: CGRect] = [:]
    @State private var flights: [Flight] = []
    @State private var landed: Set<String> = []
    @State private var generation = 0
    /// The path as last drawn, to tell a push from a pop.
    @State private var shown: [PanelRoute] = []

    private var stack: [(depth: Int, route: PanelRoute?)] {
        [(0, nil)] + model.path.enumerated().map { ($0.offset + 1, $0.element) }
    }

    private func id(_ depth: Int, _ route: PanelRoute?) -> String { "\(depth)-\(route.map { "\($0)" } ?? "fleet")" }

    var body: some View {
        let all = stack
        let top = all.count - 1
        let visible = all.suffix(2)
        ZStack(alignment: .topLeading) {
            ForEach(visible, id: \.depth) { item in
                let key = id(item.depth, item.route)
                let isTop = item.depth == top
                page(item.route)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Metrics.width, alignment: .top)
                    .background(Ink.page)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                        withAnimation(heights[key] == nil ? nil : Motion.nav(reduce: reduceMotion)) { heights[key] = h }
                    }
                    .offset(x: isTop || reduceMotion ? 0 : -0.3 * Metrics.width)
                    .opacity(isTop ? 1 : 0)
                    .allowsHitTesting(isTop)
                    .accessibilityHidden(!isTop)
                    .zIndex(Double(item.depth))
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                    .id(key)
            }
        }
        .frame(width: Metrics.width, height: all.last.flatMap { heights[id($0.depth, $0.route)] }, alignment: .top)
        .clipped()
        .overlay(alignment: .topLeading) { ghosts }
        .coordinateSpace(name: stackSpace)
        .onPreferenceChange(TileFrames.self) { frames = $0; land() }
        .environment(\.flyingGlyphs, Set(flights.map(\.id)))
        .onChange(of: model.path) { new in
            fly(from: shown, to: new)
            shown = new
        }
        .onAppear { shown = model.path }
        .background {
            // Esc and ⌘[ go back a page; at Fleet, Esc falls through and closes the panel.
            if !model.path.isEmpty {
                Button("") { model.pop() }.keyboardShortcut(.escape, modifiers: []).hidden()
                Button("") { model.pop() }.keyboardShortcut("[", modifiers: .command).hidden()
            }
        }
    }

    private var ghosts: some View {
        ForEach(flights) { f in
            let r = landed.contains(f.id) ? frames[f.to] ?? f.from : f.from
            LogoTile(vendor: f.vendor, status: f.status)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    /// Strip ↔ rows: every lab of the profile flies, fanned out by 28 ms each.
    private func fly(from old: [PanelRoute], to new: [PanelRoute]) {
        guard !reduceMotion, let data = model.data else { flights = []; return }
        let (profile, source, destination): (String, GlyphRole, GlyphRole)
        var only: String?   // one lab's flight, rather than the whole profile's
        if new.count == old.count + 1, case .profile(let p)? = new.last {
            (profile, source, destination) = (p, .strip, .row)
        } else if old.count == new.count + 1, case .profile(let p)? = old.last {
            (profile, source, destination) = (p, .row, .strip)
        } else if new.count == old.count + 1, case .provider(let p, let v)? = new.last {
            (profile, source, destination, only) = (p, .row, .hero, v)
        } else if old.count == new.count + 1, case .provider(let p, let v)? = old.last {
            (profile, source, destination, only) = (p, .hero, .row, v)
        } else {
            flights = []
            return
        }
        guard let p = data.profiles.first(where: { $0.name == profile }) else { return }
        generation += 1
        landed = []
        flights = data.slotted(p).filter { only == nil || $0.id == only }.enumerated().compactMap { i, v in
            let key = glyphKey(profile, v.id)
            guard let from = frames["\(source.rawValue)|\(key)"] else { return nil }
            return Flight(id: key, vendor: v, status: model.status(profile, v).status, from: from,
                          to: "\(destination.rawValue)|\(key)", index: i)
        }
        land()
        let generation = generation
        let last = Double(flights.count) * 0.028
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.flightDuration + last + 0.05) {
            guard self.generation == generation else { return }
            flights = []
            landed = []
        }
    }

    /// Each copy sets off once its destination has been laid out.
    private func land() {
        for f in flights where !landed.contains(f.id) && frames[f.to] != nil {
            withAnimation(Motion.flight(f.index)) { _ = landed.insert(f.id) }
        }
    }
}

// The bar across the top of every pushed page: back to the parent, named,
// a centred title, and one optional control at the trailing edge.
struct NavBar<Leading: View, Trailing: View>: View {
    var height: CGFloat = 44
    var title: String? = nil
    let back: () -> Void
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        ZStack {
            if let title {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 96)
            }
            HStack(spacing: 0) {
                Button(action: back) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Ink.link)
                            .frame(width: 16)
                        leading
                    }
                    .padding(.leading, 4).padding(.trailing, 8)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(radius: 7))
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 8)
        }
        .frame(height: height)
    }
}
