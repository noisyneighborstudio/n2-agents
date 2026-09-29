import Foundation

/// A localized string with automatic grammar agreement ("^[3 profile](inflect:
/// true)" → "3 profiles"). String(localized:) leaves that markup as text; only
/// an attributed string resolves it.
func inflected(_ value: String.LocalizationValue, comment: StaticString) -> String {
    String(AttributedString(localized: value, comment: comment).characters)
}

/// The Active switch's menu, as data: every profile (checked when it's active
/// for every lab it holds), then one submenu per lab listing the profiles that
/// hold it (checked where that lab is active). Choosing a profile makes it
/// active for all its labs; choosing within a lab changes only that lab.
struct ActiveMenu: Equatable {
    struct Choice: Equatable {
        let profile: String
        let vendor: String?     // nil: every lab
        let checked: Bool
    }
    struct Lab: Equatable {
        let vendor: String
        let label: String
        let choices: [Choice]
    }

    let profiles: [Choice]
    let labs: [Lab]

    init(snapshot: Snapshot, profiles: [Profile]) {
        self.profiles = profiles.map { Choice(profile: $0.name, vendor: nil, checked: snapshot.active == $0.name) }
        labs = snapshot.installedVendors.compactMap { v in
            let holders = profiles.filter { $0.slots[v.id] != nil }
            // A lab only one profile holds has nothing to switch.
            guard holders.count > 1 else { return nil }
            return Lab(vendor: v.id, label: v.label,
                       choices: holders.map { Choice(profile: $0.name, vendor: v.id, checked: $0.isActive(for: v.id)) })
        }
    }

    /// What the header says: the one active profile, or that labs differ.
    static func title(_ snapshot: Snapshot) -> String? {
        snapshot.active == "mixed" ? nil : snapshot.active
    }
}
