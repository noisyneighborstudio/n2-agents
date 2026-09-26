import SwiftUI

/// The observation's account and buckets, independent of cached login labels.
struct UsageDetailsView: View {
    let usage: Usage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(usage.accountSummary)
                .font(.system(size: 11, weight: .medium))
                .help(usage.accountHelp)
            Text(usage.hasObservationTime
                 ? "Observed \(usage.fetchedAt.formatted(date: .abbreviated, time: .standard))"
                 : "Observation time unavailable")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !usage.isFresh {
                Text("Stale measurement · refresh needed").foregroundStyle(.orange)
            }
            if usage.isFresh, usage.note == .restricted {
                Text("Restricted for new work").foregroundStyle(.red)
                ForEach(Array(usage.restrictionReasons.enumerated()), id: \.offset) { index, reason in
                    Text(reason).foregroundStyle(.secondary).lineLimit(2).help(reason)
                    Text(usage.restrictionResets.indices.contains(index)
                         ? usage.restrictionResets[index].map { "Restriction resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Restriction reset unknown"
                         : "Restriction reset unknown")
                        .foregroundStyle(.secondary)
                }
                Text(usage.maxedUntil.map { "All current limits reset by \($0.formatted(date: .abbreviated, time: .shortened))" }
                     ?? "Recovery time unknown")
                    .foregroundStyle(.secondary)
            } else if usage.note != .ok && usage.note != .restricted {
                Text(usage.statusLabel.prefix(1).uppercased() + String(usage.statusLabel.dropFirst())).foregroundStyle(.orange)
                Text(usage.statusExplanation).foregroundStyle(.secondary)
            } else if usage.maxed {
                Text("At N2's scheduling reserve").foregroundStyle(.orange)
            }
            if usage.isFresh, usage.note == .ok || usage.note == .restricted {
                ForEach(Array((usage.windows ?? []).enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(window.label).lineLimit(2).help(window.scope)
                            Spacer(minLength: 4)
                            Text("\(window.percent, specifier: "%.1f")% used").monospacedDigit()
                        }
                        ProgressView(value: window.percent, total: 100)
                            .tint(window.percent >= 95 ? .orange : .accentColor)
                        Text(window.resets.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" }
                             ?? "Reset time unknown")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(usage.creditNotes.enumerated()), id: \.offset) { _, note in
                    Text(note).foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 10))
        .padding(.vertical, 5)
    }
}
