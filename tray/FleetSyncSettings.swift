import SwiftUI

/// The CLI owns all fleet state. This view only renders its metadata and sends
/// explicit operator choices; credential contents never pass through the view.
struct FleetSyncSettings: View {
    @State private var categories: [String: Bool] = [:]
    @State private var providers: [(String, String, Bool)] = []
    @State private var conflicts: [(String, String)] = []
    @State private var status = "Loading fleet…"
    @State private var message = ""
    @State private var busy = false
    private let labels = [("settings", "Agent settings"), ("skills", "Skills and instructions"),
                          ("mcp", "MCP configuration"), ("auth", "Credentials")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FLEET PROFILE SYNC").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.secondary)
            Text("QA profile copies · changes stay separate from the primary app.")
                .font(.system(size: 12)).foregroundStyle(Ink.secondary)
            Button("Import local profiles and credentials") { perform(["sync", "import-local", "--credentials"]) }
            Text("Imports missing files only. Existing QA edits and primary profiles are preserved.")
                .font(.system(size: 11)).foregroundStyle(Ink.secondary)
            ForEach(labels, id: \.0) { key, label in
                Toggle(label, isOn: Binding(get: { categories[key] ?? false }, set: { enabled in
                    perform(["sync", "categories", key, enabled ? "on" : "off"])
                }))
            }
            Text("Credential sharing also requires a per-provider choice. MCP files can contain secrets and require that choice too.")
                .font(.system(size: 11)).foregroundStyle(Ink.secondary)
            ForEach(providers, id: \.0) { vendor, support, enabled in
                Toggle("\(vendor.capitalized) credentials · \(support)", isOn: Binding(get: { enabled }, set: { value in
                    perform(["sync", "auth", value ? "enable" : "disable", vendor])
                }))
                .disabled(support == "unsupported" || categories["auth"] == false)
            }
            HStack {
                Button("Sync now") { perform(["sync", "now"]) }
                Button("Enable background sync") { perform(["sync", "service", "install", "--interval", "60"]) }
                Button("Stop") { perform(["sync", "service", "uninstall"]) }
            }
            Button("Refresh status") { refresh() }
            Text(status).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            ForEach(conflicts, id: \.0) { id, address in
                VStack(alignment: .leading) {
                    Text(address).font(.system(size: 11)).textSelection(.enabled)
                    HStack {
                        Button("Keep this Mac’s version") { perform(["sync", "resolve", id, "--local"]) }
                        Button("Use peer’s version") { perform(["sync", "resolve", id, "--remote"]) }
                    }
                }
            }
            if !message.isEmpty { Text(message).font(.system(size: 11)).textSelection(.enabled) }
            if busy { ProgressView().controlSize(.small) }
        }
        .disabled(busy)
        .task { refresh() }
    }

    private func perform(_ args: [String]) {
        guard !busy else { return }
        busy = true
        Task {
            let result = await Task.detached { Self.run(args) }.value
            message = result
            await load()
            busy = false
        }
    }

    private func refresh() {
        guard !busy else { return }
        busy = true
        Task { await load(); busy = false }
    }

    @MainActor private func load() async {
        let values = await Task.detached {
            [Self.run(["sync", "categories"]), Self.run(["sync", "auth", "list"]),
             Self.run(["peers"]), Self.run(["sync", "service", "status"]), Self.run(["sync", "conflicts"])]
        }.value
        categories = Dictionary(uniqueKeysWithValues: rows(values[0]).compactMap { fields in
            fields.count == 2 ? (fields[0], fields[1] == "on") : nil
        })
        providers = rows(values[1]).compactMap { f in f.count >= 3 ? (f[0], f[1], f[2] == "opted-in") : nil }
        let peers = rows(values[2]).compactMap { f in f.count >= 5 ? "\(f[1]): \(f[4])" : nil }
        status = (peers + [values[3]]).joined(separator: "\n")
        conflicts = rows(values[4]).compactMap { f in f.count >= 2 ? (f[0], f[1]) : nil }
    }

    private func rows(_ text: String) -> [[String]] {
        text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    private static func run(_ args: [String]) -> String {
        guard let resources = Bundle.main.resourcePath else { return "App resources unavailable" }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [resources + "/agents", "fleet"] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ShellPath.fromLoginShell() ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return error.localizedDescription }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
