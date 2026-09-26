import Foundation
import CoreFoundation

/// Counts reported by the provider for this invocation. Nil means unreported.
/// inputTokens includes cached input; cached input is never added twice.
struct TaskUsage {
    var scope = "unknown"
    var models: [String: TaskUsage] = [:]
    var session: String? = nil
    var model: String? = nil
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var cachedInputTokens: Int? = nil
    var cacheCreationInputTokens: Int? = nil
    var uncachedInputTokens: Int? = nil
    var totalTokens: Int? = nil
    var counts: [String: Any] {
        ["inputTokens": inputTokens as Any? ?? NSNull(), "outputTokens": outputTokens as Any? ?? NSNull(),
         "cachedInputTokens": cachedInputTokens as Any? ?? NSNull(),
         "cacheCreationInputTokens": cacheCreationInputTokens as Any? ?? NSNull(),
         "uncachedInputTokens": uncachedInputTokens as Any? ?? NSNull(), "totalTokens": totalTokens as Any? ?? NSNull()]
    }
}

struct AgentResult {
    var text: String
    var usage = TaskUsage()

    private static func count(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0,
              n.doubleValue < Double(Int.max), n.doubleValue.rounded() == n.doubleValue else { return nil }
        return n.intValue
    }
    private static func sum(_ values: Int?...) -> Int? {
        var result = 0
        for value in values {
            guard let value else { return nil }
            let (next, overflow) = result.addingReportingOverflow(value)
            guard !overflow else { return nil }
            result = next
        }
        return result
    }
    private static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func parse(_ text: String, vendor: String) -> AgentResult {
        var result = AgentResult(text: text)
        if vendor == "claude", let value = object(text), value["type"] as? String == "result" {
            result.text = value["result"] as? String ?? (value["errors"] as? [String])?.joined(separator: "\n") ?? ""
            result.usage.session = value["session_id"] as? String
            if let models = value["modelUsage"] as? [String: Any], models.count == 1 {
                result.usage.model = models.keys.first
            }
            if let usage = value["usage"] as? [String: Any] {
                result.usage.scope = "main-agent"
                result.usage.uncachedInputTokens = count(usage["input_tokens"])
                result.usage.cachedInputTokens = count(usage["cache_read_input_tokens"])
                result.usage.cacheCreationInputTokens = count(usage["cache_creation_input_tokens"])
                result.usage.inputTokens = sum(result.usage.uncachedInputTokens, result.usage.cachedInputTokens, result.usage.cacheCreationInputTokens)
                result.usage.outputTokens = count(usage["output_tokens"])
                result.usage.totalTokens = sum(result.usage.inputTokens, result.usage.outputTokens)
            }
            // modelUsage is cumulative for the entire tree, including subagents.
            // Loop invocations are fresh sessions, so no earlier resume is counted.
            if let models = value["modelUsage"] as? [String: Any], !models.isEmpty {
                result.usage = TaskUsage(scope: "invocation-tree", session: result.usage.session)
                result.usage.model = models.count == 1 ? models.keys.first : nil
                for (model, raw) in models {
                    let usage = raw as? [String: Any] ?? [:]
                    var bucket = TaskUsage(scope: "invocation-tree", model: model)
                    bucket.uncachedInputTokens = count(usage["inputTokens"])
                    bucket.cachedInputTokens = count(usage["cacheReadInputTokens"])
                    bucket.cacheCreationInputTokens = count(usage["cacheCreationInputTokens"])
                    bucket.inputTokens = sum(bucket.uncachedInputTokens, bucket.cachedInputTokens, bucket.cacheCreationInputTokens)
                    bucket.outputTokens = count(usage["outputTokens"])
                    bucket.totalTokens = sum(bucket.inputTokens, bucket.outputTokens)
                    result.usage.models[model] = bucket
                }
                func total(_ key: KeyPath<TaskUsage, Int?>) -> Int? {
                    var value: Int? = 0
                    for bucket in result.usage.models.values { value = sum(value, bucket[keyPath: key]) }
                    return value
                }
                result.usage.inputTokens = total(\.inputTokens)
                result.usage.outputTokens = total(\.outputTokens)
                result.usage.cachedInputTokens = total(\.cachedInputTokens)
                result.usage.cacheCreationInputTokens = total(\.cacheCreationInputTokens)
                result.usage.uncachedInputTokens = total(\.uncachedInputTokens)
                result.usage.totalTokens = total(\.totalTokens)
            }
        } else if vendor == "codex" {
            var recognized = false
            var finalText: String? = nil
            var errors: [String] = []
            for line in text.split(separator: "\n") {
                guard let value = object(String(line)), let type = value["type"] as? String else { continue }
                switch type {
                case "thread.started":
                    recognized = true
                    result.usage.session = value["thread_id"] as? String
                case "item.completed":
                    recognized = true
                    if let item = value["item"] as? [String: Any], item["type"] as? String == "agent_message" {
                        finalText = item["text"] as? String
                    }
                case "turn.completed":
                    recognized = true
                    result.usage.scope = "provider-turn"
                    if let usage = value["usage"] as? [String: Any] {
                        result.usage.inputTokens = count(usage["input_tokens"])
                        result.usage.outputTokens = count(usage["output_tokens"])
                        result.usage.cachedInputTokens = count(usage["cached_input_tokens"])
                        result.usage.totalTokens = sum(result.usage.inputTokens, result.usage.outputTokens)
                    }
                case "error", "turn.failed":
                    recognized = true
                    if let error = value["error"] as? [String: Any], let message = error["message"] as? String { errors.append(message) }
                    else if let message = value["message"] as? String { errors.append(message) }
                default: break
                }
            }
            if recognized { result.text = ([finalText].compactMap { $0 } + errors).joined(separator: "\n") }
        }
        return result
    }
}
