import Foundation

@main struct BusyBarTests {
    static func main() {
        func check(_ got: [BusyBarEvent], _ want: [BusyBarEvent], _ message: String) {
            if got != want { fatalError("\(message): got \(got), want \(want)") }
        }
        let a = "Work|claude", b = "Home|codex"
        let back = Date().addingTimeInterval(3600)
        var watch = BusyBarWatch()

        // What is already so at launch stays quiet, including a slot already out.
        check(watch.update([(a, .ready(left: 80)), (b, .out(back: back))]), [], "first sight is recorded quietly")
        check(watch.update([(a, .checking), (b, .checkFailed)]), [], "not knowing is not news")

        // Each tier once, and a jump announces only the tier it lands in.
        check(watch.update([(a, .ready(left: 45))]), [.alert(kind: "half", slot: a)], "50% left")
        check(watch.update([(a, .ready(left: 40))]), [], "same tier again")
        check(watch.update([(a, .low(left: 8))]), [.alert(kind: "low", slot: a)], "jump past 25% to 10%")
        check(watch.update([(a, .out(back: back))]), [.alert(kind: "out", slot: a)], "out")
        check(watch.update([(a, .out(back: back.addingTimeInterval(60)))]), [], "still out")

        // Capacity back after running out, even when a failed check came between.
        check(watch.update([(a, .checkFailed)]), [], "a failed check while out")
        check(watch.update([(a, .ready(left: 100)), (b, .ready(left: 30))]),
              [.alert(kind: "back", slot: a), .alert(kind: "back", slot: b)], "back with capacity")
        // Recovering above a tier makes the next dip news again.
        check(watch.update([(a, .ready(left: 49))]), [.alert(kind: "half", slot: a)], "next dip after recovery")

        // A lost sign-in shows once and its return clears it, without a tier alert on top.
        check(watch.update([(b, .signedOut)]), [.alert(kind: "signedout", slot: b)], "signed out")
        check(watch.update([(b, .signedOut)]), [], "still signed out")
        check(watch.update([(b, .ready(left: 20))]), [.clear(slot: b)], "signed back in")
        check(watch.update([(b, .ready(left: 15))]), [], "tier recorded on sign-in")

        // Unmetered labs have nothing to say.
        check(watch.update([("Home|opencode", .unmetered), ("Home|opencode", .unmetered)]), [], "unmetered")
        // The usage show: slots with a reading, out as 0, the rest left out.
        let slides = BusyBarSlide.from([("Work - Claude Code", .ready(left: 82)), ("Work - Codex", .out(back: nil)),
                                        ("Home - Grok", .low(left: 8)), ("Home - opencode", .unmetered),
                                        ("Home - Muse", .signedOut), ("Home - Cursor", .checking),
                                        ("Home - Codex", .checkFailed)])
        if slides != [BusyBarSlide(title: "Work - Claude Code", left: 82), BusyBarSlide(title: "Work - Codex", left: 0),
                      BusyBarSlide(title: "Home - Grok", left: 8)] { fatalError("slides: \(slides)") }

        // On the hour, once: not at :30, not twice in the hour's first minute.
        var gate = HourlyGate()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: h, minute: m, second: s))!
        }
        let ticks = [(at(9, 59, 30), false), (at(10, 0, 5), true), (at(10, 0, 35), false), (at(10, 30), false),
                     (at(11, 0, 20), true), (at(11, 1), false)]
        for (date, due) in ticks where gate.due(date, calendar: calendar) != due { fatalError("gate at \(date)") }

        // A new build shows once per version, however often Sparkle reports it.
        if !watch.isNewUpdate("1.6.0") { fatalError("first report of a version") }
        if watch.isNewUpdate("1.6.0") { fatalError("same version twice") }
        if !watch.isNewUpdate("1.6.1") { fatalError("next version") }
        print("BusyBarTests passed")
    }
}
