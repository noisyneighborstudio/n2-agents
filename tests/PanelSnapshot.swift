import AppKit
import SwiftUI

// Renders the real panel views over a fixed fleet (the design prototype's
// data) to a PNG, so a change can be checked by eye in both appearances
// without a live CLI. Usage: panel-snapshot <state> <light|dark> <out.png>
@main struct PanelSnapshot {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            FileHandle.standardError.write(Data("usage: panel-snapshot <state> <light|dark> <out.png>\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let dark = args[2] == "dark"
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let model = Fixture.model()
        let state = args[1].split(separator: "/").map(String.init)
        let profile = state.count > 1 ? state[1] : "Default", vendor = state.count > 2 ? state[2] : "codex"
        var move: (() -> Void)?
        switch state.first {
        case "profile"?:
            model.path = [.profile(profile)]
        case "provider"?:
            model.path = [.profile(profile), .provider(profile: profile, vendor: vendor)]
        case "configure"?:
            model.path = [.profile(profile), .provider(profile: profile, vendor: vendor), .configure(profile: profile, vendor: vendor)]
        // Motion: settle, move, and capture a frame every 40 ms until it lands.
        case "push"?:
            move = { model.push(.profile(profile)) }
        case "pop"?:
            model.path = [.profile(profile)]
            move = { model.pop() }
        case "open"?:
            model.path = [.profile(profile)]
            move = { model.push(.provider(profile: profile, vendor: vendor)) }
        default:
            break
        }
        model.refreshedAt = Date().addingTimeInterval(-120)
        // Pinned top over the glass's tone, as GlassWindow holds it.
        let root = PanelView(model: model, actions: Fixture.actions)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Ink.page)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = app.appearance
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 360, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = app.appearance
        window.contentView = host
        window.orderFrontRegardless()
        // Let SwiftUI settle (onAppear, preference changes) before drawing.
        func settle(_ seconds: Double) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            host.layoutSubtreeIfNeeded()
        }
        func draw(_ path: String, height: CGFloat? = nil) {
            let size = NSSize(width: 360, height: height ?? host.fittingSize.height)
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: rep)
            }
            guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
            try! png.write(to: URL(fileURLWithPath: path))
            print("\(path) \(Int(size.width))x\(Int(size.height))")
        }
        settle(0.6)
        guard let move else {
            settle(1.0)
            draw(args[3])
            return
        }
        let height = max(host.fittingSize.height, 460)
        draw(args[3].replacingOccurrences(of: ".png", with: "-00.png"), height: height)
        move()
        for frame in 1...20 {
            settle(0.04)
            draw(args[3].replacingOccurrences(of: ".png", with: String(format: "-%02d.png", frame)), height: height)
        }
    }
}

enum Fixture {
    static let actions = NoActions()

    static func vendor(_ id: String, _ label: String, usage: String = "oauth", long: String = "7d",
                       desktop: String = "") -> Vendor {
        Vendor(id: id, installed: true, desktop: desktop.isEmpty ? "none" : "instance", usage: usage, label: label,
               sessions: "none", monogram: String(id.prefix(2)).uppercased(), desktopName: desktop,
               desktopBundle: "", longWindow: long)
    }

    static func reading(used: Double, resets: TimeInterval, scope: String = "seven_day",
                        duration: Double = 7 * 86400) -> Usage {
        var u = Usage(fiveHour: nil, sevenDay: nil, resets: nil, note: .ok, sevenResets: nil,
                      windows: [.init(scope: scope, percent: used, resets: Date().addingTimeInterval(resets),
                                      durationSeconds: duration)])
        u.identityStatus = "verified"
        u.accountHash = String(repeating: "2dde0c4f", count: 8)
        return u
    }

