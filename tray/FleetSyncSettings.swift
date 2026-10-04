import SwiftUI

/// The CLI owns all fleet state. This view only renders its metadata and sends
/// explicit operator choices; credential contents never pass through the view.
///
/// Nothing here waits on anything else: each section fills in when its own
/// read returns (nil means still loading), a refresh keeps the last values on
/// screen, and an action disables only its own control.
struct FleetSyncSettings: View {
    @State private var categories: [String: Bool]?
    @State private var providers: [(String, String, Bool)]?
    @State private var machines: String?
    @State private var service: String?
    @State private var serviceLoaded: Bool?
    @State private var conflicts: [(String, String)]?
    @State private var held: [String]?
    @State private var hasIdentity: Bool?
    @State private var running: Set<String> = []
    /// Reads that timed out; their sections say so instead of spinning.
    @State private var timedOut: Set<Int> = []
    @State private var message = ""
    private let isQA = Bundle.main.object(forInfoDictionaryKey: "N2FleetQA") as? Bool == true
    private let labels = [("settings", "Agent settings"), ("skills", "Skills and instructions"),
                          ("mcp", "MCP configuration"), ("auth", "Credentials")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FLEET PROFILE SYNC").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.secondary)
            if hasIdentity == false {
                Text("This Mac isn’t in a fleet yet. Create a fleet identity from the Fleet section of the panel.")
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
            } else {
                controls
            }
        }
        .task { await load() }
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isQA {
                Text("QA profile copies · changes stay separate from the primary app.")
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                action("Import local profiles and credentials", ["sync", "import-local", "--credentials"])
                Text("Imports missing files only. Existing QA edits and primary profiles are preserved.")
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
            if let categories {
                ForEach(labels, id: \.0) { key, label in
                    let args = ["sync", "categories", key, categories[key] == true ? "off" : "on"]
                    Toggle(label, isOn: Binding(get: { categories[key] ?? false }, set: { _ in perform(args) }))
                        .disabled(running.contains(key))
                }
            } else {
                loading("Loading what this Mac shares…", read: 0)
            }
            Text("Credential sharing also requires a per-provider choice. MCP files can contain secrets and require that choice too.")
                .font(.system(size: 11)).foregroundStyle(Ink.secondary)
            if let providers {
                ForEach(providers, id: \.0) { vendor, support, enabled in
                    let args = ["sync", "auth", enabled ? "disable" : "enable", vendor]
                    Toggle(FleetWords.credentials(vendor, support), isOn: Binding(get: { enabled }, set: { _ in perform(args) }))
                        .disabled(running.contains(vendor) || support == "unsupported" || categories?["auth"] == false)
                }
            } else {
                loading("Loading credential providers…", read: 1)
            }
            HStack {
                action("Sync Now", ["sync", "now"])
                // One of the two, by what the service says it is doing.
                if serviceLoaded != true {
                    action("Turn On Background Sync", ["sync", "service", "install", "--interval", "60"])
                }
                if serviceLoaded != false {
                    action("Turn Off Background Sync", ["sync", "service", "uninstall"])
                }
            }
            Button("Refresh Status") { Task { await load() } }
            status(machines, loading: "Loading machines…", read: 2)
            status(service, loading: "Loading background sync…", read: 3)
            if let conflicts {
                ForEach(conflicts, id: \.0) { id, address in
                    VStack(alignment: .leading) {
                        Text(FleetWords.resource(address)).font(.system(size: 12)).textSelection(.enabled)
                        HStack {
                            action("Keep this Mac’s version", ["sync", "resolve", id, "--local"])
                            action("Use peer’s version", ["sync", "resolve", id, "--remote"])
                        }
                    }
                }
            } else {
                loading("Loading conflicts…", read: 4)
            }
            if let held, !held.isEmpty {
                Text("Held since this Mac joined. Other Macs don’t get these profiles until you share them.")
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                ForEach(held, id: \.self) { profile in
                    HStack {
                        Text(profile).font(.system(size: 11))
                        action("Share with the fleet", ["sync", "share", profile])
                    }
                }
            } else if held == nil {
                loading("Loading held profiles…", read: 5)
            }
            if !message.isEmpty { Text(message).font(.system(size: 11)).textSelection(.enabled) }
        }
    }

    @ViewBuilder private func loading(_ text: String, read index: Int) -> some View {
        if timedOut.contains(index) {
            Text("Couldn’t read this in time. Refresh status to try again.")
                .font(.system(size: 11)).foregroundStyle(Ink.secondary)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
        }
    }

    @ViewBuilder private func status(_ value: String?, loading text: String, read index: Int) -> some View {
        if let value {
            Text(value).font(.system(size: 11.5)).foregroundStyle(Ink.secondary).textSelection(.enabled)
        } else {
            loading(text, read: index)
        }
    }

    /// A button that disables only itself while its command runs.
    private func action(_ title: String, _ args: [String]) -> some View {
        let key = args.joined(separator: " ")
        return Button(title) { perform(args, key: key) }.disabled(running.contains(key))
    }

    private func perform(_ args: [String], key: String? = nil) {
        // Toggles key on the category or vendor they change.
        let key = key ?? args[args.count - (args[1] == "auth" ? 1 : 2)]
        guard !running.contains(key) else { return }
        running.insert(key)
        Task {
            let result = await Task.detached { FleetSettingsLoader.run(args) }.value
            message = result == FleetSettingsLoader.timedOut ? "That didn’t finish in time. Try again." : result
            running.remove(key)
            await load()
        }
    }

    @MainActor private func load() async {
        await FleetSettingsLoader.load(run: { FleetSettingsLoader.run($0) }) { index, value in
            // A timed-out read keeps whatever its section last showed.
            guard value != FleetSettingsLoader.timedOut else { timedOut.insert(index); return }
            timedOut.remove(index)
            switch index {
            case 0:
                categories = Dictionary(uniqueKeysWithValues: rows(value).compactMap { fields in
                    fields.count == 2 ? (fields[0], fields[1] == "on") : nil
                })
            case 1:
                providers = rows(value).compactMap { f in f.count >= 3 ? (f[0], f[1], f[2] == "opted-in") : nil }
            case 2:
                hasIdentity = FleetSettingsLoader.hasIdentity(value)
                machines = rows(value).compactMap { f in
                    f.count >= 5 ? (f[4] == "self" ? "\(f[1]) · this Mac" : "\(f[1]) · \(f[4])") : nil
                }.joined(separator: "\n")
            case 3:
                service = FleetWords.service(value, now: Date())
                serviceLoaded = rows(value).contains { $0.count >= 2 && $0[0] == "loaded" && $0[1] == "yes" }
            case 4:
                conflicts = rows(value).compactMap { f in f.count >= 2 ? (f[0], f[1]) : nil }
            default:
                held = FleetSettingsLoader.heldProfiles(value)
            }
        }
    }

    private func rows(_ text: String) -> [[String]] {
        text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }
}
