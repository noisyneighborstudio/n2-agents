import AppKit
import XCTest
@testable import N2AgentsTray

@MainActor
final class NativeAuthTests: XCTestCase {
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
