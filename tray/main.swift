import AppKit
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
// Resident duties beyond the panel:
//  - Auto-repatch: detects Claude.app updates (version drift vs clones) and
//    silently rebuilds idle clones in the background.
//  - Self-update: delegates signed automatic and manual updates to Sparkle.

// A profile as the panel needs it: the CLI's porcelain row plus the two
// Claude-desktop paths the clone/delete/reveal actions operate on.
struct Profile {
    let name: String
    let hasApp: Bool
    let running: Bool
    let dataDir: String
    let configDir: String
    /// vendor id -> "active" | "ok"; absent means no slot for that vendor.
    let slots: [String: String]

    var isDefault: Bool { name == "Default" }
    func isActive(for vendor: String) -> Bool { slots[vendor] == "active" }
}

// Data source for the session picker table (cell-based, single column).
final class SessionListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var rows: [String] = []
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        rows[row]
    }
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
    /// Decides which fleet notices still deserve a desktop banner. The feed is
    /// durable and re-read every refresh, so without it a finished task would
    /// re-announce itself every three minutes.
    var announcer = FleetAnnouncer()
    // Built on first open: it anchors to the status item's button.
    private lazy var panel = GlassWindow(rootView: PanelView(model: model, actions: self),
                                         behavior: .transient(anchor: statusItem.button!))
    private let fm = FileManager.default
    private let home = NSHomeDirectory()
    private var configRoot: String { home + "/.n2-agents" }
    private let claudeBundleID = "com.anthropic.claudefordesktop"
    private let newIssueURL = "https://github.com/noisyneighborstudio/n2-agents/issues/new"

    private var repatchInFlight = Set<String>() {
        didSet { model.repatching = repatchInFlight }
    }
    private var appsDirSource: DispatchSourceFileSystemObject?
    private var repatchDebounce: DispatchWorkItem?
#if canImport(Sparkle)
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
    )
#endif

    var autoRepatch: Bool {
        UserDefaults.standard.object(forKey: "autoRepatch") as? Bool ?? true
    }

    // Scripts live in the bundle's Resources; fall back to the source tree when
    // running the bare dev binary.
    private var scriptsDir: String {
        if let r = Bundle.main.resourcePath, fm.fileExists(atPath: r + "/make-claude-profile.sh") {
            return r
        }
        return home + "/Development/n2-agents"
    }

    // Claude Desktop is not always in /Applications: a per-user install lands in
    // ~/Applications, and the user can point us at any bundle via "Locate Claude
    // Desktop…". Clones carry a suffixed bundle id, so the base id never matches one.
    private var claudeAppPath: String? {
        if let saved = UserDefaults.standard.string(forKey: "claudeAppPath"),
           fm.fileExists(atPath: saved + "/Contents") {
            return saved
        }
        for candidate in ["/Applications/Claude.app", home + "/Applications/Claude.app"]
        where fm.fileExists(atPath: candidate + "/Contents") {
            return candidate
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID)?.path
    }

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let r = Bundle.main.resourcePath, let icon = NSImage(contentsOfFile: r + "/n2agents.icns") {
            icon.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = icon
            statusItem.button?.imagePosition = .imageLeft
        } else {
            statusItem.button?.title = "🤖"
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)


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
        Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in self?.refreshPanel() }
        // The fleet read runs on its own cadence: task state and notices move
        // between panel opens, and a banner that waits three minutes for the
        // next profile read is not a notification.
        refreshFleet()
        Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in self?.refreshFleet() }

        // Auto-repatch: event-driven — watch /Applications for bundle swaps
        // (Claude's updater renames the new version into place, which modifies
        // the directory). A 6h timer is only a fallback for missed events.
        startWatchingApplications()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.autoRepatchTick() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in self.autoRepatchTick() }

        // Keep claude-as / claude-<profile> on PATH in step with the profile
        // list — real executables, so apps and scripts get them too, and
        // upgrades from a shell-function-only version heal themselves.
        DispatchQueue.global(qos: .utility).async { self.runCLI(["shims"]) }

