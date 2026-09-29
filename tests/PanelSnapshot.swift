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
        case "banners"?:
            model.fleet?.pending = [FleetPending(id: "SHA256:" + String(repeating: "c", count: 43), machine: "studio",
                                                 transport: "ssh", requestedAt: Date())]
            model.fleet?.conflicts = [FleetConflict(id: "c1", address: "profile|Work|claude|settings", digest: "", remote: "present", inScope: true)]
            model.fleet?.sync.conflicts = 1
        case "tasks"?, "task"?:
            model.fleet?.tasks += [FleetTask(id: "t-9d20", state: .disconnected, vendor: "claude", rc: "", label: "nightly evals",
                                             machine: "mac-mini", role: "dispatcher"),
                                   FleetTask(id: "t-0b11", state: .done, vendor: "codex", rc: "0", label: "lint fleet docs",
                                             machine: "mac-mini", role: "dispatcher")]
            model.fleet?.tasks.sort { ["t-9d20", "t-kc01", "t-7f3a", "t-0b11"].firstIndex(of: $0.id)! < ["t-9d20", "t-kc01", "t-7f3a", "t-0b11"].firstIndex(of: $1.id)! }
            if state.first == "task" { model.path = [.task(state.count > 1 ? state[1] : "t-kc01")] }
        case "work"?:
            model.workDraft = WorkDraft(task: "Run the nightly evals and summarize regressions", workspace: "~/Development/evals",
                                        state: .planned(FleetPlan.parse("1\tSHA256:b\tmac-mini\tclaude\t90s\tno\t0\t1\t2\t87\n2\tSHA256:a\tmacbook-pro\tcodex\t140s\tno\t0\t0\t2\t138\n")))
            model.path = [.sendWork]
        case "fleet-settings"?:
            model.fleet?.tools = [FleetTool(id: "ripgrep", want: "14.1.0", state: .update, disruptive: false)]
            model.fleet?.exceptions = [FleetException(id: "profile|Work|claude|*", index: 1)]
        case "machine"?:
            model.path = [.machine("SHA256:" + String(repeating: "b", count: 43))]
        case "send"?:
            let id = "codex/7c1e4b8a-0000-4000-8000-000000000001"
            model.sendDrafts[id] = SendDraft(cwd: "/Users/seth/Development/n2-agents")
            model.path = [.sendSession(id)]
        case "configure"?:
            model.path = [.profile(profile), .provider(profile: profile, vendor: vendor), .configure(profile: profile, vendor: vendor)]
        // Motion: settle, move, and capture a frame every 40 ms until it lands.
        case "push"?:
            move = { model.push(.profile(profile)) }
        case "pop"?:
            model.path = [.profile(profile)]
            move = { model.pop() }
        case "switch"?:
            model.path = [.profile(profile), .provider(profile: profile, vendor: vendor)]
            move = {
                guard let v = model.data?.snapshot.vendor(vendor), let s = model.suggestion(for: profile, v) else { return }
                model.switchTo(s)
            }
        case "open"?:
            model.path = [.profile(profile)]
            move = { model.push(.provider(profile: profile, vendor: vendor)) }
        default:
            break
        }
        model.refreshedAt = Date().addingTimeInterval(-120)
        // Pinned top over the glass's tone, as GlassWindow holds it.
        let feed = ToastFeed()
        if ["stack", "fan", "arrive"].contains(state.first ?? "") {
            let tiers = Fixture.tiers(model)
            for w in tiers.prefix(state.first == "arrive" ? 3 : 4) { feed.add(w, from: 100) }
            if state.first == "fan" { feed.hover(true) }
            if state.first == "arrive" { move = { feed.add(tiers[3], from: 10) } }
        }
        let root = Group {
            if state.first == "fleet-settings" {
                FleetSettingsSection(model: model, actions: Fixture.actions).padding(24).frame(width: 500)
            } else if ["stack", "fan", "arrive"].contains(state.first ?? "") {
                ToastStack(feed: feed, model: model, actions: Fixture.actions, open: { _ in }).padding(.top, 10)
            } else if state.first == "toast", let card = Fixture.toast(state.count > 1 ? state[1] : "half", model) {
                card.background(RoundedRectangle(cornerRadius: 18).fill(Ink.page)).padding(10)
            } else {
                PanelView(model: model, actions: Fixture.actions)
            }
        }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(["toast", "stack", "fan", "arrive"].contains(state.first ?? "") ? Color.gray.opacity(0.25) : Ink.page)
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
            let size = NSSize(width: max(360, host.fittingSize.width), height: height ?? host.fittingSize.height)
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

    /// Work's Claude through the four tiers, as Play the Week sends them.
    static func tiers(_ model: PanelModel) -> [UsageWarning] {
        let week = 7 * 86400.0
        return [50.0, 75, 90, 100].map { used in
            let window = Usage.Window(scope: "seven_day", percent: used, resets: Date().addingTimeInterval(week * 0.4), durationSeconds: week)
            let status: SlotStatus = used >= 100 ? .out(back: window.resets) : used > 80 ? .low(left: Int(100 - used)) : .ready(left: Int(100 - used))
            return UsageWarning(profile: "Work", vendor: "claude", status: status, tier: UsageTier(status)!, window: window)
        }
    }

    /// A toast for one tier, on Work's Claude (the fixture's low slot) at that tier's reading.
    static func toast(_ tier: String, _ model: PanelModel) -> UsageToastCard? {
        let used: Double = ["half": 50, "quarter": 75, "low": 90, "out": 100][tier] ?? 50
        let week = 7 * 86400.0
        var u = reading(used: used, resets: week * 0.4)
        if used == 100 { u.windows = [.init(scope: "seven_day", percent: 100, resets: Date().addingTimeInterval(2 * 86400 + 20 * 3600), durationSeconds: week)] }
        model.usage["claude"]?["Work"] = u
        guard let v = model.data?.snapshot.vendor("claude"),
              let w = model.usageWarnings.warnings.first(where: { $0.id == "Work|claude" }) else { return nil }
        return UsageToastCard(warning: w, vendor: v, model: model, actions: actions, open: {}, close: {})
    }

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
                if let app = vendors.first(where: { $0.id == v })?.desktopName, !app.isEmpty {
                    snapshot.desktopDirs[name, default: [:]][v] = NSHomeDirectory() + "/Library/Application Support/\(app)-\(name)"
                }
            }
        }
        let profiles = rows.map { Profile(name: $0.name, running: false, slots: $0.slots) }
        let model = PanelModel()
        let now = Date().timeIntervalSince1970
        let sessions = SessionInfo.parse("""
            Default\tcodex\t7c1e4b8a-0000-4000-8000-000000000001\t\(now - 240)\t\(NSHomeDirectory())/Development/n2-agents\tRedesign the menu bar panel\tseth/tray-redesign\tStart/configure UI redesign
            Work\tclaude\tsess-2\t\(now - 3600)\t\(NSHomeDirectory())/Development/site\tFix the pricing table\tmain\t
            Default\tclaude\tsess-3\t\(now - 7200)\t\(NSHomeDirectory())/Development/n2-agents\tWrite fleet docs\tmain\tFleet readiness notes
            """)
        model.data = PanelData(snapshot: snapshot, profiles: profiles, sessions: sessions,
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
        model.fleet = fleet()
        return model
    }

    /// This Mac in sync with one other: mac-mini, running a task; one failed.
    static func fleet() -> FleetData {
        var f = FleetData()
        f.initialized = true
        f.machine = "macbook-pro"
        f.selfID = "SHA256:" + String(repeating: "a", count: 43)
        f.observedAt = Date()
        f.peers = [FleetPeer(id: f.selfID, machine: "macbook-pro", transport: "self", state: .approved, reach: .`self`),
                   FleetPeer(id: "SHA256:" + String(repeating: "b", count: 43), machine: "mac-mini", transport: "tailscale",
                             state: .approved, reach: .online)]
        f.sync = FleetSync(machine: "macbook-pro", selfID: f.selfID, resources: 12, agreed: 12)
        f.tasks = [FleetTask(id: "t-7f3a", state: .running, vendor: "claude", rc: "", label: "migrate settings store",
                             machine: "mac-mini", role: "dispatcher"),
                   FleetTask(id: "t-kc01", state: .failed, vendor: "codex", rc: "1", label: "kc-before",
                             machine: "macbook-pro", role: "dispatcher")]
        f.notices = [FleetNotice(at: Date().addingTimeInterval(-1500), kind: .started, task: "t-7f3a", machine: "mac-mini",
                                 text: "migrate settings store"),
                     FleetNotice(at: Date().addingTimeInterval(-3000), kind: .failed, task: "t-kc01", machine: "macbook-pro",
                                 text: "kc-before")]
        f.loaded = Set(FleetRead.allCases)
        return f
    }
}