    static func model() -> PanelModel {
        let vendors = [vendor("claude", "Claude Code", desktop: "Claude"), vendor("codex", "Codex", desktop: "Codex"),
                       vendor("cursor", "Cursor", long: "mo"), vendor("opencode", "opencode", usage: "none"),
                       vendor("muse", "Muse"), vendor("grok", "Grok")]
        let slots: [String: [String]] = ["Default": ["claude", "codex", "cursor", "opencode", "muse"],
                                         "Expo": ["claude", "codex", "grok"], "Work": ["claude", "codex", "cursor"]]
        let order = ["Default", "Expo", "Work"]
        let rows = order.map { name in
            ProfileRow(name: name, desktopRunning: false,
                       slots: Dictionary(uniqueKeysWithValues: slots[name]!.map { ($0, name == "Default" ? "active" : "ok") }))
        }
        var snapshot = Snapshot(vendors: vendors, profiles: rows, active: "Default")
        for name in order {
            for v in slots[name]! {
                snapshot.slotDirs[name, default: [:]][v] = NSHomeDirectory() + "/.n2-agents/profiles/\(name)/\(v)"
                snapshot.signedIn[name, default: [:]][v] = !(name == "Expo" && v == "grok")
            }
        }
        let profiles = rows.map { Profile(name: $0.name, running: false, slots: $0.slots) }
        let model = PanelModel()
        model.data = PanelData(snapshot: snapshot, profiles: profiles, sessions: [],
                               terminals: ["Ghostty", "Terminal", "iTerm2", "Warp"], desktops: ["claude", "codex"])
        let hour: TimeInterval = 3600, day = 24 * hour
        var out = reading(used: 100, resets: 3 * day + 10 * hour + 54 * 60)
        out.note = .restricted
        out.restrictionReasons = ["primary: rate_limit_reached"]
        out.restrictionResets = [Date().addingTimeInterval(3 * day + 10 * hour + 54 * 60)]
        var failed = Usage(fiveHour: nil, sevenDay: nil, resets: nil, note: .fetchError, sevenResets: nil,
                           fetchedAt: .distantPast, windows: [])
        failed.identityStatus = "unavailable"
        model.usage = [
            "claude": ["Default": reading(used: 68, resets: 3 * day + 8 * hour),
                       "Expo": reading(used: 19, resets: 4 * day + 13 * hour),
                       "Work": reading(used: 88, resets: 2 * day + 16 * hour)],
            "codex": ["Default": out,
                      "Expo": reading(used: 45, resets: 6 * day + 7 * hour),
                      "Work": reading(used: 10, resets: 7 * hour)],
            "cursor": ["Default": reading(used: 0, resets: 22 * day, scope: "mo", duration: 30 * day),
                       "Work": reading(used: 36, resets: 15 * day, scope: "mo", duration: 30 * day)],
            "muse": ["Default": failed],
        ]
        return model
    }
}

final class NoActions: PanelActions {
    func openSession(profile: String, vendor: String, terminal: String?) {}
    func setActive(profile: String, vendor: String?) {}
    func copyCommand(profile: String, vendor: String) {}
    func copyPath(_ path: String) {}
    func openDesktop(profile: String, vendor: String) {}
    func signIn(profile: String, vendor: String, confirm: Bool) {}
    func finishSetup(profile: String) {}
    func resumeSession(_ session: SessionInfo) {}
    func sendSession(_ session: SessionInfo) {}
    func moveSession(_ session: SessionInfo, to profile: String) {}
    func copyResumeCommand(_ session: SessionInfo) {}
    func showAllSessions() {}
    func closeSessions() {}
    func showSettings() {}
    func closeSettings() {}
    func reonboardAccounts() {}
    func signInMissingAccounts() {}
    func installCLI() -> String { "" }
    func addVendor(profile: String) {}
    func deleteProfile(_ name: String) {}
    func newProfile() {}
    func retryUsage() {}
    func setPreferredTerminal(_ name: String) {}
    func setUpdateChannel(_ channel: UpdateChannel) {}
    var panelShortcut: String? { nil }
    func setPanelShortcut() {}
    func checkForUpdates() {}
    func reportBug() {}
    func quit() {}
}
