import AppKit
import XCTest
@testable import N2AgentsTray

// Substitute the clipboard action, never read or replace the user's clipboard.
private final class FixtureAuthTerminalView: AuthTerminalView {
    var pasteCount = 0
    override func paste(_ sender: Any) {
        pasteCount += 1
        send(txt: "fixture-auth-code")
    }
}

@MainActor
final class NativeAuthTests: XCTestCase {
    func testCommandVPastesIntoFocusedPrompt() async {
        await pasteIntoPrompt(usingKeyboard: true)
    }

    func testPasteCodeButtonReturnsFocusToPrompt() async {
        await pasteIntoPrompt(usingKeyboard: false)
    }

    private func pasteIntoPrompt(usingKeyboard: Bool) async {
        _ = NSApplication.shared
        let done = expectation(description: "Pasted code reaches login process")
        let session = NativeAuthSession(executable: "/bin/sh",
            arguments: ["-c", "read code; test \"$code\" = fixture-auth-code"],
            environment: ["PATH": "/usr/bin:/bin"])
        let terminal = FixtureAuthTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        terminal.processDelegate = session
        session.terminal = terminal
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = terminal
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        window.makeFirstResponder(nil)
        XCTAssertFalse(terminal.performKeyEquivalent(with: key))
        XCTAssertEqual(terminal.pasteCount, 0)
        session.onFinish = { status in
            XCTAssertEqual(status, 0)
            done.fulfill()
        }
        session.start()
        if usingKeyboard {
            window.makeFirstResponder(terminal)
            XCTAssertTrue(terminal.performKeyEquivalent(with: key))
        } else {
            session.pasteCode()
        }
        XCTAssertEqual(terminal.pasteCount, 1)
        XCTAssertTrue(window.firstResponder === terminal)
        terminal.send(txt: "\n")
        await fulfillment(of: [done], timeout: 10)
        session.pasteCode()
        XCTAssertEqual(terminal.pasteCount, 1, "Finished prompts must not receive pasted codes")
        session.cancel()
    }

    func testInteractivePromptFinishesInsideApp() async {
        _ = NSApplication.shared
        let done = expectation(description: "Login process exits")
        let session = NativeAuthSession(executable: "/bin/sh",
            arguments: ["-c", "test -t 0 && test -t 1 || exit 9; printf 'Enter code: '; read code; test \"$code\" = verified"],
            environment: ["PATH": "/usr/bin:/bin"])
        session.onFinish = { status in
            XCTAssertEqual(status, 0)
            XCTAssertFalse(session.isRunning)
            done.fulfill()
        }
        session.start()
        session.terminal.send(txt: "verified\n")
        await fulfillment(of: [done], timeout: 10)
    }

    func testLoginFailureIsReported() async {
        _ = NSApplication.shared
        let done = expectation(description: "Failed login exits")
        let session = NativeAuthSession(executable: "/bin/sh", arguments: ["-c", "exit 3"], environment: [:])
        session.onFinish = { status in
            XCTAssertNotEqual(status, 0)
            done.fulfill()
        }
        session.start()
        await fulfillment(of: [done], timeout: 10)
    }

    func testCancelStopsProcessWithoutAdvancingSetup() async {
        _ = NSApplication.shared
        let session = NativeAuthSession(executable: "/bin/sh", arguments: ["-c", "read answer"], environment: [:])
        session.onFinish = { _ in XCTFail("Cancelled sign-in advanced setup") }
        session.start()
        session.cancel()
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.onFinish)
    }
}
