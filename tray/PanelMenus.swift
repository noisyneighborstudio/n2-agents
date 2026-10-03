import Foundation

/// A localized string with automatic grammar agreement ("^[3 profile](inflect:
/// true)" → "3 profiles"). String(localized:) leaves that markup as text; only
/// an attributed string resolves it.
/// Agreement is costly to compute, so each distinct sentence is resolved once.
func inflected(_ value: String.LocalizationValue, comment: StaticString) -> String {
    let key = String(localized: value, comment: comment)
    if let done = Inflections.done[key] { return done }
    let resolved = String(AttributedString(localized: value, comment: comment).characters)
    Inflections.done[key] = resolved
    return resolved
}

private enum Inflections {
    nonisolated(unsafe) static var done: [String: String] = [:]
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

    /// The labs a profile is active for, in the snapshot's order.
    static func activeLabs(_ profile: Profile, _ snapshot: Snapshot) -> [Vendor] {
        snapshot.installedVendors.filter { profile.isActive(for: $0.id) }
    }

    /// A card's word for where new sessions go: "Active" on the one active
    /// profile; while labs use different profiles, the labs this one is
    /// active for, which is what the header's Mixed means card by card.
    static func badge(_ profile: Profile, _ snapshot: Snapshot) -> String? {
        if snapshot.active == profile.name { return String(localized: "Active", comment: "The profile new sessions use") }
        guard snapshot.active == "mixed" else { return nil }
        let labs = activeLabs(profile, snapshot)
        switch labs.count {
        case 0: return nil
        case 1: return String(localized: "Active for \(labs[0].label)", comment: "Profile card while labs differ: its one active lab")
        default: return String(localized: "Active for \(labs.count) labs", comment: "Profile card while labs differ: how many labs it is active for")
        }
    }
}
