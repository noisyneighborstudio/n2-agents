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

/// Sends the watch's events through `agents busybar`, which does nothing while
/// the switch is off. One serial queue keeps cards in order; nothing here
/// waits on the bar, and an unreachable bar only costs that queue a timeout.
final class BusyBarAlerts {
    private var watch = BusyBarWatch()
    private let queue = DispatchQueue(label: "dev.sethwebster.n2agents.busybar")

    func update(_ model: PanelModel) {
        guard let data = model.data else { return }
        var titles: [String: String] = [:]
        let slots = data.profiles.flatMap { p in
            data.slotted(p).map { v -> (id: String, status: SlotStatus) in
                let id = "\(p.name)|\(v.id)", status = model.status(p.name, v).status
                titles[id] = "\(p.name) - \(v.label)"
                if case .out(let back?) = status {
                    titles[id]! += ", back \(SlotStatus.day(back)) \(back.formatted(.dateTime.hour().minute()))"
                }
                return (id, status)
            }
        }
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
