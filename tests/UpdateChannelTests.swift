import Foundation

@main struct UpdateChannelTests {
    static func main() {
        let suite = "N2Agents.UpdateChannelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(UpdateChannel.selected(defaults: defaults) == .stable)
        precondition(UpdateChannel.selected(defaults: defaults).feedInfoKey == "N2AgentsStableFeedURL")
        defaults.set(UpdateChannel.continuous.rawValue, forKey: UpdateChannel.preferenceKey)
        precondition(UpdateChannel.selected(defaults: defaults) == .continuous)
        precondition(UpdateChannel.selected(defaults: defaults).feedInfoKey == "N2AgentsContinuousFeedURL")
        defaults.set("untrusted", forKey: UpdateChannel.preferenceKey)
        precondition(UpdateChannel.selected(defaults: defaults) == .stable)
    }
}
