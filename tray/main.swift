import AppKit
import Combine
import SwiftUI
#if canImport(Sparkle)
import Sparkle
typealias UpdaterDelegateProtocol = SPUUpdaterDelegate
#else
protocol UpdaterDelegateProtocol {}
#endif

// N2 Agents — menu bar panel for cross-vendor agent profiles.
//
// A profile is an IDENTITY holding one slot per lab (Claude, Codex, Grok, …),
// so switching moves every vendor at once. The whole profile/vendor model is
// owned by the `agents` CLI; this app parses `agents porcelain` and shells back
// out for anything with side effects, so the two cannot drift.
// Helper scripts are embedded in the app bundle (Contents/Resources).
//
// Resident duty beyond the panel: self-update, delegated to Sparkle.

// A profile as the panel needs it: the CLI's porcelain row.
struct Profile {
    let name: String
    let running: Bool       // one of its desktop instances is open
    /// vendor id -> "active" | "ok"; absent means no slot for that vendor.
    let slots: [String: String]

    var isDefault: Bool { name == "Default" }
    func isActive(for vendor: String) -> Bool { slots[vendor] == "active" }
}

func appleScriptEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

// Known terminals and how to hand each one a command. Only installed ones are shown.
struct TerminalSpec {
    let name: String
    let bundleId: String
    let kind: Kind
    enum Kind {
        case appleScript((String) -> String)   // cmd -> osascript source (needs Automation permission)
        case openArgs((String) -> [String])    // cmd -> CLI args for a new app instance
        case warpLaunchConfig                  // Warp: launch-configuration yaml + warp:// URL
    }
}

let terminalSpecs: [TerminalSpec] = [
    TerminalSpec(name: "Terminal", bundleId: "com.apple.Terminal", kind: .appleScript { cmd in
        "tell application id \"com.apple.Terminal\"\nactivate\ndo script \"\(appleScriptEscape(cmd))\"\nend tell"
    }),
    TerminalSpec(name: "iTerm2", bundleId: "com.googlecode.iterm2", kind: .appleScript { cmd in
        "tell application id \"com.googlecode.iterm2\"\nactivate\nset w to (create window with default profile)\ntell current session of w to write text \"\(appleScriptEscape(cmd))\"\nend tell"
    }),
    TerminalSpec(name: "Warp", bundleId: "dev.warp.Warp-Stable", kind: .warpLaunchConfig),
    TerminalSpec(name: "Ghostty", bundleId: "com.mitchellh.ghostty", kind: .openArgs { cmd in
        ["-e", "/bin/zsh", "-lc", cmd]
    }),
    TerminalSpec(name: "kitty", bundleId: "net.kovidgoyal.kitty", kind: .openArgs { cmd in
        ["/bin/zsh", "-lc", cmd]
    }),
    TerminalSpec(name: "Alacritty", bundleId: "org.alacritty", kind: .openArgs { cmd in
        ["-e", "/bin/zsh", "-lc", cmd]
    }),
    TerminalSpec(name: "WezTerm", bundleId: "com.github.wez.wezterm", kind: .openArgs { cmd in
        ["start", "--", "/bin/zsh", "-lc", cmd]
    }),
]

final class AppDelegate: NSObject, NSApplicationDelegate, UpdaterDelegateProtocol, PanelActions, FleetActions, SetupHost {
    var statusItem: NSStatusItem!
    let model = PanelModel()
    var announcer = FleetAnnouncer()
    var fleetReadID: UUID?
    var notificationAttempt: UUID?
    private var statusIcon: StatusIcon?
    private var quotaWatch: AnyCancellable?
    private var menuBarAppearance: NSKeyValueObservation?
    private var drawnIcon: (remaining: Int?, dark: Bool, attention: Bool, dot: UsageTier?)?
    /// The worst toast dismissed since the panel was last opened, from the quarter tier.
    private var iconDot: UsageTier?
    // A click opens the panel on that lab's page.
    private lazy var quotaToast = QuotaToast(anchor: statusItem.button!, model: model, actions: self, open: { [weak self] warning in
        guard let self else { return }
        self.model.path = [.profile(warning.profile), .provider(profile: warning.profile, vendor: warning.vendor)]
        self.model.closedAt = nil
        if !self.panel.isShowing { self.togglePanel() }
    }, dismissed: { [weak self] warning in
        guard let self, warning.tier >= .quarter, !self.panel.isShowing else { return }
        self.iconDot = max(self.iconDot ?? warning.tier, warning.tier)
        self.drawStatusIcon()
    })
    // Built on first use (an open, or the first quota reading): it anchors to
    // the status item's button.
    private lazy var panel: GlassWindow = {
        let panel = GlassWindow(rootView: PanelView(model: model, actions: self),
                                behavior: .transient(anchor: statusItem.button!))
        panel.onDismiss = { [weak self] in self?.model.closedAt = Date() }
        return panel
    }()
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.togglePanel() }
    /// Recent sessions, opened out of the panel into its own window.
    private var sessionsWindow: GlassWindow?
    /// Preferences live in a persistent window rather than a transient menu.
    private var settingsWindow: GlassWindow?
    private let fm = FileManager.default
    private let home = NSHomeDirectory()
    private let newIssueURL = "https://github.com/noisyneighborstudio/n2-agents/issues/new"

    private var updateStatus: UpdateStatus? {
        didSet {
            model.updateStatus = updateStatus
            refreshStatusTitle()
        }
    }
#if canImport(Sparkle)
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
    )
