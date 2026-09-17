import Foundation

enum UpdateChannel: String, CaseIterable {
    case stable
    case continuous

    static let preferenceKey = "updateChannel"
    var feedInfoKey: String { self == .stable ? "N2AgentsStableFeedURL" : "N2AgentsContinuousFeedURL" }

    static func selected(defaults: UserDefaults = .standard) -> UpdateChannel {
        defaults.string(forKey: preferenceKey).flatMap(UpdateChannel.init(rawValue:)) ?? .stable
    }
}
