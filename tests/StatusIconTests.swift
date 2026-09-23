import AppKit

@main struct StatusIconTests {
    static func main() {
        for (left, tier) in [(100, StatusIcon.Tier.green), (81, .green), (80, .amber), (50, .amber),
                             (49, .orange), (20, .orange), (19, .red), (0, .red)] {
            precondition(StatusIcon.Tier(remaining: left) == tier, "\(left)% left should be \(tier)")
        }
        // The toast announces a reading once it's a tier worse than before.
        precondition(StatusIcon.Tier.green < .amber && StatusIcon.Tier.amber < .orange && StatusIcon.Tier.orange < .red)
    }
}
