import Foundation

@main struct SlotMeasurementTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func parse(windows: [[String: Any]], status: String = "ok", restrictions: [[String: Any]] = [],
                   age: Double = 0, provider: String = "codex", display: [String: Any] = [:]) throws -> SlotMeasurement {
            let data = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "provider": provider, "profile": "Default", "status": status,
                "observedAt": now.addingTimeInterval(-age).timeIntervalSince1970,
                "windows": windows, "restrictions": restrictions, "display": display
            ])
            return SlotMeasurement.parse(String(decoding: data, as: UTF8.self), now: now)!
        }
        let healthy: [String: Any] = ["scope": "primary", "usedPercent": 10]
        let full: [String: Any] = ["scope": "custom:model", "usedPercent": 99, "resetsAt": now.addingTimeInterval(100).timeIntervalSince1970]
        let custom = try parse(windows: [healthy, full])
        precondition(custom.status == "local-reserve" && custom.used == 99 && custom.resets == now.addingTimeInterval(100))
        let unknownReset = try parse(windows: [full, ["usedPercent": 100]])
        precondition(unknownReset.resets == nil)
        let explicit = try parse(windows: [healthy], restrictions: [["scope": "account", "reason": "blocked"]])
        precondition(explicit.status == "restricted" && explicit.resets == nil)
        let retry = try parse(windows: [healthy], restrictions: [["scope": "execution", "reason": "quota-rejected", "resetsAt": now.addingTimeInterval(100).timeIntervalSince1970]])
        precondition(retry.status == "restricted" && retry.resets == now.addingTimeInterval(100))
        for invalid: Any in [true, -1, 101, "20", NSNull()] {
            let result = try parse(windows: [healthy, ["usedPercent": invalid]])
            precondition(result.status == "fetch-error", "invalid bucket cannot advertise headroom")
        }
        let old = try parse(windows: [healthy], age: 901)
        let future = try parse(windows: [healthy], age: -301)
        precondition(old.status == "stale-measurement" && future.used == nil)
        let missing = try parse(windows: [], display: ["shortUsed": "5"])
        precondition(missing.status == "fetch-error", "Codex must not fall back to lossy display fields")
        let legacy = try parse(windows: [], provider: "muse", display: ["shortUsed": "5", "longUsed": "20"])
        precondition(legacy.status == "ok" && legacy.used == 20)
        for invalid: Any in [true, -1, 101, "garbage", "nan"] {
            let result = try parse(windows: [], provider: "muse", display: ["shortUsed": 20, "longUsed": invalid])
            precondition(result.status == "fetch-error", "invalid fallback bucket cannot advertise headroom")
        }
        for absent: Any in [NSNull(), "-"] {
            let result = try parse(windows: [], provider: "muse", display: ["shortUsed": 20, "longUsed": absent])
            precondition(result.status == "ok" && result.used == 20)
        }
        let failed = try parse(windows: [healthy], status: "fetch-error")
        precondition(failed.used == nil)
        let restricted = try parse(windows: [], status: "restricted")
        precondition(restricted.status == "restricted")
        let unexplained = try parse(windows: [full], status: "restricted")
        precondition(unexplained.resets == nil, "a restriction cannot borrow an unrelated window reset")
        precondition(SlotMeasurement.date("2027-01-15T08:00:00.123Z") != nil)
        precondition(SlotMeasurement.parse("not JSON", now: now) == nil)
        print("Structured slot measurement tests passed")
    }
}
