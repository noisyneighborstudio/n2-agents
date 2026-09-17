import AppKit
#if canImport(Sparkle)
import Sparkle
typealias UpdaterDelegateProtocol = SPUUpdaterDelegate
#else
protocol UpdaterDelegateProtocol {}
#endif

// N2 Agents — menu bar launcher for cross-vendor agent profiles.
//
// A profile is an IDENTITY holding one slot per lab (Claude, Codex, Grok, …),
// so switching moves every vendor at once. The whole profile/vendor model is
// owned by the `agents` CLI; this app parses `agents porcelain` and shells back
// out for anything with side effects, so the two cannot drift.
// Helper scripts are embedded in the app bundle (Contents/Resources).
//
// Resident duties beyond the menu:
//  - Auto-repatch: detects Claude.app updates (version drift vs clones) and
//    silently rebuilds idle clones in the background.
//  - Self-update: delegates signed automatic and manual updates to Sparkle.

// A profile as the menu needs it: the CLI's porcelain row plus the two
// Claude-desktop paths the clone/delete/reveal actions operate on.
struct Profile {
    let name: String
    let hasApp: Bool
    let dataDir: String
    let configDir: String
    /// vendor id -> "active" | "ok"; absent means no slot for that vendor.
    let slots: [String: String]

    var isDefault: Bool { name == "Default" }
    func isActive(for vendor: String) -> Bool { slots[vendor] == "active" }
}

// A Claude Code CLI session: projects/<slug>/<uuid>.jsonl inside a config dir.
struct SessionInfo {
    let id: String
    let projectSlug: String
    let jsonlPath: String
    let cwd: String?
    let snippet: String
    let mtime: Date
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UpdaterDelegateProtocol {
    private var statusItem: NSStatusItem!
    private let fm = FileManager.default
    private let home = NSHomeDirectory()
    private var configRoot: String { home + "/.n2-agents" }
    private let claudeBundleID = "com.anthropic.claudefordesktop"
    private let newIssueURL = "https://github.com/noisyneighborstudio/n2-agents/issues/new"

    private var repatchInFlight = Set<String>()
    private var appsDirSource: DispatchSourceFileSystemObject?
    private var repatchDebounce: DispatchWorkItem?
#if canImport(Sparkle)
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
    )
#endif

