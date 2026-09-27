import Foundation
import Dispatch

struct DispatchQueue {
    static let group = DispatchGroup()
    static var main: Self { Self() }
    func async(execute body: @escaping () -> Void) {
        Self.group.enter()
        Dispatch.DispatchQueue.main.async { body(); Self.group.leave() }
    }
}
struct Bundle { static let main = Bundle(); let bundleIdentifier: String? = "fixture" }
struct UNAuthorizationOptions: OptionSet { let rawValue: Int; static let alert = Self(rawValue: 1); static let sound = Self(rawValue: 2) }
struct UNNotificationSound { static let `default` = Self() }
final class UNMutableNotificationContent { var title = ""; var body = ""; var subtitle = ""; var sound: UNNotificationSound? }
struct UNNotificationRequest { let identifier: String; let content: UNMutableNotificationContent; let trigger: Int? }
final class UNUserNotificationCenter {
    static let center = UNUserNotificationCenter()
    static func current() -> UNUserNotificationCenter { center }
    var authorizations: [(Bool, Error?) -> Void] = []
    var submissions: [(UNNotificationRequest, ((Error?) -> Void)?)] = []
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping (Bool, Error?) -> Void) { authorizations.append(completionHandler) }
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)? = nil) { submissions.append((request, completionHandler)) }
}
final class PanelModel {
    var fleetNotificationError: String? { didSet { precondition(Thread.isMainThread) } }
}
final class AppDelegate {
    let model = PanelModel()
    var announcer = FleetAnnouncer()
    var notificationAttempt: UUID?
    // PRODUCTION_METHOD
}
@main struct NotificationTests {
    static let app = AppDelegate()
    static let center = UNUserNotificationCenter.current()
    static let failure = NSError(domain: "synthetic", code: 1)
    static var notices: [FleetNotice] = []
    static var step = 0
    static var delayed: ((Error?) -> Void)?
    static func fresh(_ kind: FleetNotice.Kind = .done) {
        notices.append(FleetNotice(at: Date(timeIntervalSince1970: Double(notices.count + 1)), kind: kind, task: "task", machine: "Peer", text: "Activity retained"))
        app.announce(notices)
    }
    static func next() {
        switch step {
        case 0:
            app.announce([])
            precondition(center.authorizations.isEmpty, "first read must stay silent")
            fresh(); center.authorizations.removeFirst()(false, nil)
        case 1:
            precondition(app.model.fleetNotificationError != nil, "denied permission must be visible")
            precondition(center.submissions.isEmpty)
            app.announce(notices)
            precondition(center.authorizations.isEmpty, "refresh must preserve deduplication")
            fresh(.failed); center.authorizations.removeFirst()(false, failure)
        case 2:
            precondition(app.model.fleetNotificationError != nil)
            fresh(.disconnected); center.authorizations.removeFirst()(true, nil)
        case 3:
            precondition(center.submissions.count == 1)
            center.submissions.removeFirst().1?(failure)
        case 4:
            precondition(app.model.fleetNotificationError != nil, "submission rejection must be visible")
            // Two callbacks in one batch; later success cannot hide a failure.
            notices.append(FleetNotice(at: Date(timeIntervalSince1970: 10), kind: .done, task: "other", machine: "Peer", text: "Other"))
            fresh(); center.authorizations.removeFirst()(true, nil)
        case 5:
            precondition(center.submissions.count == 2)
            let callbacks = center.submissions; center.submissions.removeAll()
            Dispatch.DispatchQueue.global().async {
                callbacks[1].1?(failure)
                callbacks[0].1?(nil)
                Dispatch.DispatchQueue.main.async { advance() }
            }
            return
        case 6:
            precondition(app.model.fleetNotificationError != nil)
            fresh(); let old = center.authorizations.removeFirst()
            fresh(); center.authorizations.removeFirst()(true, nil)
            old(false, failure)
        case 7:
            precondition(center.submissions.count == 1)
            center.submissions.removeFirst().1?(nil)
        case 8:
            precondition(app.model.fleetNotificationError == nil, "newer successful submission must clear failure")
            precondition(notices.count == 7, "activity must remain intact")
            fresh(); center.authorizations.removeFirst()(true, nil)
        case 9:
            delayed = center.submissions.removeFirst().1
            fresh(); center.authorizations.removeFirst()(true, nil)
        case 10:
            center.submissions.removeFirst().1?(failure)
            delayed?(nil)
        case 11:
            precondition(app.model.fleetNotificationError != nil, "old submission success erased newer failure")
            fresh(); center.authorizations.removeFirst()(true, nil)
        case 12:
            delayed = center.submissions.removeFirst().1
            fresh(); center.authorizations.removeFirst()(true, nil)
        case 13:
            center.submissions.removeFirst().1?(nil)
            delayed?(failure)
        case 14:
            precondition(app.model.fleetNotificationError == nil, "old submission failure replaced newer success")
            print("Notification permission, submission errors, callback order and deduplication passed")
            exit(0)
        default: fatalError()
        }
        advance()
    }
    static func advance() { step += 1; DispatchQueue.group.notify(queue: .main) { next() } }
    static func main() { next(); RunLoop.main.run() }
}