#endif

    // Scripts live in the bundle's Resources; fall back to the source tree when
    // running the bare dev binary.
    private var scriptsDir: String {
        if let r = Bundle.main.resourcePath, fm.fileExists(atPath: r + "/agents") {
            return r
        }
        return home + "/Development/n2-agents"
    }

    /// The PATH the bundled scripts run with, read once per launch (a static
    /// initialises exactly once, whichever thread asks first).
    private static let scriptPATH = ShellPath.fromLoginShell()
        ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

    /// What every bundled script runs in: this process's environment, with a
    /// PATH that can actually find the labs.
    private static var scriptEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = scriptPATH
        return env
    }

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let r = Bundle.main.resourcePath, let icon = NSImage(contentsOfFile: r + "/n2agents.icns") {
            statusIcon = StatusIcon(base: icon)
            drawStatusIcon()
            statusItem.button?.imagePosition = .imageLeft
        } else {
            statusItem.button?.title = "🤖"
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        if !UpdateChannel.isQABuild { hotKey.register(Shortcut.load()) }
        // @Published fires before the store, so read the model a turn later.
        quotaWatch = model.$data.combineLatest(model.$usage, model.$pendingSetups)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.quotaChanged() }
        // The drained part is drawn in the menu bar's ink, which follows the
        // wallpaper behind it.
        menuBarAppearance = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.drawStatusIcon() }
        }


        // The panel is ready before anyone clicks: it starts from the last
        // snapshot saved to disk, re-reads now and every few minutes, and an
        // open shows the last read at once while a fresh one runs behind it.
        // Nothing ever waits on the CLI to draw; only a first-ever launch has
        // nothing to show, and says so.
        model.pendingSetups = defaults.dictionary(forKey: CacheKey.pendingSetups) as? [String: [String]] ?? [:]
        if let porcelain = defaults.string(forKey: CacheKey.porcelain) {
            model.data = buildPanelData(porcelain: porcelain, sessions: defaults.string(forKey: CacheKey.sessions) ?? "")
        }
        refreshPanel()
        // The first full session read indexes every transcript, which takes
        // minutes on a big history; do it now, not when the window is opened.
        loadAllSessions()
        refreshFleet()
        Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in self?.refreshFleet() }
        // Expiry must still reach the UI when a collector is stuck.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.usage = self.model.usage.mapValues { Usage.expire($0, at: Date()) }
        }
        Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            self?.refreshPanel()
            // Every session too, so a profile's Recent is there before it's opened.
            self?.loadAllSessions()
        }

        // Keep claude-as / claude-<profile> on PATH in step with the profile
        // list — real executables, so apps and scripts get them too, and
        // upgrades from a shell-function-only version heal themselves.
        if !UpdateChannel.isQABuild {
            DispatchQueue.global(qos: .utility).async { self.runCLI(["shims"]) }
        }

#if canImport(Sparkle)
        // Sparkle owns automatic scheduling and signature verification. Both
        // automatic and manual checks obtain their feed from the delegate below.
        // The controller is lazy: a QA build never touches it, so never updates.
        if !UpdateChannel.isQABuild {
            _ = updaterController
            updaterController.updater.automaticallyChecksForUpdates = true
        }
