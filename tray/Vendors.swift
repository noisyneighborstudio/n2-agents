import Foundation

// The tray's view of the world, parsed from `agents porcelain`.
//
// Deliberately dumb: every rule about what a profile is, which vendors exist,
// how each one isolates and which is active lives in vendors.sh + agents. The
// menu renders whatever the CLI reports, so the two can never drift — the old
// single-vendor app duplicated that discovery in Swift and had to be kept in
// step by hand.

struct Vendor {
    let id: String
    let installed: Bool
    let isolation: String   // "env" — concurrent, pinned per process; "swap" — one at a time
    let desktop: String     // "clone" | "launch" | "none"
    let usage: String       // "oauth" | "none"
    let label: String

    var hasUsageAPI: Bool { usage == "oauth" }
    var clonesDesktopApp: Bool { desktop == "clone" }
}

struct ProfileRow {
    let name: String
    let desktopRunning: Bool
    /// vendor id -> "active" | "ok". Absent means this profile has no slot for it.
    let slots: [String: String]

    var vendors: [String] { slots.keys.sorted() }
    func isActive(for vendor: String) -> Bool { slots[vendor] == "active" }
}

struct Snapshot {
    let vendors: [Vendor]
    let profiles: [ProfileRow]
    let active: String

    var installedVendors: [Vendor] { vendors.filter { $0.installed } }
    func vendor(_ id: String) -> Vendor? { vendors.first { $0.id == id } }

    static let empty = Snapshot(vendors: [], profiles: [], active: "Default")

    // Lines are tab-separated records tagged V / P / A. Anything unrecognised is
    // skipped rather than fatal: a newer CLI may emit tags this build predates.
    static func parse(_ text: String) -> Snapshot {
        var vendors: [Vendor] = []
        var profiles: [ProfileRow] = []
        var active = "Default"

        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "V" where f.count >= 7:
                vendors.append(Vendor(id: f[1], installed: f[2] == "1", isolation: f[3],
                                      desktop: f[4], usage: f[5], label: f[6]))
            case "P" where f.count >= 4:
                var slots: [String: String] = [:]
                if f[3] != "-" {
                    for pair in f[3].split(separator: ",") {
                        let kv = pair.split(separator: ":", maxSplits: 1).map(String.init)
                        if kv.count == 2 { slots[kv[0]] = kv[1] }
                    }
                }
                profiles.append(ProfileRow(name: f[1], desktopRunning: f[2] == "1", slots: slots))
            case "A" where f.count >= 2:
                active = f[1]
            default:
                continue
            }
        }
        return Snapshot(vendors: vendors, profiles: profiles, active: active)
    }
}

// One line of `agents setup --porcelain`:
//   S <vendor> <installed 0|1> <absent|real|linked> <signed-in 1|0|?> <label> <install hint>
//
// "real" means the vendor's dot dir is still a plain directory — a login N2
// Agents doesn't manage yet. "linked" means it is a symlink into a profile
// slot. "?" is a vendor that keeps its token where nothing on disk can see it.
struct SetupRow {
    let id: String
    let installed: Bool
    let state: String
    let signedIn: String
    let label: String
    let installHint: String

    enum Action {
        case install(hint: String)
        case adopt
        case signIn

        var title: String {
            switch self {
            case .install: return "Install…"
            case .adopt: return "Bring In"
            case .signIn: return "Sign In…"
            }
        }
    }

    var isReady: Bool { installed && state == "linked" && signedIn != "0" }

    // Exactly one thing to do next per row, or nothing when it is ready.
    var action: Action? {
        if !installed { return .install(hint: installHint) }
        if state == "real" { return .adopt }
        if signedIn == "0" || signedIn == "?" { return .signIn }
        return nil
    }

    var detail: String {
        if !installed { return "Not installed" }
        let login: String
        switch signedIn {
        case "1": login = "Signed in"
        case "?": login = "Sign-in state unknown"
        default: login = "Not signed in"
        }
        switch state {
        case "linked": return signedIn == "1" ? "Ready" : login
        case "real": return "\(login) · not managed yet"
        default: return "Never run"
        }
    }

    static func parse(_ text: String) -> [SetupRow] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, f[0] == "S" else { return nil }
            return SetupRow(id: f[1], installed: f[2] == "1", state: f[3], signedIn: f[4],
                            label: f[5], installHint: f[6])
        }
    }
}