final class NoActions: PanelActions, FleetActions {
    func fleetInit() {}
    func fleetEnroll(transport: String) {}
    func fleetApprove(peer: String) {}
    func fleetDeny(peer: String) {}
    func fleetRevoke(peer: String) {}
    func fleetResolve(conflict: String, keepLocal: Bool) {}
    func fleetExcept(address: String, add: Bool) {}
    func fleetToolApply(_ name: String?) {}
    func fleetPlan(_ spec: FleetDispatchSpec) {}
    func fleetDispatch(_ spec: FleetDispatchSpec) {}
    func fleetShowTask(_ id: String) {}
    func fleetRetry(task: String) {}
    func fleetDistribute(task: String, machine: String?) {}
    func fleetReconcileTasks() {}

    func openSession(profile: String, vendor: String, terminal: String?) {}
    func setActive(profile: String, vendor: String?) {}
    func copyCommand(profile: String, vendor: String) {}
    func copyPath(_ path: String) {}
    func revealPath(_ path: String) {}
    func openDesktop(profile: String, vendor: String) {}
    func signIn(profile: String, vendor: String, confirm: Bool) {}
    func finishSetup(profile: String) {}
    func resumeSession(_ session: SessionInfo) {}
    func sendSession(_ session: SessionInfo) {}
    func sendSession(_ session: SessionInfo, to peer: String, cwd: String) {}
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
    func playUsageWeek() {}
    func setPreferredTerminal(_ name: String) {}
    func setUpdateChannel(_ channel: UpdateChannel) {}
    var panelShortcut: String? { nil }
    func setPanelShortcut() {}
    func checkForUpdates() {}
    func reportBug() {}
    func quit() {}
}