#endif
    }

    // The icon is a gauge of quota left, and anything newly low gets a toast.
    private func quotaChanged() {
        drawStatusIcon()
        quotaToast.update(quiet: panel.isShowing)
    }

    private func drawStatusIcon() {
        guard let icon = statusIcon, let button = statusItem.button else { return }
        let match = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        let drawn = (remaining: model.remaining, dark: match == .darkAqua || match == .vibrantDark,
                     attention: model.needsAttention, dot: iconDot)
        // Setting the image re-resolves the button's appearance, which fires
        // the observer that calls this: redraw only on a real change, or the
        // two feed each other forever.
        statusItem.button?.toolTip = model.capacitySummary
        if let last = drawnIcon, last == drawn { return }
        drawnIcon = drawn
        let image = icon.image(remaining: drawn.remaining, dark: drawn.dark, attention: drawn.attention,
                               dot: drawn.dot.map { drawn.dark ? $0.tone.dark : $0.tone.light })
        button.image = UpdateChannel.isQABuild ? StatusIcon.taggedQA(image) : image
    }

    // MARK: - Panel (re-read every time it opens)

    @objc private func togglePanel() {
        if panel.isShowing {
            panel.dismiss()
            return
        }
        quotaToast.dismiss()
        iconDot = nil
        drawStatusIcon()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            model.presented = false
            // Back within a minute, the panel reopens where it was; after
            // that, at Fleet.
            if let closed = model.closedAt, Date().timeIntervalSince(closed) > 60 {
                model.path = []
            }
        }
        // Sized from the already-loaded content, so the first frame is the
        // finished panel, not an empty one that grows into place.
        panel.present()
        DispatchQueue.main.async { self.model.presented = true }
        // Everything shown was read in advance, on the timers. Opening re-reads
        // only what has gone stale, so the panel isn't re-rendering under the
        // pointer while it's being used.
        if Date().timeIntervalSince(panelReadAt) > Self.openFreshness { refreshPanel() }
        refreshUsage(force: false, onDemand: true)
        if Date().timeIntervalSince(model.fleet?.observedAt ?? .distantPast) > Self.openFreshness { refreshFleet() }
    }

    /// How old a read may be and still be shown as is when the panel opens.
    private static let openFreshness: TimeInterval = 30
    private var panelReadAt = Date.distantPast
    /// The last panel read as published: an identical read publishes nothing.
    private var panelSource: String?

    // Anything that opens a window, dialog or terminal closes the panel first:
    // a transient panel would otherwise vanish under it mid-click. A dialog
    // that is one step of the panel's work brings it back (returnToPanel).
    func dismissPanel() {
        panel.dismiss()
    }

    /// After an alert the panel closed for, it opens again where it was: the
    /// alert was a step in the panel's work, not the end of it.
    func returnToPanel() {
        guard !panel.isShowing else { return }
        togglePanel()
    }

    // A refresh reads the CLI and the disk off the main thread and publishes
    // one PanelData. Refreshes can overlap (open, close, reopen); only the
    // newest one is allowed to land, so a slow early read never overwrites a
    // fresh one.
    private var refreshGeneration = 0

    func refreshPanel() {
        refreshGeneration += 1
        let generation = refreshGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let data = self.loadPanelData()
            DispatchQueue.main.async {
                guard generation == self.refreshGeneration, let (data, source) = data else { return }
                self.panelReadAt = Date()
                defer { self.refreshUsage(force: false) }
                guard source != self.panelSource else { return }
                self.panelSource = source
                self.model.data = data
                // A page whose profile or lab is gone closes, with what it led to.
                if let gone = self.model.path.firstIndex(where: { route in
                    guard let name = route.profile else { return false }
                    guard let p = data.profiles.first(where: { $0.name == name }) else { return true }
                    switch route {
                    case .profile, .sendSession, .machine, .conflicts, .task, .sendWork: return false
                    case .provider(_, let v), .configure(_, let v): return p.slots[v] == nil
                    }
                }) {
                    self.model.path.removeSubrange(gone...)
                }
            }
        }
    }

    private enum CacheKey {
        static let porcelain = "panelCache.porcelain"
        static let sessions = "panelCache.sessions"
        static let pendingSetups = "pendingSetups"
    }
    private let defaults = UserDefaults.standard

    // Reads the CLI (slow, off the main thread) and saves what it said, so the
    // next launch can draw from it before the CLI has answered.
    // A failed read returns nil and the panel keeps what it has, rather than
    // replacing real profiles with an empty, first-run-looking one.
    /// The read, and what it was read from: CLI output and the local facts
    /// (terminals, desktop apps) that buildPanelData adds.
    private func loadPanelData() -> (PanelData, String)? {
        let porcelain = runCLI(["porcelain"])
        guard porcelain.status == 0 else { return nil }
        let sessions = runCLI(["sessions", "--porcelain", "--limit", "2"])
        let sessionText = sessions.status == 0 ? sessions.output : ""
        defaults.set(porcelain.output, forKey: CacheKey.porcelain)
        defaults.set(sessionText, forKey: CacheKey.sessions)
        let data = buildPanelData(porcelain: porcelain.output, sessions: sessionText)
        let source = [porcelain.output, sessionText, data.terminals.joined(separator: ","),
                      data.desktops.sorted().joined(separator: ",")].joined(separator: "\u{1F}")
        return (data, source)
    }

    // Everything else is local and fast enough to run on the main thread.
    private func buildPanelData(porcelain: String, sessions: String) -> PanelData {
        let snap = Snapshot.parse(porcelain)
        FleetWords.labs = Dictionary(snap.vendors.map { ($0.id, $0.label) }) { a, _ in a }
        let profiles = discoverProfiles(snap)
        let preferred = preferredTerminal.name
        let terminals = [preferred] + installedTerminals().map(\.name).filter { $0 != preferred }
        return PanelData(snapshot: snap,
                         profiles: profiles,
                         sessions: SessionInfo.parse(sessions),
                         terminals: terminals,
                         desktops: Set(snap.installedVendors.filter {
                             $0.desktop != "none" && !$0.desktopBundle.isEmpty
                                 && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.desktopBundle) != nil
                         }.map(\.id)))
    }

    // Quota is a network call per profile against a rate-limited endpoint the
    // labs' own CLIs also poll, so it runs beside the panel, is reused for 5
    // minutes per lab, and backs off to 15 after a 429. A lab whose read costs
    // something (Muse mints a key per read) is never polled: only an open, a
    // retry or a sign-in reads it. One fetch at a time: a fetch that becomes
    // due while another is in flight runs right after it, so a result read
    // before a sign-in never stands in for one after it.
    private var usageGeneration = 0
    private var usageFetchedAt: [String: Date] = [:]
    private var usageTTL: [String: TimeInterval] = [:]
    private var usageRefetch = false
    private var usageRefetchOnDemand = false
    private var usageSlowTimer: DispatchWorkItem?

    private func refreshUsage(force: Bool, onDemand: Bool = false) {
        guard let vendors = model.data?.quotaVendors.filter({ v in
            (onDemand || !v.readsOnDemand) && (force || usageFetchedAt[v.id].map {
                Date().timeIntervalSince($0) >= usageTTL[v.id, default: 300]
            } ?? true)
        }), !vendors.isEmpty else { return }
        if model.usageLoading {
            usageRefetch = true
            usageRefetchOnDemand = usageRefetchOnDemand || onDemand
            return
        }
        // Stamped when the read starts, so a call landing mid-read doesn't
        // queue the same labs again; a sign-in clears the stamps to force one.
        for v in vendors { usageFetchedAt[v.id] = Date() }
        let generation = usageGeneration
        model.usageLoading = true
        usageSlowTimer?.cancel()
        let slow = DispatchWorkItem { [weak self] in self?.model.usageSlow = true }
        usageSlowTimer = slow
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: slow)
        let profiles = model.data?.profiles.map(\.name) ?? []
        DispatchQueue.global(qos: .utility).async {
            let fresh = Dictionary(uniqueKeysWithValues: vendors.map { v in
                let r = self.runCLI(["best", "--json", "--vendor", v.id])
                return (v.id, (rows: r.status == 0 ? Usage.parseJSON(r.output, provider: v.id, longWindow: v.longWindow) : [:],
                               failed: r.status != 0))
            })
            DispatchQueue.main.async {
                guard generation == self.usageGeneration else { return }
                self.model.usageLoading = false
                self.usageSlowTimer?.cancel()
                self.model.usageSlow = false
                var usage = self.model.usage
                for (id, result) in fresh {
                    let rows = result.rows
                    self.usageTTL[id] = rows.values.contains { $0.note == .rateLimited } ? 900 : 300
                    usage[id] = Usage.merge(usage[id] ?? [:], rows, commandFailed: result.failed, profiles: profiles)
                }
                self.model.usage = usage
                self.model.refreshedAt = Date()
                if self.usageRefetch {
                    let onDemand = self.usageRefetchOnDemand
                    self.usageRefetch = false
                    self.usageRefetchOnDemand = false
                    self.refreshUsage(force: true, onDemand: onDemand)
                }
            }
        }
    }

    // n2agents://refresh — sent by the commands the panel starts in a terminal
    // (sign-in) when they finish, so the panel shows the result at once
    // instead of on the next open.
    // n2agents://login-done?profile=P&vendor=v — a setup sign-in's terminal
    // finished, successful or not; the setup window decides which.
    // n2agents://sessions — opens the sessions window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "n2agents" {
            if url.host == "reonboard-done" || url.host == "reonboard-failed" {
                guard model.resettingAccounts else { continue }
                completeAccountReset(succeeded: url.host == "reonboard-done")
                continue
            }
            if url.host == "sessions" {
                showAllSessions()
                continue
            }
            if url.host == "login-done",
               let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
               let profile = items.first(where: { $0.name == "profile" })?.value,
               let vendor = items.first(where: { $0.name == "vendor" })?.value,
               setup?.model.profile == profile {
                setup?.loginFinished(vendor: vendor)
            }
            loginsChanged()
        }
    }

    func playUsageWeek() {
        dismissPanel()
        quotaToast.playWeek()
    }

    func retryUsage() {
        refreshUsage(force: true, onDemand: true)
    }

    // MARK: - Profile discovery

    // The CLI is the only thing that knows what a profile is: one porcelain
    // call per refresh, and the panel renders whatever it reports.
    private func snapshot() -> Snapshot {
        let r = runCLI(["porcelain"])
        return r.status == 0 ? Snapshot.parse(r.output) : Snapshot.empty
    }

    private func discoverProfiles(_ snap: Snapshot? = nil) -> [Profile] {
        (snap ?? snapshot()).profiles.map { row in
            Profile(name: row.name, running: row.desktopRunning, slots: row.slots)
        }
    }

    private func profile(named name: String) -> Profile? {
        discoverProfiles().first { $0.name == name }
    }

    // An update waiting shows as an arrow beside the icon, in the menu bar's
    // own ink, so it's seen without opening the panel.
    private func refreshStatusTitle() {
        let waiting = updateStatus == .available
        statusItem.button?.toolTip = waiting ? "N2 Agents — update available"
            : UpdateChannel.isQABuild ? "N2 Agents — QA build" : nil
        let suffix = waiting ? "↑" : ""
        // A plain title, not an attributed one: only that takes the menu bar's ink.
        statusItem.button?.font = .systemFont(ofSize: 12, weight: .bold)
        statusItem.button?.title = (statusItem.button?.image == nil ? "🤖" : "") + suffix
    }

    // MARK: - Sparkle update channel

    func setUpdateChannel(_ channel: UpdateChannel) {
        UserDefaults.standard.set(channel.rawValue, forKey: UpdateChannel.preferenceKey)
        updateStatus = nil
#if canImport(Sparkle)
        if !UpdateChannel.isQABuild { updaterController.updater.resetUpdateCycle() }
#endif
    }

    // MARK: - Global shortcut

    var panelShortcut: String? { Shortcut.load()?.display }

    func setPanelShortcut() {
        dismissPanel()
        let current = Shortcut.load()
        let recorder = ShortcutRecorderView(current: current)
        let dialog = NSAlert()
        dialog.messageText = "Keyboard shortcut"
        dialog.informativeText = "Press a combination with ⌘, ⌥ or ⌃. It opens N2 Agents from any app — handy when the icon is hidden behind the notch."
        dialog.accessoryView = recorder
        dialog.addButton(withTitle: "Save")
        dialog.addButton(withTitle: "Clear")
        dialog.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        dialog.window.initialFirstResponder = recorder
        let choice = dialog.runModal()
        guard choice != .alertThirdButtonReturn else { return }

        let picked = choice == .alertFirstButtonReturn ? (recorder.recorded ?? current) : nil
        guard hotKey.register(picked) else {
            hotKey.register(current)
            alert("Shortcut unavailable", "\(picked?.display ?? "That shortcut") is already taken by another app. Pick a different one.")
            return
        }
        Shortcut.save(picked)
    }

    func checkForUpdates() {
        dismissPanel()
        if UpdateChannel.isQABuild {
            alert("QA build", "This is a local QA build. It never updates itself; rebuild it to pick up changes.")
            return
        }
#if canImport(Sparkle)
        updaterController.checkForUpdates(nil)
#else
        alert("Updates unavailable", "This development build was compiled without Sparkle.")
#endif
    }

