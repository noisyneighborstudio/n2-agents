import AppKit
import Carbon

// A user-assignable, system-wide shortcut that pops the menu at the pointer —
// the status item can be pushed behind the notch, so the icon is not a
// reliable way in. Carbon's RegisterEventHotKey needs no Accessibility grant.

struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32   // Carbon mask: cmdKey | optionKey | controlKey | shiftKey
    let display: String

    // ⌃⌥⌘N: unclaimed by macOS and by common apps.
    static let fallback = Shortcut(keyCode: UInt32(kVK_ANSI_N),
                                   modifiers: UInt32(controlKey | optionKey | cmdKey),
                                   display: "⌃⌥⌘N")

    private static let key = "menuShortcut"

    // nil = the user cleared it; absent = never set, so the fallback applies.
    static func load(_ defaults: UserDefaults = .standard) -> Shortcut? {
        guard let d = defaults.dictionary(forKey: key) else { return fallback }
        guard let code = d["keyCode"] as? Int, let mods = d["modifiers"] as? Int,
              let display = d["display"] as? String else { return nil }
        return Shortcut(keyCode: UInt32(code), modifiers: UInt32(mods), display: display)
    }

    static func save(_ s: Shortcut?, _ defaults: UserDefaults = .standard) {
        guard let s else { defaults.set([String: Any](), forKey: key); return }
        defaults.set(["keyCode": Int(s.keyCode), "modifiers": Int(s.modifiers), "display": s.display], forKey: key)
    }

    // A shortcut needs ⌘, ⌥ or ⌃ — a bare key (or shift+key) would eat typing.
    init?(event e: NSEvent) {
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        var carbon = 0, symbols = ""
        if flags.contains(.control) { carbon |= controlKey; symbols += "⌃" }
        if flags.contains(.option)  { carbon |= optionKey;  symbols += "⌥" }
        if flags.contains(.shift)   { carbon |= shiftKey;   symbols += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey;     symbols += "⌘" }
        let named: [UInt16: String] = [
            UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
            UInt16(kVK_Delete): "⌫", UInt16(kVK_Escape): "⎋",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        ]
        let name = named[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "").uppercased()
        guard !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(e.keyCode), modifiers: UInt32(carbon), display: symbols + name)
    }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }
}

final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotKey>.fromOpaque(ctx).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// False when another app already owns the combination.
    @discardableResult
    func register(_ s: Shortcut?) -> Bool {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard let s else { return true }
        let id = EventHotKeyID(signature: OSType(0x4E32_4147), id: 1)  // 'N2AG'
        return RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

// Accessory view for the "Menu Shortcut…" alert: focus it and press a combo.
final class ShortcutRecorderView: NSView {
    private(set) var recorded: Shortcut?
    private let label = NSTextField(labelWithString: "")

    init(current: Shortcut?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        label.alignment = .center
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.stringValue = current?.display ?? "Press a shortcut…"
        label.frame = bounds.insetBy(dx: 4, dy: 4)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    // ⌘-combos arrive as key equivalents before keyDown; catch both so the
    // alert's buttons never see a combination meant for the recorder.
    override func performKeyEquivalent(with e: NSEvent) -> Bool { capture(e) }
    override func keyDown(with e: NSEvent) { if !capture(e) { super.keyDown(with: e) } }

    private func capture(_ e: NSEvent) -> Bool {
        guard let s = Shortcut(event: e) else { return false }
        recorded = s
        label.stringValue = s.display
        return true
    }
}
