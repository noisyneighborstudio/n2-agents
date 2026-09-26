import Foundation

@main struct UsageTests {
    static func main() {
        func check(_ value: Bool, _ message: String) {
            if !value { fatalError(message) }
        }
        let old = Usage(fiveHour: 18, sevenDay: 13, resets: nil, note: .ok,
                        sevenResets: nil, fetchedAt: Date(timeIntervalSince1970: 0))
        for note in [Usage.Note.fetchError, .rateLimited] {
            let failed = Usage(fiveHour: nil, sevenDay: nil, resets: nil, note: note, sevenResets: nil)
            let merged = Usage.merge(["Default": old], ["Default": failed])["Default"]!
            check(merged.used == nil && merged.binding == nil, "failed polls must not advertise headroom")
            check(merged.note == note && merged.fetchedAt == old.fetchedAt, "retain failure and original observation time")
            check(Usage.merge(["Default": merged], ["Default": failed])["Default"]!.used == nil,
                  "repeated failure cannot revive stale capacity")
        }
        check(old.used == nil && old.binding == nil, "an aged successful row expires without another poll")
        let fresh = Usage.parse("Default\t20\t80\t-\tok\t-")["Default"]!
        check(fresh.used == 80, "tightest window binds")
        check(Usage.merge(["Default": old], ["Default": fresh])["Default"]!.used == 80, "fresh measurement recovers")
        check(Usage.parse("Default\t-\t-\t-\tok")["Default"]!.used == nil, "empty response is unknown")
        check(Usage.merge(["Removed": old], [:]).isEmpty, "removed profiles do not linger")
        for invalid in ["nan", "inf", "-1", "101", "not-a-number"] {
            check(Usage.parse("Default\t\(invalid)\t-\t-\tok")["Default"]!.used == nil,
                  "invalid percentage must not crash or advertise capacity")
        }
        let now = Date().timeIntervalSince1970
        let hash = String(repeating: "a", count: 64)
        var record: [String: Any] = [
            "schemaVersion": 1, "provider": "claude", "profile": "Default",
            "observedAt": now, "status": "ok",
            "identity": ["status": "verified", "accountHash": hash],
            "windows": [
                ["scope": "five_hour", "usedPercent": 20.0, "resetsAt": now + 3600],
                ["scope": "seven_day", "usedPercent": 30.0, "resetsAt": now + 7200],
                ["scope": "seven_day_opus", "usedPercent": 98.0, "resetsAt": now + 10800],
                ["scope": "custom", "usedPercent": 12.0, "durationSeconds": 1800]
            ], "restrictions": [],
            "credits": ["overage": ["is_enabled": true, "spend_limit_reached": true]]
        ]
        func json(_ value: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
        }
        func read(_ value: [String: Any], provider: String = "claude") -> Usage {
            Usage.parseJSON(json(value), provider: provider)["Default"]!
        }
        var ownerFailure = record
        ownerFailure["provider"] = "codex"
        ownerFailure["status"] = "owner-unavailable"
        ownerFailure["windows"] = []
        ownerFailure["identity"] = ["status": "unknown"]
        let ownerUnavailable = read(ownerFailure, provider: "codex")
        check(ownerUnavailable.note == .ownerUnavailable && ownerUnavailable.used == nil,
              "owner failure has an explicit unavailable state")
        let afterOwnerFailure = Usage.merge(["Default": fresh], ["Default": ownerUnavailable])["Default"]!
        check(afterOwnerFailure.note == .ownerUnavailable && afterOwnerFailure.used == nil && afterOwnerFailure.binding == nil,
              "owner failure cannot retain a healthy capacity gauge")
        ownerFailure["status"] = "migration-pending"
        let pendingMigration = read(ownerFailure, provider: "codex")
        check(pendingMigration.note == .migrationPending && pendingMigration.used == nil && !pendingMigration.maxed,
              "migration has its own unknown-capacity state, not quota exhaustion")
        check(pendingMigration.statusLabel == "migration pending" && pendingMigration.statusExplanation.contains("paused"),
              "migration explanation survives parsing")
        check(ownerUnavailable.statusExplanation.contains("Capacity is unknown") && !ownerUnavailable.maxed,
              "owner failure is distinguished from provider exhaustion")
        let structured = read(record)
        check(structured.windows?.count == 4 && structured.used == 98 && structured.maxed,
              "model-specific buckets must constrain capacity")
        check(structured.binding?.tag == "Opus · 7d" && structured.maxedUntil == Date(timeIntervalSince1970: now + 10800),
              "binding and reset use the actual limiting bucket")
        check(structured.windows?.last?.label == "custom · 30m", "arbitrary window duration survives")
        check(structured.accountHash == hash && structured.accountHelp.contains(hash), "verified account is inspectable")
        check(structured.creditNotes.count == 2, "extra usage retains enabled and spending-limit evidence")
        check(Usage.parseJSON(json(record), provider: "codex").isEmpty, "other provider rows cannot bind")
        let duplicate = Usage.parseJSON([json(record), json(record), json(record)].joined(separator: "\n"), provider: "claude")["Default"]!
        check(duplicate.note == .fetchError && duplicate.used == nil, "all duplicate bindings remain unavailable")
        for invalid: Any in [true, -1, 101, "20"] {
            var bad = record
            bad["windows"] = [["scope": "five_hour", "usedPercent": invalid]]
            check(read(bad).used == nil, "invalid typed percentages cannot advertise capacity")
        }
        for timestamp: Any in [NSNull(), true, "invalid", now + 600, now - 1000] {
            var stale = record; stale["observedAt"] = timestamp
            check(read(stale).used == nil && !read(stale).maxed, "bad or stale timestamp cannot advertise fresh capacity")
        }
        var missingTime = record; missingTime.removeValue(forKey: "observedAt")
        check(!read(missingTime).hasObservationTime, "missing timestamp must not be displayed as an ancient real observation")
        var malformedIdentity = record
        malformedIdentity["identity"] = ["status": "verified", "accountHash": "Default"]
        check(read(malformedIdentity).identityStatus == "unavailable" && read(malformedIdentity).accountHash == nil,
              "profile name is not verified account evidence")
        var loginOnly = record; loginOnly["identity"] = ["status": "login-only", "accountHash": hash]
        check(read(loginOnly).accountHash == nil, "cached login cannot claim a verified usage account")
        record["windows"] = [["scope": "five_hour", "usedPercent": 94.9]]
        check(!read(record).maxed && read(record).availableRemaining == 5, "rounding must not cross the reserve threshold")
        record["windows"] = [["scope": "five_hour", "usedPercent": 95.0, "resetsAt": now + 3600],
                             ["scope": "seven_day", "usedPercent": 100.0]]
        check(read(record).maxed && read(record).maxedUntil == nil, "one unknown limiting reset keeps recovery unknown")
        record["windows"] = [["scope": "five_hour", "usedPercent": 20.0]]
        record["restrictions"] = [["scope": "account", "reason": "provider_rejection"]]
        let restricted = read(record)
        check(restricted.note == .restricted && restricted.maxed && restricted.availableRemaining == 0,
              "provider rejection overrides healthy percentages")
        check(restricted.used == nil && restricted.binding == nil && restricted.maxedUntil == nil,
              "restriction cannot fabricate utilization or reset")
        check(restricted.windows?.first?.percent == 20, "restriction keeps original measured bucket for diagnosis")
        record["restrictions"] = [["scope": "account", "reason": "provider_rejection", "resetsAt": now + 3600]]
        check(read(record).maxedUntil == Date(timeIntervalSince1970: now + 3600), "known restriction reset survives")
        var unexplainedRestriction = record
        unexplainedRestriction["status"] = "restricted"
        unexplainedRestriction["restrictions"] = []
        unexplainedRestriction["windows"] = [["scope": "five_hour", "usedPercent": 100, "resetsAt": now + 3600]]
        check(read(unexplainedRestriction).maxedUntil == nil, "unexplained restriction cannot borrow a bucket reset")
        record["restrictions"] = []; record["windows"] = []
        record["display"] = ["shortUsed": "20", "longUsed": "40"]
        check(read(record).used == nil, "Claude cannot use lossy legacy display columns")
        record["provider"] = "cursor"
        check(read(record, provider: "cursor").used == 40, "other collectors retain measured display fallback")
        record["credits"] = ["overage": ["is_enabled": 1]]
        check(read(record, provider: "cursor").creditNotes.isEmpty, "numeric credit flags are not booleans")
        print("Usage structured observations, freshness, restrictions, and failure tests passed")
    }
}
