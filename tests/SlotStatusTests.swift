import Foundation

@main struct SlotStatusTests {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            if !condition { fatalError(message) }
        }
        func vendor(_ usage: String = "oauth") -> Vendor {
            Vendor(id: "codex", installed: true, desktop: "none", usage: usage, label: "Codex",
                   sessions: "none", monogram: "CO", desktopName: "", desktopBundle: "", longWindow: "7d")
        }
        let now = Date()
        let reset = now.addingTimeInterval(3 * 86400)
        func reading(_ used: Double, note: Usage.Note = .ok, at: Date = now) -> Usage {
            var u = Usage(fiveHour: nil, sevenDay: nil, resets: nil, note: note, sevenResets: nil, fetchedAt: at,
                          windows: [.init(scope: "seven_day", percent: used, resets: reset)])
            if note == .restricted { u.restrictionResets = [reset] }
            return u
        }
        let codex = vendor()
        func status(_ u: Usage?, _ v: Vendor? = nil, signedIn: Bool? = true, checking: Bool = false) -> SlotStatus {
            SlotStatus.of(u, vendor: v ?? codex, signedIn: signedIn, checking: checking, now: now)
        }

        // Every note, fresh: only ok and restricted may carry a figure, and
        // only ok may carry a percentage.
        for note in Usage.Note.allCases {
            let s = status(reading(40, note: note))
            let expected: SlotStatus
            switch note {
            case .ok: expected = .ready(left: 60)
            case .restricted: expected = .out(back: reset)
            case .noUsageAPI: expected = .unmetered
            case .expired, .rateLimited, .fetchError: expected = .checkFailed
            case .staleToken, .noToken: expected = .signedOut
            case .sharedLogin: expected = .checkFailed
            case .credentialOverride, .credentialStoreUnavailable, .ownerUnavailable, .migrationPending:
                expected = .checkFailed
            }
            check(s == expected, "\(note.rawValue) mapped to \(s), expected \(expected)")
            check(note == .ok || s.left == nil, "\(note.rawValue) must never show a percentage")
            // Stale: no note ever yields a percentage or an out date from an old reading.
            let stale = status(reading(40, note: note, at: now.addingTimeInterval(-Usage.maximumAge - 1)))
            check(stale.left == nil, "stale \(note.rawValue) must never show a percentage")
            if case .out = stale { fatalError("stale \(note.rawValue) must not claim a return time") }
        }

        // Bands of the binding (least remaining) window.
        check(status(reading(0)) == .ready(left: 100), "unused is ready")
        check(status(reading(80)) == .ready(left: 20), "20 left is still ready")
        check(status(reading(81)) == .low(left: 19), "19 left is low")
        check(status(reading(99)) == .low(left: 1), "1 left is low")
        check(status(reading(100)) == .out(back: reset), "nothing left is out until the window resets")
        var two = reading(30)
        two.windows?.append(.init(scope: "five_hour", percent: 90, resets: nil))
        check(status(two) == .low(left: 10), "the window with least left binds")

        // Precedence and absence.
        check(status(reading(10), signedIn: false) == .signedOut, "a known sign-out outranks any reading")
        check(status(reading(10), vendor("none")) == .unmetered, "a lab with no usage API is unmetered")
        check(status(nil, vendor("none"), signedIn: false) == .signedOut, "signed out outranks unmetered")
        check(status(nil, vendor("none")).left == nil, "unmetered never shows a percentage")
        check(status(nil, checking: true) == .checking, "no reading while one runs is checking")
        check(status(nil) == .checkFailed, "no reading and none running is a failed check")
        var unknownReturn = reading(100, note: .restricted)
        unknownReturn.restrictionResets = [nil]
        check(status(unknownReturn) == .out(back: nil), "an unknown return is omitted, not guessed")

        // Labels and strip values say what's left, never what's used.
        check(SlotStatus.ready(left: 32).stripValue == SlotStatus.percent(32), "strip shows the remaining percent")
        check(SlotStatus.checkFailed.stripValue == "?" && SlotStatus.unmetered.stripValue == "—", "unknowns have no figure")
        check(!SlotStatus.low(left: 12).label.contains("used"), "rows say left, not used")
        print("slot status tests passed")
    }
}
