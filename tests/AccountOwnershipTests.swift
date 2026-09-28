import AppKit
import SwiftUI

@main struct AccountOwnershipTests {
    @MainActor static func main() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "docs/audits/native-ownership-flow-spike.json"))
        let fixtures = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        func raw(_ name: String) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: fixtures[name]!), encoding: .utf8)!
        }
        let active = raw("active"), retired = raw("retired")
        let inspector = AccountOwnershipInspector()
        await inspector.refresh(profile: "Work Profile") { args in
            precondition(!Thread.isMainThread, "ownership read blocked UI thread")
            precondition(args == ["auth", "status", "Work Profile"], "wrong profile or mutation command")
            return (0, active)
        }
        precondition(inspector.result?.state == "active")
        precondition(inspector.result?.account == (fixtures["active"] as! [String: Any])["binding"].flatMap { ($0 as? [String: Any])?["accountHash"] as? String })
        await inspector.refresh(profile: "Work Profile") { _ in (0, retired) }
        precondition(inspector.result?.state == "retired")
        await inspector.refresh(profile: "Work Profile") { _ in (1, "owner registration unavailable") }
        precondition(inspector.result?.state == "unavailable" && inspector.result?.account == nil,
                     "failed read retained stale active account")
        for text in ["{}", "not json", "{\"status\":\"future-state\"}", "{\"status\":\"active\"}"] {
            precondition(AccountOwnershipStatus.parse(status: 0, output: text).state == "unavailable")
        }
        // Hold one background read while a newer profile finishes; no sleeps.
        let release = DispatchSemaphore(value: 0)
        let started = AsyncStream<Void>.makeStream()
        let older = Task { await inspector.refresh(profile: "Old") { _ in
            started.continuation.yield(()); started.continuation.finish()
            precondition(release.wait(timeout: .now() + 5) == .success, "UI did not remain responsive")
            return (0, active)
        } }
        for await _ in started.stream { break }
        precondition(inspector.loading && inspector.result == nil, "loading retained stale result")
        await inspector.refresh(profile: "New") { _ in (0, retired) }
        release.signal(); await older.value
        precondition(inspector.result?.state == "retired", "old request replaced newer profile")
        if CommandLine.arguments.count > 1 {
            _ = NSApplication.shared
            let view = NSHostingView(rootView: AccountOwnershipDetails(profile: "Work Profile",
                result: AccountOwnershipStatus.parse(status: 0, output: retired))
                .padding(12).frame(width: 360, alignment: .leading)
                .background(Color.white).environment(\.colorScheme, .light))
            view.frame = NSRect(x: 0, y: 0, width: 360, height: 250)
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("Account ownership profile routing, states, failure replacement, responsiveness and stale-request tests passed")
    }
}
