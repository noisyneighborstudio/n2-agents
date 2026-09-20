import AppKit

// Setup Assistant — the first-launch flow, and 🤖 → Setup Assistant… later.
//
// Finds every lab CLI on this Mac and gets each one to "ready": installed,
// managed by N2 Agents (its dot dir is a symlink into ~/.n2-agents/Default,
// so plain `codex` and `codex-default` share ONE login), and signed in.
// Every fact and every side effect comes from `agents setup`; this window
// only renders rows and dispatches buttons.
final class SetupAssistant: NSObject, NSWindowDelegate {
    static let completedKey = "setupCompleted"

    private let cliPath: String
    private let run: ([String]) -> (status: Int32, output: String)
    private let openInTerminal: (_ command: String, _ slug: String) -> Void

    private var window: NSWindow?
    private let rowsStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let adoptAllButton = NSButton(title: "Bring All In", target: nil, action: nil)
    private var rows: [SetupRow] = []
    private var busy = false

    init(cliPath: String,
         run: @escaping ([String]) -> (status: Int32, output: String),
         openInTerminal: @escaping (_ command: String, _ slug: String) -> Void) {
        self.cliPath = cliPath
        self.run = run
        self.openInTerminal = openInTerminal
    }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        reload()
    }

    // MARK: - Window

    // Laid out like the app's other dialogs (all NSAlerts): app icon at the
    // left, bold message, small informative text, controls below, buttons
    // bottom-right with the default action rightmost. A real window rather
    // than NSAlert only because a modal panel couldn't refresh itself when the
    // user comes back from a terminal sign-in.
    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 344),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Set Up N2 Agents"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let message = NSTextField(labelWithString: "Set up N2 Agents")
        message.font = .boldSystemFont(ofSize: 13)
        let info = NSTextField(wrappingLabelWithString:
            "These agent CLIs are on this Mac. Bringing one in moves its config dir to ~/.n2-agents/Default and leaves a symlink behind, so the login you already have keeps working — from the plain command and from every profile you add.")
        info.font = .systemFont(ofSize: 11)
        info.preferredMaxLayoutWidth = 420

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        adoptAllButton.target = self
        adoptAllButton.action = #selector(adoptAll(_:))
        adoptAllButton.keyEquivalent = "\r"
        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked(_:)))
        for b in [done, adoptAllButton] {
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        let footer = NSStackView(views: [statusLabel, done, adoptAllButton])
        footer.orientation = .horizontal
        footer.distribution = .fill   // the label stretches; buttons keep to the right
        footer.spacing = 12

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        let column = NSStackView(views: [message, info, rowsStack, spacer, footer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.setCustomSpacing(4, after: message)
        column.setCustomSpacing(16, after: info)

        let root = NSStackView(views: [icon, column])
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = root
        w.initialFirstResponder = adoptAllButton
        NSLayoutConstraint.activate([
            column.widthAnchor.constraint(equalToConstant: 420),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor),
            column.heightAnchor.constraint(equalTo: root.heightAnchor, constant: -40),
        ])
        return w
    }

    // Coming back from a terminal sign-in is the common case: re-read on focus.
    func windowDidBecomeKey(_ notification: Notification) { reload() }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: SetupAssistant.completedKey)
    }

    // MARK: - Data

    private func reload() {
        guard !busy else { return }
        busy = true
        statusLabel.stringValue = "Checking installed CLIs…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.run(["setup", "--porcelain"])
            let parsed = r.status == 0 ? SetupRow.parse(r.output) : []
            DispatchQueue.main.async {
                self.busy = false
                self.rows = parsed
                self.render(error: r.status == 0 ? nil : r.output)
            }
        }
    }

    private func render(error: String?) {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let error = error {
            rowsStack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Couldn't read setup state:\n\(error)"))
            statusLabel.stringValue = ""
            return
        }
        if rows.isEmpty {
            rowsStack.addArrangedSubview(NSTextField(labelWithString: "No agent CLIs found on PATH."))
        } else {
            let grid = NSGridView(views: rows.map { cells(for: $0) })
            grid.columnSpacing = 8
            grid.rowSpacing = 4
            grid.yPlacement = .center
            for (i, width) in [14, 18, 90, 170, 96].enumerated() {
                grid.column(at: i).width = CGFloat(width)
            }
            for i in 0..<grid.numberOfRows { grid.row(at: i).height = 22 }
            rowsStack.addArrangedSubview(grid)
        }

        let installed = rows.filter { $0.installed }
        let ready = installed.filter { $0.isReady }.count
        let adoptable = installed.filter { $0.state == "real" }.count
        adoptAllButton.isHidden = adoptable == 0
        adoptAllButton.title = adoptable == 1 ? "Bring It In" : "Bring All \(adoptable) In"
        statusLabel.stringValue = installed.isEmpty
            ? "No agent CLIs found on PATH."
            : "\(ready) of \(installed.count) labs ready"
    }

    // glyph · label · detail · action — the action column is always present
    // (empty for a ready row) so the grid's columns stay put.
    private func cells(for row: SetupRow) -> [NSView] {
        // The menu's vocabulary: 🟢 good to go, ⚪️ not yet.
        let glyph = NSTextField(labelWithString: row.isReady ? "🟢" : "⚪️")
        glyph.font = .systemFont(ofSize: 11)

        // The vendor's mark as a template image, so it takes the label colour
        // like an SF Symbol would (tray/vendor-icons, bundled in Resources).
        let mark = NSImageView()
        if let res = Bundle.main.resourcePath, let image = NSImage(contentsOfFile: "\(res)/vendor-icons/\(row.id).svg") {
            image.isTemplate = true
            mark.image = image
        }
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.widthAnchor.constraint(equalToConstant: 16).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let name = NSTextField(labelWithString: row.label)
        name.font = .systemFont(ofSize: 12)

        let detail = NSTextField(labelWithString: row.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        guard let action = row.action else { return [glyph, mark, name, detail, NSGridCell.emptyContentView] }
        let button = NSButton(title: action.title, target: self, action: #selector(rowAction(_:)))
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.widthAnchor.constraint(equalToConstant: 96).isActive = true
        button.identifier = NSUserInterfaceItemIdentifier(row.id)
        return [glyph, mark, name, detail, button]
    }

    // MARK: - Actions

    @objc private func rowAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let row = rows.first(where: { $0.id == id }),
              let action = row.action else { return }
        switch action {
        case .install(let hint):
            if hint.hasPrefix("http"), let url = URL(string: hint) {
                NSWorkspace.shared.open(url)
            } else {
                openInTerminal(hint, "install-\(row.id)")
            }
        case .adopt:
            adopt([row.id])
        case .signIn:
            // The CLI adopts first if needed, then execs the vendor's own login
            // flow, pinned to Default — same as `agents setup login <v>`.
            openInTerminal("\"\(cliPath)\" setup login \(row.id)", "setup-\(row.id)")
        }
    }

    @objc private func adoptAll(_ sender: Any?) {
        adopt(rows.filter { $0.installed && $0.state == "real" }.map { $0.id })
    }

    private func adopt(_ vendors: [String]) {
        guard !busy, !vendors.isEmpty else { return }
        busy = true
        statusLabel.stringValue = "Bringing in \(vendors.joined(separator: ", "))…"
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            for v in vendors {
                let r = self.run(["setup", "adopt", v])
                if r.status != 0 { failures.append("\(v): \(r.output)") }
            }
            DispatchQueue.main.async {
                self.busy = false
                if !failures.isEmpty {
                    let a = NSAlert()
                    a.messageText = "Some labs couldn't be brought in"
                    a.informativeText = failures.joined(separator: "\n\n")
                    a.runModal()
                }
                self.reload()
            }
        }
    }

    @objc private func refreshClicked(_ sender: Any?) { reload() }

    @objc private func doneClicked(_ sender: Any?) {
        UserDefaults.standard.set(true, forKey: SetupAssistant.completedKey)
        window?.close()
    }
}
