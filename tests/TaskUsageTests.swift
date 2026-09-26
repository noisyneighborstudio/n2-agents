import Foundation

@main struct TaskUsageTests {
    static func main() {
        let codex = """
        {"type":"thread.started","thread_id":"session-one"}
        {"type":"item.completed","item":{"type":"command_execution","aggregated_output":"private command output"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"final report"}}
        {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20}}
        """
        let c = AgentResult.parse(codex, vendor: "codex")
        precondition(c.text == "final report" && c.usage.session == "session-one")
        precondition(c.usage.totalTokens == 120 && c.usage.cachedInputTokens == 80, "cache is a subset, not extra tokens")
        let claude = #"{"type":"result","session_id":"session-two","result":"answer","usage":{"input_tokens":10,"cache_read_input_tokens":30,"cache_creation_input_tokens":20,"output_tokens":5},"modelUsage":{"model-one":{"inputTokens":10,"cacheReadInputTokens":30,"cacheCreationInputTokens":20,"outputTokens":5}}}"#
        let a = AgentResult.parse(claude, vendor: "claude")
        precondition(a.text == "answer" && a.usage.model == "model-one")
        precondition(a.usage.inputTokens == 60 && a.usage.totalTokens == 65)
        let mixed = AgentResult.parse(#"{"type":"result","subtype":"error_max_budget_usd","errors":["budget reached"],"usage":{"input_tokens":1,"output_tokens":1},"modelUsage":{"parent":{"inputTokens":10,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"outputTokens":5},"child":{"inputTokens":20,"cacheReadInputTokens":10,"cacheCreationInputTokens":0,"outputTokens":5}}}"#, vendor: "claude")
        precondition(mixed.usage.model == nil && mixed.usage.models.count == 2)
        precondition(mixed.usage.totalTokens == 50 && mixed.usage.scope == "invocation-tree")
        precondition(mixed.text == "budget reached")
        let missing = AgentResult.parse(#"{"type":"result","result":"answer","usage":{"input_tokens":10,"output_tokens":5}}"#, vendor: "claude")
        precondition(missing.usage.totalTokens == nil && missing.usage.uncachedInputTokens == 10, "missing counts are not zero")
        let invalid = AgentResult.parse(#"{"type":"turn.completed","usage":{"input_tokens":true,"output_tokens":-1}}"#, vendor: "codex")
        precondition(invalid.usage.inputTokens == nil && invalid.usage.outputTokens == nil)
        let failure = AgentResult.parse(#"{"type":"turn.failed","error":{"message":"usage limit reached"}}"#, vendor: "codex")
        precondition(failure.text == "usage limit reached" && failure.usage.totalTokens == nil)
        let plain = AgentResult.parse("plain fixture report", vendor: "codex")
        precondition(plain.text == "plain fixture report" && plain.usage.totalTokens == nil)
        print("Task usage parsing tests passed")
    }
}
