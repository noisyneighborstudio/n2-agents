import SwiftUI

struct AccountOwnershipStatus {
    let state: String
    let account: String?
    let owner: String?
    let detail: String

    static func parse(status: Int32, output: String) -> Self {
        func unavailable(_ reason: String) -> Self {
            Self(state: "unavailable", account: nil, owner: nil, detail: reason)
        }
        guard status == 0 else { return unavailable(String(output.prefix(500))) }
        guard let data = output.data(using: .utf8),
              let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = row["status"] as? String else {
            return unavailable("Ownership status could not be read.")
        }
        let messages = [
            "active": "Active authentication grant. Usage limits still apply.",
            "remote-owner": "Managed by another machine. Its availability has not been checked.",
            "retired": "This authentication grant has been retired.",
            "renewing": "The owner is renewing this authentication grant.",
            "reauth-required": "The owner requires a new sign-in.",
            "pending-login": "The owner is waiting for sign-in.",
            "migration-pending": "Credential migration is pending. New work is paused.",
            "migration-invalid": "Credential migration needs repair.",
            "conflicting": "Account ownership has conflicting changes.",
            "binding-mismatch": "The profile binding does not match the owner's grant."
        ]
        guard let detail = messages[state] else { return unavailable("Unrecognized ownership state.") }
        if ["migration-pending", "migration-invalid", "conflicting"].contains(state) {
            return Self(state: state, account: nil, owner: nil, detail: detail)
        }
        guard let binding = row["binding"] as? [String: Any],
              binding["provider"] as? String == "codex",
              let account = binding["accountHash"] as? String, account.count == 64,
              account.allSatisfy({ "0123456789abcdef".contains($0) }),
              let owner = binding["owner"] as? String, owner.hasPrefix("SHA256:"), owner.count <= 64 else {
            return unavailable("Ownership binding is missing or invalid.")
        }
        return Self(state: state, account: account, owner: owner, detail: detail)
    }
}

@MainActor final class AccountOwnershipInspector: ObservableObject {
    @Published private(set) var result: AccountOwnershipStatus?
    @Published private(set) var loading = false
    private var request = UUID()

    func refresh(profile: String,
                 run: @escaping @Sendable ([String]) -> (status: Int32, output: String)) async {
        let current = UUID()
        request = current; result = nil; loading = true
        let response = await Task.detached { run(["auth", "status", profile]) }.value
        guard request == current, !Task.isCancelled else { return }
        result = AccountOwnershipStatus.parse(status: response.status, output: response.output)
        loading = false
    }
}

struct AccountOwnershipDetails: View {
    let profile: String
    let result: AccountOwnershipStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Account ownership · \(profile)").fontWeight(.medium)
            Text(result.detail)
            if let owner = result.owner {
                Text("Owner ID: \(owner)").textSelection(.enabled)
            }
            if let account = result.account {
                Text("Account fingerprint: \(account)").textSelection(.enabled)
            }
            Text("Authentication state is separate from available usage.").foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
    }
}

struct AccountOwnershipView: View {
    let profile: String
    @StateObject private var inspector = AccountOwnershipInspector()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if inspector.loading { ProgressView("Reading ownership…").controlSize(.small) }
            if let result = inspector.result { AccountOwnershipDetails(profile: profile, result: result) }
            Button("Refresh ownership") { Task { await refresh() } }.disabled(inspector.loading)
        }
        .task(id: profile) { await refresh() }
    }

    private func refresh() async {
        await inspector.refresh(profile: profile) { FleetSettingsLoader.command($0) }
    }
}