    private var autoRepatchEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "autoRepatch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoRepatch") }
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
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

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

    // MARK: - Menu construction (rebuilt each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        cachedSnapshot = nil
        let profiles = discoverProfiles()
        let desktopPath = claudeAppPath
        let claudeInstalled = desktopPath != nil

        if !claudeInstalled {
            menu.addItem(NSMenuItem(title: "⚠️ Claude Desktop not found — Claude Code profiles still work",
                                    action: nil, keyEquivalent: ""))
            menu.addItem(actionItem("Locate Claude Desktop…", #selector(locateClaude(_:)), nil))
            menu.addItem(actionItem("Download Claude Desktop…", #selector(downloadClaude(_:)), nil))
            menu.addItem(.separator())
        }

        if profiles.isEmpty {
            menu.addItem(NSMenuItem(title: "No profiles yet", action: nil, keyEquivalent: ""))
        }

        let active = activeProfileName()
        let snap = snapshot()
        let terms = installedTerminals()

        // Default is an ordinary row now — the CLI reports it like any other
        // profile — so it no longer needs a hand-written duplicate of this block.
        for profile in profiles {
            var marker = (profile.isDefault ? isDefaultRunning() : isRunning(profile)) ? "🟢" : "⚪️"
            var suffix = ""
            if repatchInFlight.contains(profile.name) {
                marker = "⏳"
                suffix = "  (repatching…)"
            } else if isStale(profile) {
                suffix = "  ⬆️ update pending"
            }
            let item = NSMenuItem(title: "\(marker) \(profile.name)\(suffix)", action: nil, keyEquivalent: "")
            item.state = active == profile.name ? .on : .off

            let sub = NSMenu()
            if active != profile.name {
                sub.addItem(actionItem("Set as Active (all vendors)", #selector(setActiveProfile(_:)), profile.name))
                sub.addItem(.separator())
            }
            if profile.hasApp && claudeInstalled {
                sub.addItem(actionItem("Open Claude Desktop",
                                       profile.isDefault ? #selector(openDefaultDesktop(_:)) : #selector(openDesktop(_:)),
                                       profile.name))
            }

            // One entry per vendor this profile actually holds a slot for. A
            // vendor with no slot is simply absent rather than shown broken.
            let slotted = snap.installedVendors.filter { profile.slots[$0.id] != nil }
            if slotted.isEmpty {
                sub.addItem(NSMenuItem(title: "No vendor slots yet", action: nil, keyEquivalent: ""))
            }
            for v in slotted {
                let tag = profile.isActive(for: v.id) ? "  ✓" : ""
                sub.addItem(actionItem("Open \(v.label)\(tag)  (\(preferredTerminal.name))",
                                       #selector(openVendorTerminal(_:)), "\(profile.name)|\(v.id)"))
                if terms.count > 1 {
                    let inItem = NSMenuItem(title: "Open \(v.label) In", action: nil, keyEquivalent: "")
                    let inMenu = NSMenu()
                    for t in terms {
                        inMenu.addItem(actionItem(t.name, #selector(openVendorTerminalIn(_:)),
                                                  "\(profile.name)|\(v.id)|\(t.bundleId)"))
                    }
                    inItem.submenu = inMenu
                    sub.addItem(inItem)
                }
                sub.addItem(actionItem("Copy Command:  \(v.id)-\(profile.name.lowercased())",
                                       #selector(copyVendorCommand(_:)), "\(profile.name)|\(v.id)"))
                sub.addItem(.separator())
            }

            sub.addItem(actionItem("Add Vendor…", #selector(addVendor(_:)), profile.name))
            sub.addItem(actionItem("Reveal Claude Data Dir", #selector(revealData(_:)), profile.name))
            sub.addItem(actionItem("Transfer Claude Session…", #selector(transferProfileSession(_:)), profile.name))
            if !profile.isDefault {
                sub.addItem(.separator())
                sub.addItem(actionItem("Delete Profile…", #selector(deleteProfile(_:)), profile.name))
            }
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        // Without Claude Desktop there is nothing to clone, but a Claude Code
        // profile is just a config dir — creating one must stay possible.
        menu.addItem(actionItem(claudeInstalled ? "New Profile…" : "New Profile (Claude Code only)…",
                                #selector(newProfile(_:)), nil))
        if claudeInstalled {
            menu.addItem(actionItem("Re-patch All (after Claude update)", #selector(repatchAll(_:)), nil))
        }
        let toggle = actionItem("Auto-repatch after Claude updates", #selector(toggleAutoRepatch(_:)), nil)
        toggle.state = autoRepatchEnabled ? .on : .off
        menu.addItem(toggle)
        let channelItem = NSMenuItem(title: "Update Channel", action: nil, keyEquivalent: "")
        let channelMenu = NSMenu()
        for channel in UpdateChannel.allCases {
            let item = actionItem(channel.rawValue.capitalized, #selector(selectUpdateChannel(_:)), channel.rawValue)
            item.state = channel == UpdateChannel.selected() ? .on : .off
            channelMenu.addItem(item)
        }
        channelItem.submenu = channelMenu
        menu.addItem(channelItem)
        menu.addItem(actionItem("Check for N2 Agents Updates…", #selector(checkForUpdates(_:)), nil))
        let allTerms = installedTerminals()
        if allTerms.count > 1 {
            let termItem = NSMenuItem(title: "Open Sessions In", action: nil, keyEquivalent: "")
            let termMenu = NSMenu()
            for t in allTerms {
                let i = actionItem(t.name, #selector(setPreferredTerminal(_:)), t.bundleId)
                i.state = (t.bundleId == preferredTerminal.bundleId) ? .on : .off
                termMenu.addItem(i)
            }
            termItem.submenu = termMenu
            menu.addItem(termItem)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Report a Bug…", #selector(reportBug(_:)), nil))
        let versionItem = NSMenuItem(title: "N2 Agents v\(currentVersion)", action: nil, keyEquivalent: "")
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem(title: "Quit N2 Agents", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func actionItem(_ title: String, _ action: Selector, _ profile: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = profile
        return item
    }

    // MARK: - Profile discovery

    // One porcelain call per menu build; the CLI is the only thing that knows
    // what a profile is. Cached for the duration of a menu open so a submenu
    // and its parent can't disagree.
    private var cachedSnapshot: Snapshot?

    private func snapshot(refresh: Bool = false) -> Snapshot {
        if !refresh, let c = cachedSnapshot { return c }
        let r = runCLI(["porcelain"])
        let snap = r.status == 0 ? Snapshot.parse(r.output) : Snapshot.empty
        cachedSnapshot = snap
        return snap
    }

    private func discoverProfiles() -> [Profile] {
        snapshot().profiles.map { row in
            Profile(name: row.name,
                    hasApp: row.name == "Default"
                        ? (claudeAppPath != nil)
                        : fm.fileExists(atPath: "/Applications/Claude-\(row.name).app"),
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

    private func profile(from sender: NSMenuItem) -> Profile? {
        guard let name = sender.representedObject as? String else { return nil }
        return discoverProfiles().first { $0.name == name }
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
        guard autoRepatchEnabled else { return }
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
                               "Claude updated but the profile couldn't be rebuilt automatically:\n\n\(String(out.suffix(600)))\n\nTry 🤖 → Re-patch All, or file an issue.")
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

    @objc private func toggleAutoRepatch(_ sender: NSMenuItem) {
        autoRepatchEnabled.toggle()
        if autoRepatchEnabled { autoRepatchTick() }
    }

    // MARK: - Sparkle update channel

    @objc private func selectUpdateChannel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let channel = UpdateChannel(rawValue: raw) else { return }
        UserDefaults.standard.set(channel.rawValue, forKey: UpdateChannel.preferenceKey)
#if canImport(Sparkle)
        updaterController.updater.resetUpdateCycle()
#endif
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
#if canImport(Sparkle)
        updaterController.checkForUpdates(sender)
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

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        alert("Update check failed", error.localizedDescription)
    }
#endif

    // MARK: - Actions

    // The path is stored in this app's preferences; the agents CLI reads the same
    // key, so scripts and menu agree on where Claude Desktop lives.
    @objc private func locateClaude(_ sender: NSMenuItem) {
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

    @objc private func downloadClaude(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!)
    }

    @objc private func reportBug(_ sender: NSMenuItem) {
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

    @objc private func openDesktop(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
        if repatchInFlight.contains(p.name) {
            alert("“\(p.name)” is repatching", "Claude updated and this profile is being rebuilt. It'll be back in a moment.")
            return
        }
        let url = URL(fileURLWithPath: "/Applications/Claude-\(p.name).app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil {
                DispatchQueue.main.async {
                    self.alert("Couldn't launch Claude-\(p.name)",
                               "The app may be mid-repatch or damaged. Try “Re-patch All” from the N2 Agents menu.")
                }
            }
        }
    }

    // MARK: - agents CLI (single implementation of profile side effects)

    private var cliPath: String { scriptsDir + "/agents" }

    @discardableResult
    private func runCLI(_ args: [String]) -> (status: Int32, output: String) {
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

    private func activeProfileName() -> String { snapshot().active }

    @objc private func setActiveProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        setActive(name)
    }

    private func setActive(_ name: String) {
        let r = runCLI(["use", name])
        if r.status != 0 { alert("Couldn't switch active profile", r.output) }
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

    private func isDefaultRunning() -> Bool {
        guard let appPath = claudeAppPath else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", appPath + "/Contents/MacOS/Claude"]
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

    @objc private func openDefaultDesktop(_ sender: NSMenuItem) {
        guard let appPath = claudeAppPath else {
            alert("Claude Desktop not found", "Install it from claude.ai/download, or point N2 Agents at it with “Locate Claude Desktop…”.")
            return
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    // representedObject is "<profile>|<vendor>" (plus "|<bundleId>" for the
    // explicit terminal picker) — the menu's only encoding.
    private func parseTarget(_ sender: NSMenuItem) -> (profile: String, vendor: Vendor, bundleId: String?)? {
        guard let raw = sender.representedObject as? String else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let v = snapshot().vendor(parts[1]) else { return nil }
        return (parts[0], v, parts.count >= 3 ? parts[2] : nil)
    }

    @objc private func openVendorTerminal(_ sender: NSMenuItem) {
        guard let t = parseTarget(sender) else { return }
        launchSession(sessionCommand(profile: t.profile, vendor: t.vendor),
                      slug: "\(t.profile)-\(t.vendor.id)", in: preferredTerminal)
    }

    @objc private func openVendorTerminalIn(_ sender: NSMenuItem) {
        guard let t = parseTarget(sender), let id = t.bundleId,
              let spec = terminalSpecs.first(where: { $0.bundleId == id }) else { return }
        launchSession(sessionCommand(profile: t.profile, vendor: t.vendor),
                      slug: "\(t.profile)-\(t.vendor.id)", in: spec)
    }

    @objc private func copyVendorCommand(_ sender: NSMenuItem) {
        guard let t = parseTarget(sender) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("\(t.vendor.id)-\(t.profile.lowercased())", forType: .string)
    }

    // Add a lab to an existing profile: one slot dir, plus its PATH shim.
    @objc private func addVendor(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let snap = snapshot()
        let profile = snap.profiles.first { $0.name == name }
        let candidates = snap.installedVendors.filter { profile?.slots[$0.id] == nil }
        guard !candidates.isEmpty else {
            alert("Nothing to add", "“\(name)” already has a slot for every agent CLI installed on this Mac.")
            return
        }
        let dialog = NSAlert()
        dialog.messageText = "Add a vendor to “\(name)”"
        dialog.informativeText = "Creates an isolated config dir for that CLI. Sign in to it once afterwards."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        popup.addItems(withTitles: candidates.map { $0.label })
        dialog.accessoryView = popup
        dialog.addButton(withTitle: "Add")
        dialog.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        let picked = candidates[max(0, popup.indexOfSelectedItem)]
        let r = runCLI(["new", name, "--vendors", picked.id, "--cli-only"])
        if r.status != 0 { alert("Couldn't add \(picked.label)", r.output) }
    }

    private func installedTerminals() -> [TerminalSpec] {
        terminalSpecs.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil }
    }

    private var preferredTerminal: TerminalSpec {
        let saved = UserDefaults.standard.string(forKey: "preferredTerminal")
        let installed = installedTerminals()
        return installed.first { $0.bundleId == saved } ?? installed.first ?? terminalSpecs[0]
    }

    @objc private func setPreferredTerminal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "preferredTerminal")
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

    @objc private func revealData(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
        try? fm.createDirectory(atPath: p.dataDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: p.dataDir))
    }

    @objc private func newProfile(_ sender: NSMenuItem) {
        let cliOnly = claudeAppPath == nil
        let alert = NSAlert()
        alert.messageText = cliOnly ? "New Claude Code profile" : "New Claude profile"
        alert.informativeText = cliOnly
            ? "Name, letters/numbers only (e.g. Work). Creates a Claude Code config dir with its own login. Claude Desktop isn't installed, so there's no desktop app to clone — install it later and create the profile again to add one."
            : "Name, letters/numbers only (e.g. Work). Clones Claude.app into an isolated instance with its own login, plus a Claude Code config dir."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
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
        if fm.fileExists(atPath: "/Applications/Claude-\(name).app") {
            self.alert("Profile exists", "Claude-\(name).app is already in /Applications. Pick another name, or delete the existing profile first.")
            return
        }
        if cliOnly {
            let r = runCLI(["new", name, "--cli-only"])
            if r.status != 0 { self.alert("Couldn't create profile", r.output) }
            return
        }
        runInTerminal("\"\(scriptsDir)/agents\" new \(name)")
    }

    @objc private func repatchAll(_ sender: NSMenuItem) {
        runInTerminal("\"\(scriptsDir)/repatch-claude-profiles.sh\"")
    }

    @objc private func deleteProfile(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
        if isRunning(p) {
            alert("“\(p.name)” is running", "Quit that Claude instance first, then delete the profile.")
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
    }

    // MARK: - Session transfer (move a CLI session between profile config dirs)

    // Session transfer is Claude-shaped for now (Codex transcripts move fine
    // via `agents transfer --vendor codex`, but this picker only reads Claude's
    // projects/ layout), so it addresses the profile's claude slot.
    private func claudeConfigDir(forProfileNamed name: String) -> String {
        let slot = configRoot + "/" + name + "/claude"
        if fm.fileExists(atPath: slot) { return slot }
        return name == "Default" ? home + "/.claude" : slot
    }

    @objc private func transferProfileSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        transferUI(fromName: name)
    }

    private func discoverSessions(configDir: String) -> [SessionInfo] {
        let projectsDir = configDir + "/projects"
        var sessions: [SessionInfo] = []
        guard let slugs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }
        for slug in slugs where !slug.hasPrefix(".") {
            let dir = projectsDir + "/" + slug
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = dir + "/" + file
                let mtime = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
                let (cwd, snippet) = sessionPreview(path)
                sessions.append(SessionInfo(id: String(file.dropLast(".jsonl".count)),
                                            projectSlug: slug, jsonlPath: path,
                                            cwd: cwd, snippet: snippet, mtime: mtime))
            }
        }
        return sessions.sorted { $0.mtime > $1.mtime }
    }

    // Read the head of the transcript for the working dir and first user prompt.
    private func sessionPreview(_ path: String) -> (cwd: String?, snippet: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return (nil, "") }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 16384),
              let text = String(data: data, encoding: .utf8) else { return (nil, "") }
        var cwd: String?
        var snippet: String?
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if cwd == nil { cwd = obj["cwd"] as? String }
            if snippet == nil, obj["type"] as? String == "user",
               let msg = obj["message"] as? [String: Any] {
                if let s = msg["content"] as? String {
                    snippet = s
                } else if let parts = msg["content"] as? [[String: Any]] {
                    snippet = parts.compactMap { $0["text"] as? String }.first
                }
            }
            if cwd != nil && snippet != nil { break }
        }
        let clean = (snippet ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (cwd, clean.isEmpty ? "(no prompt)" : String(clean.prefix(80)))
    }

    private func sessionRowLabel(_ s: SessionInfo) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        let project = s.cwd.map { ($0 as NSString).lastPathComponent } ?? s.projectSlug
        return "\(df.string(from: s.mtime))  ·  \(project)  ·  \(s.snippet)"
    }

    private func transferUI(fromName: String) {
        let srcLabel = fromName
        let sessions = discoverSessions(configDir: claudeConfigDir(forProfileNamed: fromName))
        guard !sessions.isEmpty else {
            alert("No sessions in “\(srcLabel)”", "This profile has no Claude Code sessions yet.")
            return
        }
        // Only profiles that actually hold a Claude slot can receive one.
        let targets: [(name: String, label: String)] = snapshot().profiles
            .filter { $0.name != fromName && $0.slots["claude"] != nil }
            .map { ($0.name, $0.name) }
        guard !targets.isEmpty else {
            alert("No destination profile", "Create another profile with a Claude slot first (🤖 → New Profile…).")
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
        dialog.messageText = "Transfer a session from “\(srcLabel)”"
        dialog.informativeText = "Moves the session (transcript + per-session data) to another profile. Resume it there from this menu or with claude --resume."
        dialog.accessoryView = container
        dialog.addButton(withTitle: "Transfer")
        dialog.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .alertFirstButtonReturn else { return }

        let session = sessions[max(0, table.selectedRow)]
        let dest = targets[max(0, popup.indexOfSelectedItem)]
        let result = runCLI(["transfer", session.id, "--from", srcLabel, "--to", dest.label])
        guard result.status == 0 else {
            alert("Transfer failed", result.output)
            return
        }

        // Resume through the CLI so the pinning rules stay in one place.
        let invoke = "\"\(cliPath)\" run \(dest.name) --vendor claude --start-from-session=\(session.id)"
        let resumeCmd = session.cwd.map { "cd \"\($0)\" && \(invoke)" } ?? invoke

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
    private func runInTerminal(_ command: String) {
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

    private func alert(_ title: String, _ message: String) {
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
