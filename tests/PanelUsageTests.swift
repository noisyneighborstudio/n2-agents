import Foundation

@main struct PanelUsageTests {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            if !condition { fatalError(message) }
        }
        let vendors = ["claude", "codex"].map {
            Vendor(id: $0, installed: true, desktop: "none", usage: "oauth", label: $0,
                   sessions: "none", monogram: "", desktopName: "", desktopBundle: "", longWindow: "7d")
        }
        let profile = Profile(name: "Default", running: false, slots: ["claude": "ok", "codex": "ok"])
        let data = PanelData(snapshot: Snapshot(vendors: vendors, profiles: [], active: "Default"),
                             profiles: [profile], sessions: [], terminals: [], desktops: [])
        let model = PanelModel()
        model.data = data
        let healthy = Usage(fiveHour: 20, sevenDay: 30, resets: nil, note: .ok, sevenResets: nil)
        let restricted = Usage(fiveHour: nil, sevenDay: nil, resets: nil, note: .restricted, sevenResets: nil)
        model.usage = ["claude": ["Default": restricted], "codex": ["Default": healthy]]
        check(model.remaining == 0, "restricted slot must affect overall headroom despite healthy sibling")
        check(model.reading(profile, data).state == .labsOut(out: 1, of: 2, until: nil),
              "profile must name its blocked provider")
        check(model.reading(profile, data).used == 30, "restriction must not invent utilization")
        if case .slot(let name, let vendor, let used) = model.nextBest {
            check(name == "Default" && vendor == "codex" && used == 30, "choose healthy sibling")
        } else { fatalError("healthy sibling must remain selectable") }
        check(model.lowQuota.contains { $0.id == "Default/claude" && $0.left == 0 },
              "blocked provider must appear in low-capacity notices")
        model.usage["codex"] = ["Default": restricted]
        check(model.reading(profile, data).state == .allOut(until: nil), "all restrictions mean all out")
        check(model.reading(profile, data).used == nil, "all restricted does not mean measured 100 percent")
        if case .allMaxed(let reset) = model.nextBest {
            check(reset == nil, "unknown reset cannot become a recovery promise")
        } else { fatalError("restricted accounts are exhausted, not signed out") }
        var stale = healthy; stale.fetchedAt = .distantPast
        model.usage = ["claude": ["Default": stale], "codex": ["Default": stale]]
        check(model.remaining == nil && model.reading(profile, data).state == .usageUnknown,
              "stale observations must leave summary capacity unknown")
        if case .usageUnavailable = model.nextBest {} else { fatalError("unknown usage is not signed out") }
        model.usage["claude"] = ["Default": restricted]
        if case .usageUnavailable = model.nextBest {} else { fatalError("restricted plus unknown is not all exhausted") }
        model.usage["codex"] = [:]
        if case .usageUnavailable = model.nextBest {} else { fatalError("missing reading is unknown") }
        let unavailable = Usage(fiveHour: nil, sevenDay: nil, resets: nil, note: .ownerUnavailable, sevenResets: nil)
        model.usage = ["claude": ["Default": unavailable], "codex": ["Default": healthy]]
        check(model.remaining == nil, "healthy sibling cannot make incomplete overall coverage look healthy")
        check(model.reading(profile, data).used == nil, "incomplete profile must not draw a summary capacity gauge")
        check(model.measurementCoverage.known == 1 && model.measurementCoverage.expected == 2,
              "summary reports actual measurement coverage")
        check(model.capacitySummary.contains("1 of 2"), "unknown summary names missing coverage")
        if case .slot(_, let vendor, _) = model.nextBest { check(vendor == "codex", "healthy provider still selectable") }
        else { fatalError("partial unknown must not disable healthy work") }
        model.usage["codex"] = ["Default": restricted]
        check(model.remaining == 0 && model.capacitySummary.contains("At least one"),
              "unknown capacity must not hide a known restriction")
        model.usage["claude"] = ["Default": healthy]
        check(model.remaining == 0, "complete coverage retains known rejection")
        print("Native panel restriction, summary, and next-agent tests passed")
    }
}
