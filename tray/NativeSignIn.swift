import AppKit
import CoreFoundation

struct SignInPlan: Sendable {
    let arguments: [String]
    let owner: String?
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Cannot determine this profile's sign-in route. Check account ownership and resolve any migration or configuration conflict, then try again." }
    }
    private static func versionOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number == 1
    }
    static func parse(profile: String, vendor: String, status: Int32, output: String) throws -> Self {
        let legacy = Self(arguments: ["login", profile, "--vendor", vendor], owner: nil)
        guard vendor == "codex" else { return legacy }
        guard status == 0, let data = output.data(using: .utf8), data.count <= 4 * 1024 * 1024,
              let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              versionOne(report["schemaVersion"]), let profiles = report["profiles"] as? [[String: Any]] else { throw Unavailable() }
        let matches = profiles.filter { $0["name"] as? String == profile }
        guard matches.count == 1, let row = matches.first, let routes = row["routes"] as? [[String: Any]] else { throw Unavailable() }
        let slots = routes.filter { $0["provider"] as? String == vendor }
        guard slots.count == 1, let slot = slots.first, slot["status"] as? String == "available",
              let route = slot["ownerBinding"] as? [String: Any] else { throw Unavailable() }
        if route["status"] as? String == "unmanaged" { return legacy }
        func hex(_ value: Any?) -> String? {
            guard let value = value as? String, value.count == 64,
                  value.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            return value
        }
        guard row["metadataStatus"] as? String == "ready", route["status"] as? String == "registered",
              let revision = hex(route["revision"]), let binding = route["binding"] as? [String: Any],
              versionOne(binding["schemaVersion"]), binding["provider"] as? String == "codex",
              binding["credentialStore"] as? String == "owner-file", hex(binding["accountHash"]) != nil,
              let profileID = row["profileId"] as? String, binding["profileId"] as? String == profileID,
              ["profileId", "grantId", "ownershipGeneration"].allSatisfy({ key in
                  guard let value = binding[key] as? String else { return false }; return UUID(uuidString: value) != nil
              }), let owner = binding["owner"] as? String,
              owner.range(of: "^SHA256:[A-Za-z0-9+/]{43}$", options: .regularExpression) != nil else { throw Unavailable() }
        return Self(arguments: ["fleet", "auth", "login", profile, "--expected-revision", revision], owner: owner)
    }
    static func load(profile: String, vendor: String,
                     run: @escaping @Sendable ([String]) -> (Int32, String)) async throws -> Self {
        if vendor != "codex" { return try parse(profile: profile, vendor: vendor, status: 0, output: "") }
        let response: (Int32, String) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: run(["profiles", "--json"])) }
        }
        return try parse(profile: profile, vendor: vendor, status: response.0, output: response.1)
    }
    static func run(cli: String, environment: [String: String], args: [String]) -> (Int32, String) {
        precondition(!Thread.isMainThread)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [cli] + args
        process.environment = environment; process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return (1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func command(cli: String) -> String { ([cli] + arguments).map(Self.quote).joined(separator: " ") }
    func terminalCommand(cli: String, profile: String, vendor: String, setup: Bool) -> String {
        var result = command(cli: cli)
        if setup {
            var callback = URLComponents(string: "n2agents://login-done")!
            callback.queryItems = [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "vendor", value: vendor)]
            result += "; open -g " + Self.quote(callback.url!.absoluteString)
        }
        return result + "; open -g 'n2agents://refresh'"
    }
    @MainActor func alert(profile: String, label: String) -> NSAlert {
        let alert = NSAlert(); alert.messageText = "Sign in to \(label) for \(profile)?"
        if let owner {
            alert.informativeText = "Sign-in runs on the configured account owner and keeps the same account. Existing sessions retain their account. A terminal will show the sign-in link or code. A remote owner must allow sign-in management.\n\nOwner: \(owner)"
            alert.addButton(withTitle: "Sign In")
        } else {
            alert.informativeText = "The current \(label) login for this profile is removed, then a terminal opens for sign-in. Check which account your browser is using first."
            alert.addButton(withTitle: "Sign Out and Sign In")
        }
        alert.addButton(withTitle: "Cancel"); return alert
    }
}

@MainActor final class SignInCoordinator {
    private var request = UUID()
    func perform(profile: String, vendor: String, confirmLegacy: Bool, copyOnly: Bool = false,
                 run: @escaping @Sendable ([String]) -> (Int32, String), confirm: @MainActor (SignInPlan) -> Bool,
                 finish: @MainActor (SignInPlan) -> Void, cancelled: @MainActor () -> Void = {}, fail: @MainActor (String) -> Void) async {
        let current = UUID(); request = current
        do {
            let plan = try await SignInPlan.load(profile: profile, vendor: vendor, run: run)
            guard request == current, !Task.isCancelled else { return }
            if !copyOnly && (plan.owner != nil || confirmLegacy) && !confirm(plan) { cancelled(); return }
            guard request == current, !Task.isCancelled else { return }
            finish(plan)
        } catch {
            guard request == current, !Task.isCancelled else { return }
            fail(error.localizedDescription)
        }
    }
}
