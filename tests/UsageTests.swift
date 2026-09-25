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
        print("Usage freshness and failure tests passed")
    }
}
