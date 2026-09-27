import Foundation

@main struct UsageTests {
    static func main() {
        func check(_ value: Bool, _ message: String) {
            if !value {
                FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
                exit(1)
            }
        }
        let old = Usage(fiveHour: 18, sevenDay: 13, resets: nil, note: .ok,
                        sevenResets: nil, fetchedAt: Date(timeIntervalSince1970: 0))
        check(old.used == nil && old.binding == nil, "expired reading still claims capacity")
        for note in [Usage.Note.fetchError, .rateLimited] {
            let error = Usage(fiveHour: nil, sevenDay: nil, resets: nil, note: note, sevenResets: nil)
            let merged = Usage.merge(["Fixture": old], ["Fixture": error])["Fixture"]!
            check(merged.used == nil && merged.note == note, "row failure revived capacity")
            check(merged.fetchedAt == old.fetchedAt, "failure reset the observation age")
        }
        let now = Date()
        var fresh = old
        fresh.fetchedAt = now
        check(fresh.isFresh(at: now), "current reading should be fresh")
        check(!fresh.isFresh(at: now.addingTimeInterval(Usage.maximumAge)), "expiry boundary")
        check(!fresh.isFresh(at: now.addingTimeInterval(-1)), "future-dated reading")
        let expired = Usage.expire(["Fixture": fresh], at: now.addingTimeInterval(Usage.maximumAge))["Fixture"]!
        check(expired.note == .expired && expired.used == nil, "clock expiry must invalidate displayed data")
        check(expired.fiveHour == 18 && expired.fetchedAt == now, "expiry must retain history")
        check(expired.historyLabel.contains("18%"), "history should identify previous measured value")
        let failed = Usage.merge(["Fixture": fresh], [:], commandFailed: true)
        check(failed["Fixture"]?.note == .fetchError && failed["Fixture"]?.used == nil, "command failure erased history")
        check(failed["Fixture"]?.fetchedAt == now, "command failure reset age")
        check(Usage.merge(failed, [:], commandFailed: true)["Fixture"]?.used == nil, "repeat command failure")
        check(Usage.merge(failed, ["Fixture": fresh])["Fixture"]?.used == 18, "success must recover")
        check(Usage.merge(failed, [:]).isEmpty, "successful profile removal must remove history")
        let firstFailure = Usage.merge([:], [:], commandFailed: true, profiles: ["Fixture"])["Fixture"]!
        check(firstFailure.used == nil && firstFailure.historyLabel == "No successful reading", "first read failure is explicit")
        for status in ["fetch-error", "rate-limited", "no-token"] {
            let row = Usage.parse("Fixture\t-\t-\t-\t\(status)")["Fixture"]!
            check(row.fetchedAt == .distantPast && row.historyLabel == "No successful reading",
                  "first failed row fabricated observation history")
        }
        for invalid in ["nan", "inf", "-1", "101", "invalid"] {
            check(Usage.parse("Fixture\t\(invalid)\t-\t-\tok")["Fixture"]?.used == nil, "invalid percentage")
        }

        for invalid in ["nan", "-1", "101"] {
            check(Usage.parse("Fixture\t\(invalid)\t20\t-\tok")["Fixture"]?.used == nil,
                  "malformed first window must invalidate whole row")
            check(Usage.parse("Fixture\t20\t\(invalid)\t-\tok")["Fixture"]?.used == nil,
                  "malformed second window must invalidate whole row")
        }
        check(Usage.parse("Fixture\t-\t20\t-\tok")["Fixture"]?.used == 20,
              "an absent window is not malformed")
        // The collector's Codex rows: a spent 5h window beside a weekly one at
        // 30%, and a refusal no window accounts for.
        let spent = Usage.parse("Fixture\t100\t30\t2026-09-26T03:24\tok\t2026-09-26T08:24")["Fixture"]!
        check(spent.maxed && spent.sevenDay == 30, "5h exhaustion must not overwrite the weekly figure")
        check(spent.maxedUntil == Date(timeIntervalSince1970: 1790393040), "a spent 5h window returns at its own reset")
        let denied = Usage.parse("Fixture\t-\t80\t-\tlimit-reached\t2026-09-26T08:24")["Fixture"]
        check(denied?.note == .limitReached && denied?.used == nil, "a refusal must not read as capacity")
        func vendor(_ id: String) -> Vendor {
            Vendor(id: id, installed: true, desktop: "none", usage: "oauth",
                   label: id, sessions: "none", monogram: id, desktopName: "",
                   desktopBundle: "", longWindow: "7d")
        }
        let profile = Profile(name: "Fixture", running: false, slots: ["claude": "ok", "codex": "ok"])
        let data = PanelData(snapshot: Snapshot(vendors: [vendor("claude"), vendor("codex")],
                                               profiles: [], active: "Fixture"),
                             profiles: [profile], sessions: [], terminals: [], desktops: [])
        let model = PanelModel()
        model.data = data
        model.usage = ["claude": ["Fixture": fresh], "codex": ["Fixture": expired]]
        check(model.reading(profile, data).state == .usageUnknown, "mixed summary claims ready")
        check(model.reading(profile, data).used == nil && model.remaining == nil, "partial summary advertises headroom")
        model.usage["claude"] = ["Fixture": expired]
        if case .usageUnknown? = model.nextBest {} else { check(false, "expired slots must report usage unavailable") }
        model.usage["claude"] = ["Fixture": fresh]
        model.usage["codex"] = ["Fixture": fresh]
        check(model.reading(profile, data).state == .ready && model.remaining == 82, "complete measurements recover")
        let alias = Usage.parse("Fixture\t-\t-\t-\tshared-login")["Fixture"]!
        model.usage["codex"] = ["Fixture": alias, "Default": fresh]
        check(model.reading(profile, data).state == .ready && model.remaining == 82,
              "shared fresh measurement must not suppress summary")
        check(model.effectiveUsage("Fixture", "codex")?.used == 18, "details must resolve shared measurement")
        model.usage["codex"]?["Default"] = expired
        check(model.reading(profile, data).state == .usageUnknown && model.remaining == nil,
              "shared expired measurement must not claim capacity")
        model.usage["codex"] = ["Fixture": denied!]
        check(model.reading(profile, data).state == .usageUnknown && model.remaining == nil,
              "a refused slot must not claim capacity")
        let fallbackVendor = Vendor(id: "opencode", installed: true, desktop: "none", usage: "none",
                                    label: "Fallback", sessions: "none", monogram: "F",
                                    desktopName: "", desktopBundle: "", longWindow: "7d")
        let fallbackProfile = Profile(name: "Fallback", running: false, slots: ["opencode": "ok"])
        model.data = PanelData(snapshot: Snapshot(vendors: [fallbackVendor, vendor("claude")], profiles: [], active: "Fixture"),
                               profiles: [fallbackProfile, profile], sessions: [], terminals: [], desktops: [])
        if case .slot(_, "claude", .some)? = model.nextBest {} else { check(false, "tray must prefer measured capacity") }
        model.usage["claude"] = ["Fixture": expired]
        if case .slot(_, "opencode", nil)? = model.nextBest {} else { check(false, "tray should expose unmeasured fallback") }
        print("Usage freshness, command failure, expiry, history and summary proofs passed")
    }
}
