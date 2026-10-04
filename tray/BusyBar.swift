import Foundation

/// A slot's health change worth showing on a BUSY Bar: a usage tier entered
/// (50, 25, 10% left, out), a lost sign-in, capacity back after running out,
/// or a sign-in restored, which clears its card. `kind` is busybar.py's.
enum BusyBarEvent: Equatable {
    case alert(kind: String, slot: String)
    case clear(slot: String)
}

/// Decides events from successive statuses. A slot's first known status is
/// recorded quietly, so launching the app doesn't replay what is already so.
/// Like the toasts, a tier is news once per tier entered, and a reading back
/// above a tier makes the next dip news again. Not knowing (checking, a
/// failed check) is not recovering: those statuses are skipped.
struct BusyBarWatch {
    private var known: [String: SlotStatus] = [:]
    private var announced: [String: UsageTier] = [:]
    private var announcedVersion: String?

    /// A new N2 Agents build, once per version: Sparkle reports it on every
    /// hourly check until it's installed.
    mutating func isNewUpdate(_ version: String) -> Bool {
        defer { announcedVersion = version }
        return version != announcedVersion
    }

    mutating func update(_ slots: [(id: String, status: SlotStatus)]) -> [BusyBarEvent] {
        var events: [BusyBarEvent] = []
        for (id, status) in slots {
            switch status {
            case .checking, .checkFailed, .unmetered: continue
            case .ready, .low, .out, .signedOut: break
            }
            let tier = UsageTier(status), last = announced[id]
            announced[id] = tier
            guard let was = known.updateValue(status, forKey: id) else { continue }
            if status == .signedOut {
                if was != .signedOut { events.append(.alert(kind: "signedout", slot: id)) }
            } else if was == .signedOut {
                events.append(.clear(slot: id))
            } else if case .out = was, tier != .out {
                events.append(.alert(kind: "back", slot: id))
            } else if let tier, last.map({ tier > $0 }) ?? true {
                events.append(.alert(kind: tier.busyBarKind, slot: id))
            }
        }
        return events
    }
}

extension UsageTier {
    var busyBarKind: String {
        switch self {
        case .half: return "half"
        case .quarter: return "quarter"
        case .low: return "low"
        case .out: return "out"
        }
    }
}

/// One slide of the hourly usage show.
struct BusyBarSlide: Codable, Equatable {
    let title: String
    let left: Int

    /// Every slot with a reading, in panel order. A slot that is out shows 0;
    /// unmetered, signed-out and unknown slots have nothing to show.
    static func from(_ slots: [(title: String, status: SlotStatus)]) -> [BusyBarSlide] {
        slots.compactMap { title, status in
            if case .out = status { return BusyBarSlide(title: title, left: 0) }
            return status.left.map { BusyBarSlide(title: title, left: $0) }
        }
    }
}

/// Due once an hour, in the hour's first minute; a Mac asleep then skips it.
struct HourlyGate {
    private var last: Date?

    mutating func due(_ now: Date, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.minute, from: now) == 0,
              !(last.map { calendar.isDate($0, equalTo: now, toGranularity: .hour) } ?? false) else { return false }
        last = now
        return true
    }
}

/// Sends the watch's events through `agents busybar`, which does nothing while
/// the switch is off. One serial queue keeps cards in order; nothing here
/// waits on the bar, and an unreachable bar only costs that queue a timeout.
/// A sync at launch and every 30 s connects to a bar plugged in later and
/// puts back the card it missed; on the hour, the usage show plays.
final class BusyBarAlerts {
    private var watch = BusyBarWatch()
    private var hourly = HourlyGate()
    private var slides: [BusyBarSlide] = []
    private let queue = DispatchQueue(label: "dev.sethwebster.n2agents.busybar")
    private var timer: Timer?

    init() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        queue.async { _ = BusyBarCLI.run(["sync"]) }
        guard hourly.due(Date()), !slides.isEmpty, let json = try? JSONEncoder().encode(slides) else { return }
        queue.async { _ = BusyBarCLI.run(["slideshow"], input: String(decoding: json, as: UTF8.self)) }
    }

    func updateAvailable(_ version: String) {
        guard watch.isNewUpdate(version) else { return }
        queue.async { _ = BusyBarCLI.run(["alert", "update", "N2 Agents \(version)", "--key", "update"]) }
    }

    func update(_ model: PanelModel) {
        guard let data = model.data else { return }
        var titles: [String: String] = [:], shown: [(title: String, status: SlotStatus)] = []
        let slots = data.profiles.flatMap { p in
            data.slotted(p).map { v -> (id: String, status: SlotStatus) in
                let id = "\(p.name)|\(v.id)", status = model.status(p.name, v).status
                titles[id] = "\(p.name) - \(v.label)"
                shown.append((titles[id]!, status))
                if case .out(let back?) = status {
                    titles[id]! += ", back \(SlotStatus.day(back)) \(back.formatted(.dateTime.hour().minute()))"
                }
                return (id, status)
            }
        }
        slides = BusyBarSlide.from(shown)
        for event in watch.update(slots) {
            let args: [String]
            switch event {
            case .alert(let kind, let slot): args = ["alert", kind, titles[slot] ?? slot, "--key", slot]
            case .clear(let slot): args = ["clear", slot]
            }
            queue.async { _ = BusyBarCLI.run(args) }
        }
    }
}
