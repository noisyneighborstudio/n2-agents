import AppKit

// What the panel copies, and the copying itself: one place, so the command
// shown on Configure is exactly the one pasted.
enum Clipboard {
    /// The PATH shim that starts a lab in a profile: `codex-default`.
    static func command(profile: String, vendor: String) -> String { "\(vendor)-\(profile.lowercased())" }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// VoiceOver hears a copy that the screen shows only as a checkmark.
    static func announceCopied() {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: String(localized: "Copied", comment: "VoiceOver: text copied"),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
