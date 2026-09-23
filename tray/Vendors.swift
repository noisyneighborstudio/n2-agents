import Foundation

// The tray's view of the world, parsed from `agents porcelain`.
//
// Deliberately dumb: every rule about what a profile is, which vendors exist,
// and which is active lives in vendors.sh + agents. The
// menu renders whatever the CLI reports, so the two can never drift — the old
// single-vendor app duplicated that discovery in Swift and had to be kept in
// step by hand.

struct Vendor {
    let id: String
    let installed: Bool
    let desktop: String     // "clone" | "launch" | "none"
    let usage: String       // "oauth" | "ondemand" | "none"
    let label: String
    let sessions: String    // transcript layout, "none" when agents can't read them
    let monogram: String    // two-letter tile the panel draws for the lab
    let desktopName: String // its desktop app, "" when it has none
    let desktopBundle: String // that app's bundle id

    var hasUsageAPI: Bool { usage == "oauth" || usage == "ondemand" }
    /// Each read costs something, so it's never polled: read on open or retry.
    var readsOnDemand: Bool { usage == "ondemand" }
    var hasSessions: Bool { sessions != "none" }
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
    /// profile -> vendor -> slot directory / signed-in account, from S rows.
    var slotDirs: [String: [String: String]] = [:]
    var accounts: [String: [String: String]] = [:]
    /// true / false = the slot does / doesn't hold a login; absent = can't tell.
    var signedIn: [String: [String: Bool]] = [:]
    /// The last slot `agents run` started; next best starts after it.
    var lastSlot: (profile: String, vendor: String)?

    func account(_ profile: String, _ vendor: String) -> String? { accounts[profile]?[vendor] }
    func slotDir(_ profile: String, _ vendor: String) -> String? { slotDirs[profile]?[vendor] }

    var installedVendors: [Vendor] { vendors.filter { $0.installed } }
    func vendor(_ id: String) -> Vendor? { vendors.first { $0.id == id } }

    static let empty = Snapshot(vendors: [], profiles: [], active: "Default")

    // Lines are tab-separated records tagged V / P / A. Anything unrecognised is
    // skipped rather than fatal: a newer CLI may emit tags this build predates.
    static func parse(_ text: String) -> Snapshot {
        var vendors: [Vendor] = []
        var profiles: [ProfileRow] = []
        var active = "Default"
        var slotDirs: [String: [String: String]] = [:]
        var accounts: [String: [String: String]] = [:]
        var signedIn: [String: [String: Bool]] = [:]
        var lastSlot: (profile: String, vendor: String)?

        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "V" where f.count >= 6:
                vendors.append(Vendor(id: f[1], installed: f[2] == "1",
                                      desktop: f[3], usage: f[4], label: f[5],
                                      sessions: f.count > 6 ? f[6] : "none",
                                      monogram: f.count > 7 ? f[7] : String(f[1].prefix(2)).uppercased(),
                                      desktopName: f.count > 8 ? f[8] : "",
                                      desktopBundle: f.count > 9 ? f[9] : ""))
            case "P" where f.count >= 4:
                var slots: [String: String] = [:]
                if f[3] != "-" {
                    for pair in f[3].split(separator: ",") {
                        let kv = pair.split(separator: ":", maxSplits: 1).map(String.init)
                        if kv.count == 2 { slots[kv[0]] = kv[1] }
                    }
                }
                profiles.append(ProfileRow(name: f[1], desktopRunning: f[2] == "1", slots: slots))
            case "S" where f.count >= 5:
                slotDirs[f[1], default: [:]][f[2]] = f[3]
                if !f[4].isEmpty { accounts[f[1], default: [:]][f[2]] = f[4] }
                if f.count > 5, f[5] != "unknown" { signedIn[f[1], default: [:]][f[2]] = f[5] == "yes" }
            case "L" where f.count >= 3:
                lastSlot = (f[1], f[2])
            case "A" where f.count >= 2:
                active = f[1]
            default:
                continue
            }
        }
        return Snapshot(vendors: vendors, profiles: profiles, active: active,
                        slotDirs: slotDirs, accounts: accounts, signedIn: signedIn, lastSlot: lastSlot)
    }
}

// One row of `agents sessions --porcelain`: a resumable transcript in some
// profile's slot for some lab, newest first.
struct SessionInfo: Identifiable {
    let profile: String
    let vendor: String
    let sessionID: String
    let mtime: Date
    let cwd: String?
    let snippet: String
    let branch: String?
    /// The lab's own name for it (Claude's ai-title or /rename, Codex's
    /// thread name), when it has one.
    let title: String?

    /// A session id is only unique within one lab, and a list spans them all.
    var id: String { "\(vendor)/\(sessionID)" }

    /// Folder, branch, name and prompt — everything a search can match —
    /// folded once, here, rather than for every row on every keystroke.
    let searchKey: String

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Every token appears somewhere; tokens come from fold(_:).
    func matches(_ tokens: [Substring]) -> Bool {
        tokens.allSatisfy { searchKey.contains($0) }
    }

    static func parse(_ text: String) -> [SessionInfo] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, let epoch = TimeInterval(f[3]) else { return nil }
            func field(_ i: Int) -> String? { f.count > i && !f[i].isEmpty ? f[i] : nil }
            let (cwd, branch, title) = (field(4), field(6), field(7))
            return SessionInfo(profile: f[0], vendor: f[1], sessionID: f[2],
                               mtime: Date(timeIntervalSince1970: epoch),
                               cwd: cwd, snippet: f[5], branch: branch, title: title,
                               searchKey: fold([title, f[5], cwd, branch, f[0], f[1]]
                                   .compactMap { $0 }.joined(separator: "\n")))
        }
    }
}
