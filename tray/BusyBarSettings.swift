import SwiftUI

/// The BUSY Bar switch, its connection line and the optional address and
/// secret. `agents busybar` owns the settings; this view reads its status
/// (nil while loading) and keeps the last values on screen during a refresh.
/// An action disables only its own control.
struct BusyBarSettings: View {
    @State private var status: [String: String]?
    @State private var timedOut = false
    @State private var running: String?
    @State private var address = ""
    @State private var secret = ""

    private var enabled: Bool { status?["enabled"] == "on" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Send events to BUSY Bar", isOn: Binding(get: { enabled }, set: { save(on: $0, key: "switch") }))
                .disabled(status == nil || running == "switch")
            connectionLine.font(.system(size: 11)).foregroundStyle(Ink.secondary)
            DisclosureGroup("Connection") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Address", text: $address, prompt: Text("USB (10.0.4.20)"))
                    SecureField("Password or token", text: $secret,
                                prompt: Text(status?["token"] == "set" ? "Saved" : "None"))
                    Text("Wi-Fi: the bar’s IP and its HTTP access password. Anywhere: api.busy.app and a token from cloud.busy.app.")
                        .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    Button("Save") { save(on: enabled, key: "save") }
                        .disabled(status == nil || running == "save")
                }
                .padding(.top, 6)
            }
            .font(.system(size: 12))
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // The line follows the bar being plugged in or out while Settings is open.
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    @ViewBuilder private var connectionLine: some View {
        if let status {
            let host = status["host"] ?? ""
            switch (status["state"], status["connection"]) {
            case ("connected", "usb"): Text("Connected over USB")
            case ("connected", "cloud"): Text("Connected through BUSY Cloud")
            case ("connected", _): Text("Connected over Wi-Fi")
            case ("unauthorized", _): Text("The BUSY Bar at \(host) refused the password or token")
            default: Text("Not connected. Alerts go to the BUSY Bar at \(host) once it’s reachable.")
            }
        } else if timedOut {
            Text("Couldn’t check the BUSY Bar in time.")
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking the BUSY Bar…") }
        }
    }

    /// `on` plays a hello on the bar, so turning it on or saving shows it works.
    private func save(on: Bool, key: String) {
        guard running == nil else { return }
        running = key
        var args = [on ? "on" : "off"]
        if key == "save" { args += ["--address", address] }
        let input = key == "save" && !secret.isEmpty ? secret : nil
        if input != nil { args.append("--token-stdin") }
        Task {
            let result = await Task.detached { BusyBarCLI.run(args, input: input) }.value
            if result.status == 0 { apply(result.output) }
            secret = ""
            running = nil
        }
    }

    @MainActor private func load() async {
        let result = await Task.detached { BusyBarCLI.run(["status"]) }.value
        if result.output == FleetSettingsLoader.timedOut { timedOut = status == nil } else { apply(result.output) }
    }

    private func apply(_ output: String) {
        let pairs = output.split(separator: "\n").compactMap { line -> (String, String)? in
            let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return f.count == 2 ? (f[0], f[1]) : nil
        }
        let fresh = Dictionary(pairs) { _, b in b }
        guard fresh["enabled"] != nil else { return }
        if status == nil { address = fresh["address"] ?? "" }
        status = fresh
    }
}

enum BusyBarCLI {
    /// `agents busybar <args>`. Synchronous; call off the main thread.
    static func run(_ args: [String], input: String? = nil) -> (status: Int32, output: String) {
        guard let resources = Bundle.main.resourcePath else { return (1, "App resources unavailable") }
        return FleetSettingsLoader.bounded([resources + "/agents", "busybar"] + args,
                                           environment: ProcessInfo.processInfo.environment,
                                           timeout: 30, input: input.map { Data(($0 + "\n").utf8) })
    }
}
