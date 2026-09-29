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
        // Profile note: first match wins, and failed checks are never "All ready".
        let back = Date()
        check(ProfileNote.of([.ready(left: 50), .signedOut, .out(back: back)]).text.hasPrefix("1 signed out"), "sign-outs lead")
        check(ProfileNote.of([.out(back: back), .checkFailed]).text == "1 out · 1 check failed", "out names unchecked beside it")
        check(ProfileNote.of([.low(left: 5), .ready(left: 80)]).tone == .amber, "low is amber")
        check(ProfileNote.of([.checkFailed, .ready(left: 80)]).text == "1 check failed", "a failed check alone is not all ready")
        check(ProfileNote.of([.ready(left: 80), .unmetered]).text == "All ready", "ready and unmetered are all ready")
        check(ProfileNote.of([.ready(left: 80)], pending: 1).tone == .red, "unfinished setup counts as signed out")
        // Tally: every slot lands in at most one count, and checking in none.
        let tally = FleetTally([.ready(left: 80), .low(left: 3), .unmetered, .out(back: nil), .checkFailed, .signedOut, .checking])
        check(tally == { var t = FleetTally([]); t.ready = 3; t.out = 1; t.attention = 2; return t }(), "tally sums the cards")
        // Diagnostics: a restricted slot shows its raw signal; nothing absent is listed.
        let restricted = reading(100, note: .restricted)
        var withReason = restricted; withReason.restrictionReasons = ["primary: rate_limit_reached"]
        let facts = Diagnostics.facts(withReason, shared: false)
        check(facts.contains { $0.key == "Signal" && $0.value == "restricted · primary: rate_limit_reached" }, "raw note shown")
        check(!facts.contains { $0.key == "Account" || $0.key == "Credits" }, "absent facts are omitted")
        check(!facts.contains { $0.value.lowercased().contains("unknown") }, "nothing says unknown")
        check(Diagnostics.facts(nil, shared: false).isEmpty, "no reading, no facts")
        // Suggestion: same profile first, most left, soonest reset; only fresh ready readings.
        let soon = now.addingTimeInterval(3600), later = now.addingTimeInterval(7200)
        func slot(_ p: String, _ v: String, _ s: SlotStatus, _ r: Date? = nil) -> Suggestion.Slot {
            .init(profile: p, vendor: v, status: s, resets: r)
        }
        let fleet = [slot("A", "codex", .out(back: nil)), slot("A", "claude", .ready(left: 60), later),
                     slot("A", "cursor", .ready(left: 60), soon), slot("A", "grok", .ready(left: 40)),
                     slot("B", "claude", .ready(left: 100))]
        let pick = Suggestion.pick(for: "A", vendor: "codex", among: fleet, nextBest: ("B", "claude"))
        check(pick?.vendor == "cursor" && pick?.sameProfile == true, "same profile, most left, soonest reset breaks the tie")
        let unfit = [slot("A", "codex", .out(back: nil)), slot("A", "opencode", .unmetered), slot("A", "muse", .checkFailed),
                     slot("A", "grok", .signedOut), slot("A", "claude", .checking), slot("A", "cursor", .low(left: 5))]
        check(Suggestion.pick(for: "A", vendor: "codex", among: unfit, nextBest: nil) == nil,
              "never unmetered, failed, stale, checking, signed out or low; nil when nothing qualifies")
        check(Suggestion.pick(for: "A", vendor: "codex", among: unfit + [slot("B", "claude", .ready(left: 90))],
                              nextBest: ("B", "claude"))?.sameProfile == false, "falls back to the fleet's next best")
        check(Suggestion.pick(for: "A", vendor: "codex", among: unfit + [slot("B", "opencode", .unmetered)],
                              nextBest: ("B", "opencode")) == nil, "an unmetered next best is not a suggestion")
        check(Suggestion.pick(for: "A", vendor: "claude", among: [slot("A", "claude", .ready(left: 90))], nextBest: ("A", "claude")) == nil,
              "a slot is never its own suggestion")

        // Switch navigates and nothing else: no session starts, no account binding changes.
        let model = PanelModel()
        let snapshot = Snapshot(vendors: [codex], profiles: [], active: "A", signedIn: ["A": ["codex": true]])
        model.data = PanelData(snapshot: snapshot, profiles: [], sessions: [], terminals: [], desktops: [])
        model.path = [.profile("A"), .provider(profile: "A", vendor: "codex")]
        model.switchTo(Suggestion(profile: "A", vendor: "cursor", left: 60, resets: nil, sameProfile: true))
        check(model.path == [.profile("A"), .provider(profile: "A", vendor: "cursor")], "Switch within a profile replaces the page")
        model.switchTo(Suggestion(profile: "B", vendor: "claude", left: 90, resets: nil, sameProfile: false))
        check(model.path == [.profile("B"), .provider(profile: "B", vendor: "claude")], "Switch across profiles goes through its profile")
        check(model.data?.snapshot.active == "A" && model.data?.snapshot.signedIn["A"]?["codex"] == true,
              "Switch leaves the active profile and every binding as they were")
        // Toast ladder: once per tier entered, the worst on a jump, re-announced after recovery.
        func warn(_ left: Int) -> UsageWarning {
            let st: SlotStatus = left == 0 ? .out(back: nil) : left < 20 ? .low(left: left) : .ready(left: left)
            return UsageWarning(profile: "A", vendor: "codex", status: st, tier: UsageTier(st)!, window: nil)
        }
        var ladder = ToastLadder()
        let id: Set<String> = ["A|codex"]
        check(UsageTier(.ready(left: 51)) == nil && UsageTier(.ready(left: 50)) == .half, "50 left is the first tier")
        check(UsageTier(.ready(left: 25)) == .quarter && UsageTier(.low(left: 10)) == .low && UsageTier(.low(left: 11)) == .quarter, "tier edges")
        check([UsageTier(.unmetered), UsageTier(.checkFailed), UsageTier(.signedOut), UsageTier(.checking)].allSatisfy { $0 == nil },
              "unknown, failed, unmetered and signed-out never warn")
        check(ladder.update([warn(48)], measured: id).map(\.tier) == [.half], "entering half announces")
        check(ladder.update([warn(45)], measured: id).isEmpty, "the same tier again is quiet")
        check(ladder.update([warn(8)], measured: id).map(\.tier) == [.low], "a jump past quarter announces only low")
        check(ladder.update([warn(8)], measured: []).isEmpty && ladder.update([], measured: []).isEmpty,
              "no fresh reading keeps the record: not knowing is not recovering")
        check(ladder.update([warn(8)], measured: id).isEmpty, "back to a known reading at the same tier is quiet")
        check(ladder.update([], measured: id).isEmpty, "recovering above 50 is quiet")
        check(ladder.update([warn(40)], measured: id).map(\.tier) == [.half], "dipping again re-announces")
        check(ladder.update([warn(0)], measured: id).map(\.tier) == [.out], "running out announces out")
        check(ladder.update([warn(30)], measured: id).isEmpty && ladder.update([warn(20)], measured: id).map(\.tier) == [.quarter],
              "recovering to a lesser tier lowers the record, so the next dip announces")

        // Pace: needs the window's length and reset; never estimated without them.
        let week = 7 * 86400.0
        let midweek = Usage.Window(scope: "seven_day", percent: 75, resets: now.addingTimeInterval(week * 0.4), durationSeconds: week)
        let pace = Pace(midweek, now: now)
        check(pace != nil && abs(pace!.elapsed - 0.6) < 0.001 && pace!.used == 0.75, "elapsed and used from the window")
        check(pace?.lastsToReset == false && pace!.sentence.hasPrefix("You’re ahead of pace"), "75% used at 60% gone is ahead of pace")
        check(Pace(.init(scope: "seven_day", percent: 30, resets: now.addingTimeInterval(week * 0.4), durationSeconds: week), now: now)?.lastsToReset == true,
              "30% used at 60% gone lasts to the reset")
        check(Pace(.init(scope: "seven_day", percent: 75, resets: nil, durationSeconds: week), now: now) == nil, "no reset, no pace")
        check(Pace(.init(scope: "seven_day", percent: 75, resets: now.addingTimeInterval(3600), durationSeconds: nil), now: now) == nil,
              "no window length, no pace")
        check(Pace(nil) == nil, "no window, no pace")
        // Active menu: every profile, then a submenu per lab two or more profiles hold.
        func lab(_ id: String) -> Vendor {
            Vendor(id: id, installed: true, desktop: "none", usage: "oauth", label: id.capitalized,
                   sessions: "none", monogram: "", desktopName: "", desktopBundle: "", longWindow: "7d")
        }
        let work = Profile(name: "Work", running: false, slots: ["claude": "active", "codex": "ok"])
        let home = Profile(name: "Home", running: false, slots: ["claude": "ok", "codex": "active", "grok": "active"])
        let menu = ActiveMenu(snapshot: Snapshot(vendors: [lab("claude"), lab("codex"), lab("grok")], profiles: [], active: "mixed"),
                              profiles: [work, home])
        check(menu.profiles.map(\.profile) == ["Work", "Home"] && menu.profiles.allSatisfy { !$0.checked },
              "mixed: every profile listed, none checked")
        check(menu.labs.map(\.vendor) == ["claude", "codex"], "a lab only one profile holds has no submenu")
        check(menu.labs[0].choices == [.init(profile: "Work", vendor: "claude", checked: true),
                                       .init(profile: "Home", vendor: "claude", checked: false)], "each lab checks its active profile")
        check(ActiveMenu.title(Snapshot(vendors: [], profiles: [], active: "mixed")) == nil
              && ActiveMenu.title(Snapshot(vendors: [], profiles: [], active: "Work")) == "Work", "the header names one profile or none")
        // Session filters: scope by profile, lab, both; search tokens; newest first, each once.
        func sess(_ p: String, _ v: String, _ id: String, _ age: TimeInterval, _ title: String) -> SessionInfo {
            SessionInfo.parse("\(p)\t\(v)\t\(id)\t\(now.timeIntervalSince1970 - age)\t/Users/me/n2\t\(title)\tmain\t\(title)").first!
        }
        let all = [sess("Work", "codex", "1", 300, "fix build"), sess("Work", "claude", "2", 100, "write docs"),
                   sess("Home", "codex", "3", 200, "fix login"), sess("Work", "codex", "1", 300, "fix build")]
        check(SessionInfo.filter(all).map(\.sessionID) == ["2", "3", "1"], "newest first, duplicates once")
        check(SessionInfo.filter(all, profile: "Work").map(\.sessionID) == ["2", "1"], "one profile")
        check(SessionInfo.filter(all, vendor: "codex").map(\.sessionID) == ["3", "1"], "one lab")
        check(SessionInfo.filter(all, profile: "Work", vendor: "codex").map(\.sessionID) == ["1"], "profile and lab")
        check(SessionInfo.filter(all, query: "FIX").map(\.sessionID) == ["3", "1"], "search folds case")
        check(SessionInfo.filter(all, profile: "Home", query: "docs").isEmpty, "filters and search combine")
        // Task vocabulary: every state has its own shape; unreachable is waiting, not failed.
        func task(_ st: FleetTask.State, rc: String = "") -> FleetTask {
            FleetTask(id: "t", state: st, vendor: "", rc: rc, label: "", machine: "", role: "dispatcher")
        }
        let looks = [task(.queued), task(.preparing), task(.running), task(.done), task(.done, rc: "2"),
                     task(.failed), task(.disconnected), task(.unknown)]
        check(Set(looks.map(\.symbol)).count == looks.count && looks[1].symbol == task(.transferring).symbol,
              "each look has its own symbol (preparing and sending share one)")
        check(task(.disconnected).look == .notAnswering && task(.disconnected).look != .failed, "unreachable is not failed")
        check(task(.done, rc: "2").look == .doneWithExit && task(.done, rc: "0").look == .done, "an exit code is not success")
        var f = FleetData()
        f.tasks = [task(.running), task(.running), task(.failed), task(.done)]
        check(f.taskSummary.map(\.count) == [2, 1] && f.taskSummary.map(\.look) == [.running, .failed], "header counts what's live or failed")
        print("slot status tests passed")
    }
}
