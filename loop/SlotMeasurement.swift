import Foundation
import CoreFoundation

/// Structured allowance evidence used by loop selection. Display columns are
/// only a compatibility path for providers without structured limit buckets.
struct SlotMeasurement {
    let provider: String
    let profile: String
    let status: String
    let used: Double?
    let resets: Date?

    static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite {
            return Date(timeIntervalSince1970: n.doubleValue)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: text) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        if let result = formatter.date(from: text) { return result }
        let minutes = DateFormatter()
        minutes.locale = Locale(identifier: "en_US_POSIX")
        minutes.timeZone = TimeZone(secondsFromGMT: 0)
        minutes.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return minutes.date(from: text)
    }

    static func percent(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, (0...100).contains(n.doubleValue) else { return nil }
        return n.doubleValue
    }

    static func parse(_ line: String, now: Date = Date()) -> SlotMeasurement? {
        guard let data = line.data(using: .utf8),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let schema = value["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              let provider = value["provider"] as? String,
              let profile = value["profile"] as? String,
              let status = value["status"] as? String else { return nil }
        func unavailable(_ reason: String) -> SlotMeasurement {
            SlotMeasurement(provider: provider, profile: profile, status: reason, used: nil, resets: nil)
        }
        guard let observed = date(value["observedAt"]),
              now.timeIntervalSince(observed) <= 900, observed.timeIntervalSince(now) <= 300 else {
            return unavailable("stale-measurement")
        }
        guard status == "ok" || status == "restricted" else { return unavailable(status) }
        guard let windows = value["windows"] as? [[String: Any]],
              let restrictions = value["restrictions"] as? [[String: Any]] else {
            return unavailable("fetch-error")
        }
        var readings: [(Double, Date?)] = []
        var incomplete = false
        for window in windows {
            if let used = percent(window["usedPercent"]) {
                readings.append((used, date(window["resetsAt"])))
            } else { incomplete = true }
        }
        if windows.isEmpty && !["claude", "codex"].contains(provider),
           let display = value["display"] as? [String: Any] {
            for (usedKey, resetKey) in [("shortUsed", "shortResets"), ("longUsed", "longResets")] {
                let raw = display[usedKey]
                let used = percent(raw) ?? (raw as? String).flatMap(Double.init).flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
                if let used { readings.append((used, date(display[resetKey]))) }
                else if raw != nil && !(raw is NSNull) && (raw as? String) != "-" { incomplete = true }
            }
        }
        let full = readings.filter { $0.0 >= 95 }
        let restricted = status == "restricted" || !restrictions.isEmpty
        // A missing reset must not turn another bucket's reset into a promise
        // that the entire account will be available at that time.
        let resetEvidence = full.map { $0.1 } + restrictions.map { date($0["resetsAt"]) }
            + (status == "restricted" && restrictions.isEmpty ? [nil] : [])
        let resets = !resetEvidence.isEmpty && resetEvidence.allSatisfy { $0 != nil } && !incomplete
            ? resetEvidence.compactMap { $0 }.max() : nil
        return SlotMeasurement(provider: provider, profile: profile,
                               status: restricted ? "restricted" : (incomplete || readings.isEmpty ? "fetch-error" : (!full.isEmpty ? "local-reserve" : "ok")),
                               used: readings.map { $0.0 }.max(), resets: resets)
    }
}