#if canImport(Sparkle)
        // Sparkle owns automatic scheduling and signature verification. Both
        // automatic and manual checks obtain their feed from the delegate below.
        _ = updaterController
        updaterController.updater.automaticallyChecksForUpdates = true
#endif
    }

    // MARK: - Panel (re-read every time it opens)

    @objc private func togglePanel() {
        if panel.isShowing {
            panel.dismiss()
            return
        }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { model.presented = false }
        // Sized from the already-loaded content, so the first frame is the
        // finished panel, not an empty one that grows into place.
        panel.present()
        DispatchQueue.main.async { self.model.presented = true }
        refreshPanel()
        refreshFleet()
    }

    // Anything that opens a window, dialog or terminal closes the panel first:
    // a transient panel would otherwise vanish under it mid-click.
    func dismissPanel() {
        panel.dismiss()
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
                guard generation == self.refreshGeneration, let data else { return }
                self.model.data = data
                // A setup finished outside the window (its terminal, or by
                // hand) stops being pending once no lab is known signed out.
                for (profile, labs) in self.model.pendingSetups where self.setup?.model.profile != profile
                    && !labs.contains(where: { data.snapshot.signedIn[profile]?[$0] == false }) {
                    self.setupPending(profile: profile, labs: nil)
                }
                if let s = self.model.selection,
                   data.profiles.first(where: { $0.name == s.profile })?.slots[s.vendor] == nil {
                    self.model.selection = nil
                }
                self.updateStatusTitle(staleExists: !data.staleClones.isEmpty)
                self.refreshUsage(force: false)
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
    private func loadPanelData() -> PanelData? {
        let porcelain = runCLI(["porcelain"])
        guard porcelain.status == 0 else { return nil }
        let sessions = runCLI(["sessions", "--porcelain", "--limit", "2"])
        let sessionText = sessions.status == 0 ? sessions.output : ""
        defaults.set(porcelain.output, forKey: CacheKey.porcelain)
        defaults.set(sessionText, forKey: CacheKey.sessions)
        return buildPanelData(porcelain: porcelain.output, sessions: sessionText)
    }

    // Everything else is local and fast enough to run on the main thread.
    private func buildPanelData(porcelain: String, sessions: String) -> PanelData {
        let snap = Snapshot.parse(porcelain)
        let profiles = discoverProfiles(snap)
        let desktopVersion = claudeAppPath.flatMap(bundleVersion)
        var stale: [String: String] = [:]
        for p in profiles where isStale(p) {
            stale[p.name] = bundleVersion("/Applications/Claude-\(p.name).app")
        }
        let preferred = preferredTerminal.name
        let terminals = [preferred] + installedTerminals().map(\.name).filter { $0 != preferred }
        return PanelData(snapshot: snap,
                         profiles: profiles,
                         desktopVersion: desktopVersion,
                         staleClones: stale,
                         sessions: SessionInfo.parse(sessions),
                         terminals: terminals,
                         launchDesktops: Set(snap.installedVendors.filter {
                             $0.desktop == "launch" && !$0.desktopBundle.isEmpty
                                 && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.desktopBundle) != nil
                         }.map(\.id)))
    }

    // Quota is a network call per profile against a rate-limited endpoint the
    // labs' own CLIs also poll, so it runs beside the panel, is reused for 5
    // minutes, and backs off to 15 after a 429. One fetch at a time: a fetch
    // that becomes due while another is in flight runs right after it, so a
    // result read before a sign-in never stands in for one after it.
    private var usageFetchedAt: Date?
    private var usageRefetch = false
    private var usageTTL: TimeInterval = 300
    private var usageSlowTimer: DispatchWorkItem?

    private func refreshUsage(force: Bool) {
        guard let vendor = model.data?.quotaVendor else { return }
        let due = force || usageFetchedAt.map { Date().timeIntervalSince($0) >= usageTTL } ?? true
        guard due else { return }
        if model.usageLoading {
            usageRefetch = true
            return
        }
        model.usageLoading = true
        usageSlowTimer?.cancel()
        let slow = DispatchWorkItem { [weak self] in self?.model.usageSlow = true }
        usageSlowTimer = slow
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: slow)
        DispatchQueue.global(qos: .utility).async {
            let r = self.runCLI(["best", "--porcelain", "--vendor", vendor.id])
            DispatchQueue.main.async {
                self.model.usageLoading = false
                self.usageSlowTimer?.cancel()
                self.model.usageSlow = false
                self.usageFetchedAt = Date()
                let fresh = r.status == 0 ? Usage.parse(r.output) : [:]
                self.usageTTL = fresh.values.contains { $0.note == .rateLimited } ? 900 : 300
                self.model.usage = Usage.merge(self.model.usage, fresh)
                if self.usageRefetch {
                    self.usageRefetch = false
                    self.refreshUsage(force: true)
                }
            }
        }
    }

    // n2agents://refresh — sent by the commands the panel starts in a terminal
    // (sign-in) when they finish, so the panel shows the result at once
    // instead of on the next open.
    // n2agents://login-done?profile=P&vendor=v — a setup sign-in's terminal
    // finished, successful or not; the setup window decides which.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "n2agents" {
            if url.host == "login-done",
               let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
               let profile = items.first(where: { $0.name == "profile" })?.value,
               let vendor = items.first(where: { $0.name == "vendor" })?.value,
               setup?.model.profile == profile {
                setup?.loginFinished(vendor: vendor)
            }
            usageFetchedAt = nil
            refreshPanel()
        }
    }

    func retryUsage() {
        refreshUsage(force: true)
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
            Profile(name: row.name,
                    hasApp: row.name == "Default"
                        ? (claudeAppPath != nil)
                        : fm.fileExists(atPath: "/Applications/Claude-\(row.name).app"),
                    running: row.desktopRunning,
                    dataDir: row.name == "Default"
                        ? home + "/Library/Application Support/Claude"
                        : home + "/Library/Application Support/Claude-" + row.name,
                    configDir: row.name == "Default"
                        ? home + "/.claude"
                        : configRoot + "/" + row.name,
                    slots: row.slots)
        }
    }

    private func isRunning(_ profile: Profile) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "user-data-dir=" + profile.dataDir]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func profile(named name: String) -> Profile? {
        discoverProfiles().first { $0.name == name }
    }

    // MARK: - Auto-repatch (Claude.app updated -> rebuild idle clones)

    private func startWatchingApplications() {
        let fd = open("/Applications", O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleDebouncedRepatchCheck() }
        src.setCancelHandler { close(fd) }
        src.resume()
        appsDirSource = src
    }

    // Updates copy a large bundle over several seconds — wait for 30s of quiet
    // before checking versions, so we never clone a half-written Claude.app.
    private func scheduleDebouncedRepatchCheck() {
        repatchDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.autoRepatchTick() }
        repatchDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    // NSDictionary(contentsOfFile:) instead of Bundle(path:) — Bundle caches
    // Info.plist contents and would miss in-place updates.
    private func bundleVersion(_ appPath: String) -> String? {
        guard let d = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist") else { return nil }
        return (d["CFBundleShortVersionString"] as? String) ?? (d["CFBundleVersion"] as? String)
    }

    private func isStale(_ profile: Profile) -> Bool {
        guard profile.hasApp,
              let appPath = claudeAppPath,
              let src = bundleVersion(appPath),
              let clone = bundleVersion("/Applications/Claude-\(profile.name).app") else { return false }
        return src != clone
    }

    @objc private func autoRepatchTick() {
        let profiles = discoverProfiles()
        let stale = profiles.filter { isStale($0) }
        updateStatusTitle(staleExists: !stale.isEmpty)
        guard autoRepatch else { return }
        for p in stale where !isRunning(p) && !repatchInFlight.contains(p.name) {
            backgroundRepatch(p.name)
        }
    }

    private func backgroundRepatch(_ name: String) {
        repatchInFlight.insert(name)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [scriptsDir + "/repatch-claude-profiles.sh", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.terminationHandler = { t in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.repatchInFlight.remove(name)
                self.autoRepatchTickStatusOnly()
                if t.terminationStatus != 0 {
                    self.alert("Auto-repatch failed for “\(name)”",
                               "Claude updated but the profile couldn't be rebuilt automatically:\n\n\(String(out.suffix(600)))\n\nTry Re-patch All Clones Now from the N2 Agents settings menu, or file an issue.")
                }
            }
        }
        do {
            try task.run()
        } catch {
            repatchInFlight.remove(name)
        }
    }

    private func autoRepatchTickStatusOnly() {
        let stale = discoverProfiles().contains { isStale($0) }
        updateStatusTitle(staleExists: stale)
    }

    private func updateStatusTitle(staleExists: Bool) {
        let busy = !repatchInFlight.isEmpty
        let suffix = busy ? "⏳" : (staleExists ? "⬆️" : "")
        if statusItem.button?.image != nil {
            statusItem.button?.title = suffix
        } else {
            statusItem.button?.title = "🤖" + suffix
        }
    }

    func setAutoRepatch(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "autoRepatch")
        if on { autoRepatchTick() }
    }

    func repatchAll() {
        dismissPanel()
        runInTerminal("\"\(scriptsDir)/repatch-claude-profiles.sh\"")
    }

    // A clone that is running can't be rebuilt in place: offer to quit it, and
    // start the rebuild once it has actually exited.
    func rebuildClone(_ name: String) {
        let clonePath = "/Applications/Claude-\(name).app"
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == clonePath }
        guard !running.isEmpty else {
            backgroundRepatch(name)
            return
        }
        dismissPanel()
        let confirm = NSAlert()
        confirm.messageText = "Quit Claude-\(name) and rebuild it?"
        confirm.informativeText = "The clone is on an older Claude version. Its windows close; your login and data stay."
        confirm.addButton(withTitle: "Quit and Rebuild")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        var token: NSObjectProtocol?
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleURL?.path == clonePath,
                  !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == clonePath }) else { return }
            if let t = token { NSWorkspace.shared.notificationCenter.removeObserver(t) }
            token = nil
            self?.backgroundRepatch(name)
        }
        running.forEach { $0.terminate() }
    }

    func showCloneDetails() {
        guard let data = model.data else { return }
        let names = Set(data.staleClones.keys).union(repatchInFlight).sorted()
        let lines = names.map { name -> String in
            if repatchInFlight.contains(name) { return "\(name) — rebuilding" }
            let on = data.staleClones[name].map { "on \($0)" } ?? "behind"
            let running = data.profiles.first { $0.name == name }?.running == true
            return "\(name) — \(on), " + (running ? "waiting until it quits" : autoRepatch ? "queued" : "auto-repatch is off")
        }
        dismissPanel()
        alert("Claude \(data.desktopVersion ?? "") — clones behind", lines.joined(separator: "\n"))
    }

    // MARK: - Sparkle update channel

    func setUpdateChannel(_ channel: UpdateChannel) {
        UserDefaults.standard.set(channel.rawValue, forKey: UpdateChannel.preferenceKey)
        model.updateStatus = nil
#if canImport(Sparkle)
        updaterController.updater.resetUpdateCycle()
#endif
    }

    func checkForUpdates() {
        dismissPanel()
#if canImport(Sparkle)
        updaterController.checkForUpdates(nil)
#else
        alert("Updates unavailable", "This development build was compiled without Sparkle.")
#endif
    }

