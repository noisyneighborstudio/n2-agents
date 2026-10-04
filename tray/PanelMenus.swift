import AppKit
import SwiftUI

/// A localized string with automatic grammar agreement ("^[3 profile](inflect:
/// true)" → "3 profiles"). String(localized:) leaves that markup as text; only
/// an attributed string resolves it.
/// Agreement is costly to compute, so each distinct sentence is resolved once.
func inflected(_ value: String.LocalizationValue, comment: StaticString) -> String {
    let key = String(localized: value, comment: comment)
    if let done = Inflections.done[key] { return done }
    let resolved = String(AttributedString(localized: value, comment: comment).characters)
    Inflections.done[key] = resolved
    return resolved
}

private enum Inflections {
    nonisolated(unsafe) static var done: [String: String] = [:]
}

/// The Active switch's menu, as data: every profile (checked when it's active
/// for every lab it holds), then one submenu per lab listing the profiles that
/// hold it (checked where that lab is active). Choosing a profile makes it
/// active for all its labs; choosing within a lab changes only that lab.
struct ActiveMenu: Equatable {
    struct Choice: Equatable {
        let profile: String
        let vendor: String?     // nil: every lab
        let checked: Bool
    }
    struct Lab: Equatable {
        let vendor: String
        let label: String
        let choices: [Choice]
    }

    let profiles: [Choice]
    let labs: [Lab]

    init(snapshot: Snapshot, profiles: [Profile]) {
        self.profiles = profiles.map { Choice(profile: $0.name, vendor: nil, checked: snapshot.active == $0.name) }
        labs = snapshot.installedVendors.compactMap { v in
            let holders = profiles.filter { $0.slots[v.id] != nil }
            // A lab only one profile holds has nothing to switch.
            guard holders.count > 1 else { return nil }
            return Lab(vendor: v.id, label: v.label,
                       choices: holders.map { Choice(profile: $0.name, vendor: v.id, checked: $0.isActive(for: v.id)) })
        }
    }

    /// What the header says: the one active profile, or that labs differ.
    static func title(_ snapshot: Snapshot) -> String? {
        snapshot.active == "mixed" ? nil : snapshot.active
    }

    /// The labs a profile is active for, in the snapshot's order.
    static func activeLabs(_ profile: Profile, _ snapshot: Snapshot) -> [Vendor] {
        snapshot.installedVendors.filter { profile.isActive(for: $0.id) }
    }

    /// A card's word for where new sessions go: "Active" on the one active
    /// profile; while labs use different profiles, the labs this one is
    /// active for, which is what the header's Mixed means card by card.
    static func badge(_ profile: Profile, _ snapshot: Snapshot) -> String? {
        if snapshot.active == profile.name { return String(localized: "Active", comment: "The profile new sessions use") }
        guard snapshot.active == "mixed" else { return nil }
        let labs = activeLabs(profile, snapshot)
        switch labs.count {
        case 0: return nil
        case 1: return String(localized: "Active for \(labs[0].label)", comment: "Profile card while labs differ: its one active lab")
        default: return String(localized: "Active for \(labs.count) labs", comment: "Profile card while labs differ: how many labs it is active for")
        }
    }
}

// MARK: - AppKit menus

// SwiftUI's Menu flattens custom labels on macOS, so the panel's menus are
// plain NSMenus, each opened under the control that owns it.
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

/// Where a control's menu opens: an AppKit view behind the control, so the
/// menu drops from its bottom edge however it was pressed — by pointer,
/// keyboard or VoiceOver — rather than wherever the pointer happens to be.
final class MenuAnchor {
    /// Every view drawn for the control. Mid-transition SwiftUI draws a page
    /// twice and may update the outgoing copy last, so the one to open from is
    /// whichever is still in a window, not whichever was set last.
    private let views = NSHashTable<NSView>.weakObjects()
    var view: NSView? { views.allObjects.first { $0.window != nil } }
    func add(_ view: NSView) { views.add(view) }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.add(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.add(view) }
}

extension View {
    /// The control whose bottom edge `popUp(_:under:)` opens a menu from.
    func menuAnchor(_ anchor: MenuAnchor) -> some View { background(MenuAnchorView(anchor: anchor)) }
}

func popUp(_ items: [NSMenuItem], under anchor: MenuAnchor) {
    let menu = NSMenu()
    items.forEach(menu.addItem)
    guard let view = anchor.view, let window = view.window else { return }
    // A control in the trailing half lines the menu up with its trailing
    // edge, so the menu hangs inside the panel rather than off its side.
    let trailing = view.convert(view.bounds, to: nil).midX > window.frame.width / 2
    let x = trailing ? view.bounds.maxX - menu.size.width : 0
    menu.popUp(positioning: nil, at: NSPoint(x: x, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
}