#if canImport(Sparkle)
    // raw.githubusercontent.com caches each encoding of the feed for 5
    // minutes, and the gzip copy Sparkle asks for can lag a release: "up to
    // date" while an update sits published. A query unique to the check
    // skips the cache.
    func feedURLString(for updater: SPUUpdater) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: UpdateChannel.selected().feedInfoKey) as? String)
            .map { "\($0)?t=\(Int(Date().timeIntervalSince1970))" }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        [UpdateChannel.selected().rawValue]
    }

    // Shown in the panel footer, never as a dialog: Sparkle already reports
    // failures of checks the user asked for, and a background check has no
    // business interrupting anyone. "No update" arrives here too — not a failure.
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let e = error as NSError
        guard !(e.domain == SUSparkleErrorDomain && e.code == Int(SUError.noUpdateError.rawValue)) else { return }
        updateStatus = .failed(e.localizedDescription)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateStatus = .upToDate
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateStatus = .available
    }
#endif

    // MARK: - Actions

    func reportBug() {
        dismissPanel()
        let body = """
        ## What happened?
        <!-- Tell us what went wrong. -->

        ## What did you expect?
        <!-- Tell us what you expected to happen. -->

        ## Steps to reproduce
        1.

        ## Environment
        - N2 Agents version: \(currentVersion)
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        guard var components = URLComponents(string: newIssueURL) else {
            alert("Couldn't open GitHub Issues", "Visit github.com/noisyneighborstudio/n2-agents/issues to report the bug.")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "title", value: "[Bug] "),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            alert("Couldn't open GitHub Issues", "Visit github.com/noisyneighborstudio/n2-agents/issues to report the bug.")
            return
        }
    }

    // Every profile opens the stock app as its own instance; the CLI starts
    // it, or brings forward the one already open. Off the main thread: it
    // waits on `open`.
    func openDesktop(profile name: String, vendor id: String) {
        guard let v = model.data?.snapshot.vendor(id) else { return }
        dismissPanel()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let r = self.runCLI(["desktop", name, "--vendor", id])
            DispatchQueue.main.async {
                if r.status != 0 { self.alert("Couldn't open \(v.desktopName)", r.output) }
                self.refreshPanel()
            }
        }
    }

    // MARK: - agents CLI (single implementation of profile side effects)

    var cliPath: String { scriptsDir + "/agents" }

    /// With a timeout, a command that has not exited by then is stopped and
    /// reported as failed, so a hung read cannot hold its caller or stack up.
    @discardableResult
    func runCLI(_ args: [String], timeout: TimeInterval? = nil) -> (status: Int32, output: String) {
        if let timeout {
            return FleetSettingsLoader.bounded([cliPath] + args, environment: Self.scriptEnvironment, timeout: timeout)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [cliPath] + args
        task.environment = Self.scriptEnvironment
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return (-1, error.localizedDescription) }
        // Read before waiting: output past the pipe's 64 KB buffer blocks the
        // CLI until someone reads it, so waiting first never returns.
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        return (task.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func setActive(profile name: String, vendor: String?) {
        var args = ["use", name]
        if let id = vendor { args += ["--vendor", id] }
        let r = runCLI(args)
        if r.status != 0 {
            dismissPanel()
            alert("Couldn't switch active profile", r.output)
        }
        refreshPanel()
    }

    // Always go through the CLI rather than composing an env-var prefix here:
    // it alone knows how each vendor is pinned.
    private func sessionCommand(profile: String, vendor: Vendor) -> String {
        "\"\(cliPath)\" run \(profile) --vendor \(vendor.id)"
    }

    // terminal nil = the preferred one.
    func openSession(profile: String, vendor id: String, terminal: String?) {
        guard let v = model.data?.snapshot.vendor(id) else { return }
        dismissPanel()
        let spec = terminal.flatMap { name in terminalSpecs.first { $0.name == name } } ?? preferredTerminal
        launchSession(sessionCommand(profile: profile, vendor: v), slug: "\(profile)-\(id)", in: spec)
    }

    @MainActor private lazy var signInCoordinator = SignInCoordinator()

    func signIn(profile: String, vendor: String, confirm: Bool) {
        startSignIn(profile: profile, vendor: vendor, confirmLegacy: confirm)
    }

    private func startSignIn(profile: String, vendor: String, confirmLegacy: Bool,
                             setup: Bool = false, copyOnly: Bool = false) {
        let cli = cliPath, environment = Self.scriptEnvironment
        let label = model.data?.snapshot.vendor(vendor)?.label ?? vendor
        if !copyOnly { dismissPanel() }
        Task { @MainActor in await signInCoordinator.perform(profile: profile, vendor: vendor,
            confirmLegacy: confirmLegacy, copyOnly: copyOnly,
            run: { SignInPlan.run(cli: cli, environment: environment, args: $0) },
            confirm: { plan in
                let alert = plan.alert(profile: profile, label: label)
                NSApp.activate(ignoringOtherApps: true)
                return alert.runModal() == .alertFirstButtonReturn
            }, finish: { plan in
                let command = plan.command(cli: cli)
                if copyOnly {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    return
                }
                self.launchSession(plan.terminalCommand(cli: cli, profile: profile, vendor: vendor, setup: setup),
                                   slug: "\(profile)-\(vendor)-login", in: self.preferredTerminal)
            }, cancelled: {
                if setup && !copyOnly && self.setup?.model.profile == profile { self.setup?.loginFinished(vendor: vendor) }
            }, fail: { message in
                if setup && !copyOnly && self.setup?.model.profile == profile { self.setup?.loginFinished(vendor: vendor) }
                let alert = NSAlert(); alert.messageText = "Sign-in unavailable"
                alert.informativeText = message; alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true); alert.runModal()
            })
        }
    }

    func copyCommand(profile: String, vendor: String) {
        Clipboard.copy(Clipboard.command(profile: profile, vendor: vendor))
    }

    func copyPath(_ path: String) {
        Clipboard.copy(path)
    }

    func revealPath(_ path: String) {
        dismissPanel()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // Add a lab to an existing profile: one slot dir, plus its PATH shim.
    func addVendor(profile name: String) {
        dismissPanel()
        openSetup(profile: name, isNew: false, resume: nil)
    }

    func finishSetup(profile: String) {
        guard !model.resettingAccounts else { return }
        dismissPanel()
        accountSetupQueue.removeAll { $0 == profile }
        openSetup(profile: profile, isNew: false, resume: model.pendingSetups[profile],
                  reonboarding: !accountSetupQueue.isEmpty)
    }

    // MARK: - Profile setup window

    private var setup: ProfileSetup?
    private var accountSetupQueue: [String] = []
    private var accountSignOut: AccountSignOut?

    private func completeAccountReset(succeeded: Bool) {
        model.resettingAccounts = false
        clearAccountCache()
        refreshPanel()
        if succeeded {
            openNextAccountSetup()
        } else {
            alert("Sign-out did not finish", "Check the sign-out window for details, then try again. Profiles remain marked as needing setup.")
        }
    }

    private func clearAccountCache() {
        refreshGeneration += 1
        usageGeneration += 1
        model.usage = [:]
        model.usageLoading = false
        model.usageSlow = false
        usageSlowTimer?.cancel()
        usageFetchedAt.removeAll()
        usageTTL.removeAll()
        usageRefetch = false
        usageRefetchOnDemand = false
        defaults.removeObject(forKey: CacheKey.porcelain)
    }

    private func openNextAccountSetup() {
        while !accountSetupQueue.isEmpty {
            let profile = accountSetupQueue.removeFirst()
            guard let labs = model.pendingSetups[profile], !labs.isEmpty else { continue }
            openSetup(profile: profile, isNew: false, resume: labs, reonboarding: true)
            return
        }
        refreshPanel()
    }

    private func openSetup(profile: String, isNew: Bool, resume: [String]?, reonboarding: Bool = false) {
        if let setup, setup.model.profile == profile {
            setup.bringToFront()
            return
        }
        setup?.finishLater()
        let snap = model.data?.snapshot ?? snapshot()
        let window = ProfileSetup(profile: profile, isNew: isNew, snapshot: snap, resume: resume, host: self)
        window.onClose = { [weak self, weak window] in
            if self?.setup === window { self?.setup = nil }
            self?.refreshPanel()
        }
        if reonboarding {
            window.onContinue = { [weak self, weak window] in
                guard let self else { return }
                // Cursor has one account for the machine. Keep the login just completed.
                if window?.model.finishedLabs.contains("cursor") == true {
                    for name in self.accountSetupQueue {
                        let labs = self.model.pendingSetups[name]?.filter { $0 != "cursor" } ?? []
                        self.setupPending(profile: name, labs: labs.isEmpty ? nil : labs)
                    }
                }
                window?.finishLater()
                self.openNextAccountSetup()
            }
        }
        setup = window
        window.show()
    }

    // Slots are directories, so creating them is instant.
    func setupCreate(profile: String, vendors: [String]) -> String? {
        let r = runCLI(["new", profile, "--vendors", vendors.joined(separator: ",")])
        return r.status == 0 ? nil : r.output
    }

    func setupAuthed(profile: String) -> [String: Bool]? {
        let r = runCLI(["authed", profile])
        return Snapshot.setupAuthentication(status: r.status, output: r.output)
    }

    func setupStartLogin(profile: String, vendor: String) -> NativeAuthSession? {
        // Codex may be owner-managed, and only its sign-in plan knows the
        // owner route; that runs in a terminal and reports back through
        // n2agents://login-done.
        if vendor == "codex" {
            startSignIn(profile: profile, vendor: vendor, confirmLegacy: false, setup: true)
            return nil
        }
        return NativeAuthSession(executable: "/bin/sh",
                                 arguments: [cliPath, "login", profile, "--vendor", vendor],
                                 environment: Self.scriptEnvironment)
    }

    func setupCopyLoginCommand(profile: String, vendor: String) {
        startSignIn(profile: profile, vendor: vendor, confirmLegacy: false, copyOnly: true)
    }

    func setupPending(profile: String, labs: [String]?) {
        model.pendingSetups[profile] = labs
        defaults.set(model.pendingSetups, forKey: CacheKey.pendingSetups)
    }

    func setupLoginLanded(profile: String) {
        loginsChanged()
    }

    // A login changed: re-read the panel and every lab's usage now, not when
    // the cached reading expires.
    private func loginsChanged() {
        usageFetchedAt.removeAll()
        refreshPanel()
        refreshUsage(force: false, onDemand: true)
    }

    func setupOpen(profile: String, vendor: String) {
        openSession(profile: profile, vendor: vendor, terminal: nil)
    }

    func setupMakeActive(profile: String) {
        setActive(profile: profile, vendor: nil)
    }

    var setupTerminalName: String { preferredTerminal.name }

    private func installedTerminals() -> [TerminalSpec] {
        terminalSpecs.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil }
    }

    private var preferredTerminal: TerminalSpec {
        let saved = UserDefaults.standard.string(forKey: "preferredTerminal")
        let installed = installedTerminals()
        return installed.first { $0.bundleId == saved } ?? installed.first ?? terminalSpecs[0]
    }

    func setPreferredTerminal(_ name: String) {
        guard let spec = terminalSpecs.first(where: { $0.name == name }) else { return }
        UserDefaults.standard.set(spec.bundleId, forKey: "preferredTerminal")
        refreshPanel()
    }

    private func launchSession(_ cmd: String, slug: String, in term: TerminalSpec) {
        switch term.kind {
        case .appleScript(let sourceBuilder):
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", sourceBuilder(cmd)]
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus != 0 { automationDeniedAlert(appName: term.name) }
            } catch {
                automationDeniedAlert(appName: term.name)
            }
        case .openArgs(let argsBuilder):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: term.bundleId) else { return }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            cfg.activates = true
            cfg.arguments = argsBuilder(cmd)
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { runningApp, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self.alert("Couldn't open \(term.name)", error.localizedDescription)
                    } else {
                        // A second app instance can open behind the existing one —
                        // bring the new window forward explicitly.
                        runningApp?.activate(options: [.activateIgnoringOtherApps])
                    }
                }
            }
        case .warpLaunchConfig:
            // Warp has no AppleScript/CLI-args path; its supported mechanism is a
            // launch-configuration yaml opened via the warp:// URL scheme.
            let dir = home + "/.warp/launch_configurations"
            let fileName = "n2agents-\(slug).yaml"
            let yaml = """
            name: n2agents-\(slug)
            windows:
              - tabs:
                  - title: \(slug)
                    layout:
                      cwd: "\(home)"
                      commands:
                        - exec: >-
                            \(cmd)
            """
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try yaml.write(toFile: dir + "/" + fileName, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(URL(string: "warp://launch/\(fileName)")!)
            } catch {
                alert("Couldn't open Warp", error.localizedDescription)
            }
        }
    }

    // Name first; the setup window then picks its labs and signs in to each.
    func newProfile() {
        dismissPanel()
        // Named, it goes on to the setup window; otherwise back to the panel.
        var named = false
        defer { if !named { returnToPanel() } }
        let alert = NSAlert()
        alert.messageText = "New profile"
        alert.informativeText = "Name, letters/numbers only (e.g. Work). Next you’ll pick the labs it holds and sign in to each."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ ($0.isLetter || $0.isNumber) && $0.isASCII }) else {
            self.alert("Invalid name", "Use ASCII letters and numbers only, e.g. Work or Client2.")
            return
        }
        if ["as", "default"].contains(name.lowercased()) {
            self.alert("Reserved name", "“\(name)” conflicts with a built-in N2 Agents command. Pick another name.")
            return
        }
        if model.data?.profiles.contains(where: { $0.name.lowercased() == name.lowercased() }) == true {
            self.alert("Profile exists", "“\(name)” is already a profile. Pick another name, or delete the existing one first.")
            return
        }
        named = true
        openSetup(profile: name, isNew: true, resume: nil)
    }

    func deleteProfile(_ name: String) {
        dismissPanel()
        defer { returnToPanel() }
        guard let p = profile(named: name) else { return }
        if p.running {
            alert("“\(p.name)” is open", "Quit this profile’s desktop apps first, then delete it.")
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Delete profile “\(p.name)”?"
        confirm.informativeText = "This removes its logins, CLI config and desktop app data. It can't be undone."
        let delete = confirm.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        confirm.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let result = runCLI(["delete", p.name, "--yes"])
        if result.status != 0 {
            alert("Delete failed", result.output)
        }
        refreshPanel()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Sessions (listed, moved and resumed through the CLI)

    // Resume through the CLI so the pinning rules stay in one place.
    private func resumeCommand(_ s: SessionInfo, in profile: String) -> String {
        let invoke = "\"\(cliPath)\" run \(profile) --vendor \(s.vendor) --start-from-session=\(s.sessionID)"
        return s.cwd.map { "cd \"\($0)\" && \(invoke)" } ?? invoke
    }

    func resumeSession(_ s: SessionInfo) {
        dismissPanel()
        sessionsWindow?.dismiss()
        launchSession(resumeCommand(s, in: s.profile), slug: "\(s.profile)-\(s.vendor)", in: preferredTerminal)
    }

    func copyResumeCommand(_ s: SessionInfo) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(resumeCommand(s, in: s.profile), forType: .string)
    }

    @MainActor private lazy var sessionTransferCoordinator = SessionTransferCoordinator()

    /// Send Session is a page, not an alert: from the sessions window (or
    /// anywhere outside the panel) it opens the panel on that page.
    func sendSession(_ session: SessionInfo) {
        sessionsWindow?.dismiss()
        if model.sendDrafts[session.id] == nil { model.sendDrafts[session.id] = SendDraft(cwd: session.cwd ?? "") }
        model.path = [.sendSession(session.id)]
        model.closedAt = nil
        if !panel.isShowing { togglePanel() }
    }

    /// The page's choice, sent through the same coordinator and checks as
    /// before; the outcome lands on the draft rather than in an alert.
    func sendSession(_ session: SessionInfo, to peerID: String, cwd: String) {
        let cli = cliPath, environment = Self.scriptEnvironment
        model.sendDrafts[session.id, default: SendDraft(cwd: cwd)].state = .sending
        Task { @MainActor in
            await sessionTransferCoordinator.perform(thread: session.sessionID, vendor: session.vendor,
                run: { SignInPlan.run(cli: cli, environment: environment, args: $0) },
                // The coordinator re-reads the approved machines; the choice
                // must be one of those, matched by identity.
                choose: { peers in peers.first { $0.id == peerID }.map { ($0, cwd) } },
                finish: { message in self.model.sendDrafts[session.id]?.state = .sent(message) },
                fail: { message in self.model.sendDrafts[session.id]?.state = .failed(message) })
            if case .sending? = self.model.sendDrafts[session.id]?.state {
                self.model.sendDrafts[session.id]?.state = .failed(String(localized: "That machine is no longer approved.",
                                                                          comment: "Send Session: the chosen peer vanished"))
            }
        }
    }

    // The transcript moves; its place in the list doesn't (mv keeps the
    // mtime), so the row just changes hands when the lists re-read.
    func moveSession(_ s: SessionInfo, to profile: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let r = self.runCLI(["transfer", s.sessionID, "--from", s.profile, "--to", profile, "--vendor", s.vendor])
            DispatchQueue.main.async {
                if r.status != 0 {
                    self.dismissPanel()
                    self.alert("Couldn't move the session to “\(profile)”", r.output)
                }
                self.refreshPanel()
                self.loadAllSessions()
            }
        }
    }

    // The panel shows two. The rest live in a window of their own, at a fixed
    // size: it opens at the size it will stay, whatever the list or a search
    // does to the number of rows.
    func showAllSessions() {
        dismissPanel()
        if model.allSessions.isEmpty { model.allSessions = model.data?.sessions ?? [] }
        if sessionsWindow == nil {
            sessionsWindow = GlassWindow(rootView: SessionsWindowView(model: model, actions: self),
                                         behavior: .floating)
            sessionsWindow?.identifier = SessionsWindowView.identifier
        }
        sessionsWindow?.present()
        loadAllSessions()
    }

    func closeSessions() {
        sessionsWindow?.dismiss()
    }

    func showSettings() {
        dismissPanel()
        if settingsWindow == nil {
            settingsWindow = GlassWindow(rootView: SettingsWindowView(model: model, actions: self,
                                                                          fleet: AnyView(FleetSettingsSection(model: model, actions: self))),
                                         behavior: .floating)
            settingsWindow?.identifier = NSUserInterfaceItemIdentifier("dev.sethwebster.n2agents.settings")
        }
        settingsWindow?.present()
    }

    func closeSettings() {
        settingsWindow?.dismiss()
    }

    func reonboardAccounts() {
        guard !model.resettingAccounts, let snapshot = model.data?.snapshot else { return }
        let ask = NSAlert()
        ask.messageText = "Sign out of all accounts and set up again?"
        ask.informativeText = "This signs out every listed profile, including Default, then opens the setup window to guide you through each profile again. Profiles, settings and session history stay in place. Close running agent sessions first. Browser accounts stay signed in, so choose the intended account at each login. Cursor uses one shared account across profiles."
        ask.addButton(withTitle: "Sign Out and Set Up Again")
        ask.addButton(withTitle: "Cancel")
        ask.alertStyle = .warning
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        setup?.finishLater()
        closeSettings()
        accountSetupQueue = snapshot.profiles.filter { !$0.slots.isEmpty }.map(\.name)
        for profile in snapshot.profiles where !profile.slots.isEmpty {
            setupPending(profile: profile.name, labs: snapshot.installedVendors.map(\.id).filter { profile.slots[$0] != nil })
        }
        model.resettingAccounts = true
        clearAccountCache()
        let session = NativeAuthSession(executable: "/bin/sh",
                                        arguments: [cliPath, "reonboard", "--logout-only", "--yes"],
                                        environment: Self.scriptEnvironment)
        let controller = AccountSignOut(session: session)
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            if self.accountSignOut === controller { self.accountSignOut = nil }
            if self.model.resettingAccounts {
                self.model.resettingAccounts = false
                self.clearAccountCache()
                self.refreshPanel()
            }
        }
        session.onFinish = { [weak self, weak controller] status in
            if status == 0 { controller?.close() }
            self?.completeAccountReset(succeeded: status == 0)
        }
        accountSignOut = controller
        controller.show()
    }

    // Reads logins fresh, then queues only the profiles missing one through
    // the same setup window reset uses.
    func signInMissingAccounts() {
        guard !model.resettingAccounts else { return }
        closeSettings()
        DispatchQueue.global(qos: .userInitiated).async {
            let porcelain = self.runCLI(["porcelain"])
            DispatchQueue.main.async {
                guard !self.model.resettingAccounts else { return }
                guard porcelain.status == 0 else {
                    self.alert("Couldn't check sign-ins", porcelain.output)
                    return
                }
                let missing = Snapshot.parse(porcelain.output).missingSignIns(pending: self.model.pendingSetups)
                guard !missing.isEmpty else {
                    self.alert("All accounts are signed in", "Every listed profile has a login for each of its labs.")
                    return
                }
                self.setup?.finishLater()
                for entry in missing { self.setupPending(profile: entry.profile, labs: entry.labs) }
                self.accountSetupQueue = missing.map(\.profile)
                self.openNextAccountSetup()
            }
        }
    }

    func installCLI() -> String {
        if Bundle.main.object(forInfoDictionaryKey: "N2FleetQA") as? Bool == true {
            return "Fleet QA uses its bundled CLI; the primary CLI stays installed."
        }
        let source = URL(fileURLWithPath: cliPath).standardizedFileURL
        let agentAs = scriptsDir + "/agent-as"
        guard fm.isExecutableFile(atPath: source.path), fm.isExecutableFile(atPath: agentAs) else {
            return "The CLI files are missing from this app bundle. Reinstall N2 Agents and try again."
        }

        let allowed = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"]
        let pathDirs = Self.scriptPATH.split(separator: ":").map(String.init)
        var candidates = pathDirs.filter { allowed.contains($0) }
        candidates += allowed.filter { !candidates.contains($0) }

        for directory in candidates {
            let dir = URL(fileURLWithPath: directory, isDirectory: true)
            if !fm.fileExists(atPath: directory), directory == home + "/.local/bin" {
                do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
                catch { continue }
            }
            guard fm.isWritableFile(atPath: directory) else { continue }

            let link = dir.appendingPathComponent("agents")
            let linkExists = fm.fileExists(atPath: link.path)
                || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
            if linkExists {
                if let target = try? fm.destinationOfSymbolicLink(atPath: link.path),
                   URL(fileURLWithPath: target, relativeTo: dir).standardizedFileURL == source {
                    do {
                        try fm.createDirectory(atPath: home + "/.n2-agents", withIntermediateDirectories: true)
                        try "\(directory)\n".write(toFile: home + "/.n2-agents/.bin-dir", atomically: true, encoding: .utf8)
                    } catch {
                        return "CLI link exists, but its install record couldn't be written: \(error.localizedDescription)"
                    }
                    let result = runCLI(["shims"])
                    return result.status == 0 ? "CLI is installed at \(link.path)." : "CLI is installed; profile commands need attention: \(result.output)"
                }
                continue
            }

            do {
                try fm.createSymbolicLink(at: link, withDestinationURL: source)
                try fm.createDirectory(atPath: home + "/.n2-agents", withIntermediateDirectories: true)
                try "\(directory)\n".write(toFile: home + "/.n2-agents/.bin-dir", atomically: true, encoding: .utf8)
                let result = runCLI(["shims"])
                return result.status == 0 ? "CLI installed at \(link.path). Restart your terminal to use it." : "CLI installed; profile commands need attention: \(result.output)"
            } catch {
                return "Couldn't install the CLI in \(directory): \(error.localizedDescription)"
            }
        }
        return "No writable PATH directory is available. Make /opt/homebrew/bin, /usr/local/bin, or ~/.local/bin writable, then try again."
    }

    // Every session, not a page of them: search runs over the list in memory,
    // and the CLI's cache makes the whole list about as cheap as fifty. Only
    // the newest read lands, like refreshPanel.
    private var sessionsGeneration = 0

    private func loadAllSessions() {
        sessionsGeneration += 1
        let generation = sessionsGeneration
        model.sessionsLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let r = self.runCLI(["sessions", "--porcelain"])
            DispatchQueue.main.async {
                guard generation == self.sessionsGeneration else { return }
                self.model.sessionsLoading = false
                if r.status == 0 { self.model.allSessions = SessionInfo.parse(r.output) }
            }
        }
    }

    // MARK: - Terminal + alerts

    // Runs in Terminal.app so script output/progress is visible to the user.
    func runInTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                automationDeniedAlert()
            }
        } catch {
            automationDeniedAlert()
        }
    }

    private func automationDeniedAlert(appName: String = "Terminal") {
        let alert = NSAlert()
        alert.messageText = "N2 Agents can't control \(appName)"
        alert.informativeText = "macOS blocked N2 Agents from controlling \(appName). Enable it under Privacy & Security → Automation → N2 Agents → \(appName), then try again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
    }

    func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