#if canImport(Sparkle)
    func feedURLString(for updater: SPUUpdater) -> String? {
        Bundle.main.object(forInfoDictionaryKey: UpdateChannel.selected().feedInfoKey) as? String
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
        model.updateStatus = .failed(e.localizedDescription)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        model.updateStatus = .upToDate
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        model.updateStatus = .available
    }
#endif

    // MARK: - Actions

    // The path is stored in this app's preferences; the agents CLI reads the same
    // key, so scripts and menu agree on where Claude Desktop lives.
    func locateClaude() {
        dismissPanel()
        let panel = NSOpenPanel()
        panel.message = "Select Claude.app"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        guard let id = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String,
              id == claudeBundleID else {
            alert("Not Claude Desktop", "“\((path as NSString).lastPathComponent)” isn't the Claude Desktop app. Pick Claude.app — a profile clone (Claude-<Name>.app) won't do.")
            return
        }
        UserDefaults.standard.set(path, forKey: "claudeAppPath")
        autoRepatchTick()
    }

    func downloadClaude() {
        dismissPanel()
        NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!)
    }

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

    func openDesktop(profile name: String, vendor id: String) {
        guard let v = model.data?.snapshot.vendor(id) else { return }
        dismissPanel()
        guard v.clonesDesktopApp else { openSharedDesktop(profile: name, vendor: v); return }
        guard name != "Default" else {
            guard let appPath = claudeAppPath else {
                alert("Claude Desktop not found", "Install it from claude.ai/download, or point N2 Agents at it with “Locate Claude Desktop…”.")
                return
            }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath),
                                               configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if repatchInFlight.contains(name) {
            alert("“\(name)” is repatching", "Claude updated and this profile is being rebuilt. It'll be back in a moment.")
            return
        }
        let url = URL(fileURLWithPath: "/Applications/Claude-\(name).app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil {
                DispatchQueue.main.async {
                    self.alert("Couldn't launch Claude-\(name)",
                               "The app may be mid-repatch or damaged. Try Re-patch All Clones Now from the N2 Agents settings menu.")
                }
            }
        }
    }

    // A `launch` lab's desktop app is one app for the whole Mac, signed in as
    // the lab's active profile — macOS doesn't pass env vars to apps it
    // launches, so it can't be pinned per profile. Opening it for another
    // profile therefore makes that profile active, asked first.
    private func openSharedDesktop(profile name: String, vendor v: Vendor) {
        var args = ["desktop", name, "--vendor", v.id]
        let active = model.data?.snapshot.profiles.first { $0.name == name }?.isActive(for: v.id) ?? false
        if !active {
            let ask = NSAlert()
            ask.messageText = "Open \(v.desktopName) as “\(name)”?"
            ask.informativeText = "\(v.desktopName) uses one \(v.label) login for the whole Mac. Opening it for “\(name)” makes “\(name)” the active profile for \(v.label), so plain \(v.label) sessions use it too."
            ask.addButton(withTitle: "Make Active and Open")
            ask.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard ask.runModal() == .alertFirstButtonReturn else { return }
            args.append("--switch")
        }
        let r = runCLI(args)
        if r.status != 0 { alert("Couldn't open \(v.desktopName)", r.output) }
        refreshPanel()
    }

    // MARK: - agents CLI (single implementation of profile side effects)

    var cliPath: String { scriptsDir + "/agents" }

    @discardableResult
    func runCLI(_ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [cliPath] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return (-1, error.localizedDescription) }
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (task.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Switching a swap vendor rewrites its one global config dir, so it is
    // confirmed first — the same rule the CLI enforces with --switch.
    func setActive(profile name: String, vendor: String?) {
        var args = ["use", name]
        if let id = vendor {
            args += ["--vendor", id]
            if let v = model.data?.snapshot.vendor(id), v.isolation == "swap" {
                dismissPanel()
                let confirm = NSAlert()
                confirm.messageText = "Switch \(v.label) to “\(name)”?"
                confirm.informativeText = "\(v.label) has no per-process pinning, so this changes its login everywhere, including sessions started from other profiles."
                confirm.addButton(withTitle: "Switch")
                confirm.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        let r = runCLI(args)
        if r.status != 0 {
            dismissPanel()
            alert("Couldn't switch active profile", r.output)
        }
        refreshPanel()
    }

    // Always go through the CLI rather than composing an env-var prefix here:
    // it alone knows how each vendor is pinned, and a swap-only vendor (no
    // config-dir env var) needs --switch, which is a global side effect the
    // user should see spelled out in the command.
    private func sessionCommand(profile: String, vendor: Vendor) -> String {
        var cmd = "\"\(cliPath)\" run \(profile) --vendor \(vendor.id)"
        if vendor.isolation == "swap" { cmd += " --switch" }
        return cmd
    }

    // terminal nil = the preferred one.
    func openSession(profile: String, vendor id: String, terminal: String?) {
        guard let v = model.data?.snapshot.vendor(id) else { return }
        dismissPanel()
        let spec = terminal.flatMap { name in terminalSpecs.first { $0.name == name } } ?? preferredTerminal
        launchSession(sessionCommand(profile: profile, vendor: v), slug: "\(profile)-\(id)", in: spec)
    }

    // Signs the slot out and back in through `agents login`, in a terminal —
    // the labs sign in through a browser and print codes there. Confirmed
    // first when it would discard a working login.
    func signIn(profile: String, vendor id: String, confirm: Bool) {
        guard let v = model.data?.snapshot.vendor(id) else { return }
        dismissPanel()
        if confirm {
            let ask = NSAlert()
            ask.messageText = "Sign \(v.label) in “\(profile)” out and back in?"
            let current = model.data?.snapshot.account(profile, id).map { " (\($0))" } ?? ""
            ask.informativeText = "The current \(v.label) login for this profile\(current) is removed, then a terminal opens so you can sign in with the right account. The browser uses whichever account it's already signed in to — switch it there first if needed."
                + (v.isolation == "swap" ? " \(v.label) has one global login, so this also makes “\(profile)” its active profile." : "")
            ask.addButton(withTitle: "Sign Out and Sign In")
            ask.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard ask.runModal() == .alertFirstButtonReturn else { return }
        }
        var cmd = "\"\(cliPath)\" login \(profile) --vendor \(id)"
        if v.isolation == "swap" { cmd += " --switch" }
        // Whatever the outcome, tell the panel to re-read when it's over.
        cmd += "; open -g 'n2agents://refresh'"
        launchSession(cmd, slug: "\(profile)-\(id)-login", in: preferredTerminal)
    }

    func copyCommand(profile: String, vendor: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("\(vendor)-\(profile.lowercased())", forType: .string)
    }

    // Add a lab to an existing profile: one slot dir, plus its PATH shim.
    func addVendor(profile name: String) {
        dismissPanel()
        openSetup(profile: name, isNew: false, resume: nil)
    }

    func finishSetup(profile: String) {
        dismissPanel()
        openSetup(profile: profile, isNew: false, resume: model.pendingSetups[profile])
    }

    // MARK: - Profile setup window

    private var setup: ProfileSetup?

    private func openSetup(profile: String, isNew: Bool, resume: [String]?) {
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
        setup = window
        window.show()
    }

    // Slots are directories, so creating them is instant. The one slow piece —
    // cloning Claude.app for the profile's own Desktop — runs in the
    // background, and the card picks it up when it lands.
    func setupCreate(profile: String, vendors: [String], cloneDesktop: Bool) -> String? {
        let r = runCLI(["new", profile, "--vendors", vendors.joined(separator: ","), "--cli-only"])
        guard r.status == 0 else { return r.output }
        if cloneDesktop && !fm.fileExists(atPath: "/Applications/Claude-\(profile).app") {
            DispatchQueue.main.async { self.backgroundClone(profile) }
        }
        return nil
    }

    func setupAuthed(profile: String) -> [String: Bool]? {
        let r = runCLI(["authed", profile])
        guard r.status == 0 else { return nil }
        var out: [String: Bool] = [:]
        for line in r.output.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 2, f[1] != "unknown" else { continue }
            out[f[0]] = f[1] == "yes"
        }
        return out
    }

    private func loginCommand(profile: String, vendor: String) -> String {
        var cmd = "\"\(cliPath)\" login \(profile) --vendor \(vendor)"
        if model.data?.snapshot.vendor(vendor)?.isolation == "swap" { cmd += " --switch" }
        return cmd
    }

    func setupStartLogin(profile: String, vendor: String) {
        let done = "open -g 'n2agents://login-done?profile=\(profile)&vendor=\(vendor)'"
        launchSession(loginCommand(profile: profile, vendor: vendor) + "; " + done,
                      slug: "\(profile)-\(vendor)-setup", in: preferredTerminal)
    }

    func setupCopyLoginCommand(profile: String, vendor: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(loginCommand(profile: profile, vendor: vendor), forType: .string)
    }

    func setupPending(profile: String, labs: [String]?) {
        model.pendingSetups[profile] = labs
        defaults.set(model.pendingSetups, forKey: CacheKey.pendingSetups)
    }

    func setupOpen(profile: String, vendor: String) {
        openSession(profile: profile, vendor: vendor, terminal: nil)
    }

    func setupMakeActive(profile: String) {
        setActive(profile: profile, vendor: nil)
    }

    var setupDesktopInstalled: Bool { claudeAppPath != nil }
    var setupTerminalName: String { preferredTerminal.name }

    private func backgroundClone(_ name: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [scriptsDir + "/make-claude-profile.sh", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.terminationHandler = { t in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.refreshPanel()
                if t.terminationStatus != 0 {
                    self.alert("Couldn't create Claude Desktop for “\(name)”", String(out.suffix(600)))
                }
            }
        }
        do { try task.run() } catch { alert("Couldn't create Claude Desktop for “\(name)”", error.localizedDescription) }
    }

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

    func revealData(profile name: String) {
        dismissPanel()
        guard let p = profile(named: name) else { return }
        try? fm.createDirectory(atPath: p.dataDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: p.dataDir))
    }

    // Name first; the setup window then picks its labs and signs in to each.
    func newProfile() {
        dismissPanel()
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
        if fm.fileExists(atPath: "/Applications/Claude-\(name).app")
            || model.data?.profiles.contains(where: { $0.name.lowercased() == name.lowercased() }) == true {
            self.alert("Profile exists", "“\(name)” is already a profile. Pick another name, or delete the existing one first.")
            return
        }
        openSetup(profile: name, isNew: true, resume: nil)
    }

    func deleteProfile(_ name: String) {
        dismissPanel()
        guard let p = profile(named: name) else { return }
        if isRunning(p) {
            alert("“\(p.name)” is running", "Quit this profile’s Claude Desktop first, then delete it.")
            return
        }
        if repatchInFlight.contains(p.name) {
            alert("“\(p.name)” is repatching", "Wait for the rebuild to finish, then delete.")
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Delete profile “\(p.name)”?"
        confirm.informativeText = "“Everything” also removes its login/data (\(p.dataDir)) and CLI config (\(p.configDir)). This can't be undone."
        confirm.addButton(withTitle: "Delete App Only")
        confirm.addButton(withTitle: "Delete Everything")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let choice = confirm.runModal()
        guard choice != .alertThirdButtonReturn else { return }

        var args = ["delete", p.name, "--yes"]
        if choice == .alertSecondButtonReturn { args.append("--everything") }
        let result = runCLI(args)
        if result.status != 0 {
            alert("Delete failed", result.output)
        }
        refreshPanel()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Sessions (listed, moved and resumed through the CLI)

    private func sessions(_ args: [String]) -> [SessionInfo] {
        let r = runCLI(["sessions", "--porcelain"] + args)
        return r.status == 0 ? SessionInfo.parse(r.output) : []
    }

    func transferSession(profile name: String, vendor: String) {
        dismissPanel()
        transferUI(fromName: name, vendor: vendor)
    }

    // Resume through the CLI so the pinning rules stay in one place.
    private func resumeCommand(_ s: SessionInfo, in profile: String) -> String {
        let invoke = "\"\(cliPath)\" run \(profile) --vendor \(s.vendor) --start-from-session=\(s.id)"
        return s.cwd.map { "cd \"\($0)\" && \(invoke)" } ?? invoke
    }

    func resumeSession(_ s: SessionInfo) {
        dismissPanel()
        launchSession(resumeCommand(s, in: s.profile), slug: "\(s.profile)-\(s.vendor)", in: preferredTerminal)
    }

    private func sessionRowLabel(_ s: SessionInfo) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        let project = s.cwd.map { ($0 as NSString).lastPathComponent } ?? "—"
        return "\(df.string(from: s.mtime))  ·  \(project)  ·  \(s.snippet)"
    }

    private func transferUI(fromName: String, vendor: String) {
        let srcLabel = fromName
        let snap = snapshot()
        let label = snap.vendor(vendor)?.label ?? vendor
        let sessions = sessions([fromName, "--vendor", vendor])
        guard !sessions.isEmpty else {
            alert("No sessions in “\(srcLabel)”", "This profile has no \(label) sessions yet.")
            return
        }
        // Only profiles that hold a slot for this lab can receive one.
        let targets: [(name: String, label: String)] = snap.profiles
            .filter { $0.name != fromName && $0.slots[vendor] != nil }
            .map { ($0.name, $0.name) }
        guard !targets.isEmpty else {
            alert("No destination profile", "Create another profile with a \(label) slot first (N2 Agents settings → New Profile…).")
            return
        }

        let controller = SessionListController()
        controller.rows = sessions.map { sessionRowLabel($0) }
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.width = 460
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = false
        table.dataSource = controller
        table.delegate = controller
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)

        // Explicit frames — an NSScrollView has no intrinsic size, so
        // stack-view/Auto Layout collapses it to zero inside an NSAlert.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 262))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 34, width: 480, height: 228))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let destLabel = NSTextField(labelWithString: "Transfer to:")
        destLabel.sizeToFit()
        destLabel.setFrameOrigin(NSPoint(x: 0, y: 7))
        let popup = NSPopUpButton(frame: NSRect(x: destLabel.frame.maxX + 8, y: 1, width: 220, height: 26),
                                  pullsDown: false)
        popup.addItems(withTitles: targets.map { $0.label })
        container.addSubview(scroll)
        container.addSubview(destLabel)
        container.addSubview(popup)

        let dialog = NSAlert()
        dialog.messageText = "Transfer a \(label) session from “\(srcLabel)”"
        dialog.informativeText = "Moves the session (transcript + per-session data) to another profile. Resume it there from the panel's recent sessions."
        dialog.accessoryView = container
        dialog.addButton(withTitle: "Transfer")
        dialog.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .alertFirstButtonReturn else { return }

        let session = sessions[max(0, table.selectedRow)]
        let dest = targets[max(0, popup.indexOfSelectedItem)]
        let result = runCLI(["transfer", session.id, "--from", srcLabel, "--to", dest.label, "--vendor", vendor])
        guard result.status == 0 else {
            alert("Transfer failed", result.output)
            return
        }

        let resumeCmd = resumeCommand(session, in: dest.name)

        let done = NSAlert()
        done.messageText = "Session transferred to “\(dest.label)”"
        done.informativeText = "Open it now, or copy the resume command for later."
        done.addButton(withTitle: "Open Now")
        done.addButton(withTitle: "Copy Command")
        done.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        switch done.runModal() {
        case .alertFirstButtonReturn:
            launchSession(resumeCmd, slug: dest.label, in: preferredTerminal)
        case .alertSecondButtonReturn:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(resumeCmd, forType: .string)
        default:
            break
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
