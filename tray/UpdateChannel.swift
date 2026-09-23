import Foundation

enum UpdateChannel: String, CaseIterable {
    case stable
    case continuous

    static let preferenceKey = "updateChannel"

    /// A local QA build (`N2_QA=1 tray/build.sh`) is on no channel: Sparkle
    /// never starts, so it can't replace itself or stop the installed app.
    static let isQABuild = Bundle.main.object(forInfoDictionaryKey: "N2QABuild") as? Bool == true
    var feedInfoKey: String { self == .stable ? "N2AgentsStableFeedURL" : "N2AgentsContinuousFeedURL" }

    static func selected(defaults: UserDefaults = .standard) -> UpdateChannel {
        defaults.string(forKey: preferenceKey).flatMap(UpdateChannel.init(rawValue:)) ?? .stable
    }
}
