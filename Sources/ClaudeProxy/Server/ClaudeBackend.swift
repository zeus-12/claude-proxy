import Foundation

/// Drives `claude -p` headlessly and turns its `stream-json` output into a
/// stream of plain text deltas. This is the only place that touches the CLI.
///
/// Honesty notes baked into the design:
///  - We fully override the system prompt so the Claude Code agent persona is
///    replaced by a plain-assistant prompt. We cannot remove the ~12k tokens of
///    cached harness context, so every call has that input-token floor.
///  - All tools are disabled. A chat proxy must never let the model read files
///    or run commands on the host.
enum ClaudeBackend {

    /// Tools we explicitly forbid. Belt-and-suspenders alongside the overridden
    /// system prompt which tells the model it has no tools.
    private static let disallowedTools = [
        "Bash", "Read", "Write", "Edit", "MultiEdit", "Glob", "Grep",
        "WebFetch", "WebSearch", "Task", "TodoWrite", "NotebookEdit"
    ]

    private static let baseSystemPrompt = """
    You are a helpful AI assistant accessed through an API endpoint. Respond \
    directly to the user's messages. You have no access to tools, files, the \
    filesystem, or the user's computer. Do not mention being Claude Code or any \
    coding harness.
    """

    /// Used instead of `baseSystemPrompt` when the caller supplies function tools.
    /// Framed as a JSON-directive *router*, not a tool-caller — testing showed the
    /// words "tool"/"call a function" make Claude Code's native tool machinery
    /// engage (the model tries to invoke a real tool, it's blocked, and it
    /// narrates "the tool call failed"). Framing it as pure JSON text-generation
    /// ("you are not calling anything, you are writing JSON") reliably produces the
    /// tool-call JSON on both Sonnet and Opus.
    private static let baseSystemPromptWithTools = """
    You convert user requests into structured JSON directives for an external \
    system. You have no tools and you NEVER perform actions or fetch data yourself \
    — you ONLY write JSON text. This is pure text generation, not tool use. Do not \
    mention being Claude Code or any coding harness.
    """

    struct StreamResult {
        /// Async stream of text deltas as the model produces them.
        let deltas: AsyncThrowingStream<String, Error>
    }

    /// Flatten OpenAI messages into (systemPrompt, userPrompt). OpenAI is
    /// stateless — the client resends full history every call — so we replay the
    /// conversation as a transcript in the prompt. The model sees all context;
    /// it is not relying on any server-side session. This is faithful, just not
    /// native multi-turn.
    ///
    /// When `tools` are provided, we inject a function-calling section into the
    /// system prompt instructing the model to emit tool calls as JSON text (the
    /// subscription CLI can't use the native tool protocol — see `parseToolCalls`).
    static func buildPrompt(_ messages: [ChatMessage],
                            tools: [Tool]? = nil,
                            toolChoice: ToolChoice? = nil) -> (system: String, prompt: String) {
        let systemParts = messages.filter { $0.role == "system" }.compactMap(\.content)
        let convo = messages.filter { $0.role != "system" }

        let toolSection = toolsSystemSection(tools: tools, toolChoice: toolChoice)
        let base = toolSection == nil ? baseSystemPrompt : baseSystemPromptWithTools
        var systemPieces = [base] + systemParts
        if let toolSection { systemPieces.append(toolSection) }
        let system = systemPieces.joined(separator: "\n\n")

        let prompt: String
        if convo.count == 1, convo[0].role == "user", (tools?.isEmpty ?? true) {
            prompt = convo[0].content ?? ""
        } else {
            let transcript = convo.map(transcriptLine).joined(separator: "\n\n")
            prompt = transcript + "\n\nAssistant:"
        }
        return (system, prompt)
    }

    /// Render one non-system message as a transcript line, including replayed
    /// tool calls (assistant) and tool results (role "tool").
    private static func transcriptLine(_ msg: ChatMessage) -> String {
        switch msg.role {
        case "assistant":
            if let calls = msg.toolCalls, !calls.isEmpty {
                let entries = calls.map { "{\"name\": \"\($0.function.name)\", \"arguments\": \($0.function.arguments)}" }
                return "Assistant: {\"tool_calls\": [\(entries.joined(separator: ", "))]}"
            }
            return "Assistant: \(msg.content ?? "")"
        case "tool":
            let id = msg.toolCallId ?? ""
            return "Tool result (for tool_call_id \(id)): \(msg.content ?? "")"
        default:
            return "User: \(msg.content ?? "")"
        }
    }

    /// Build the function-calling instructions injected into the system prompt.
    /// Returns nil when there are no tools or `tool_choice` is "none".
    private static func toolsSystemSection(tools: [Tool]?, toolChoice: ToolChoice?) -> String? {
        guard let tools, !tools.isEmpty else { return nil }
        if case .none? = toolChoice { return nil }   // ToolChoice.none → no tool calling

        let list = tools.map { t -> String in
            let fn = t.function
            var line = "- \(fn.name)"
            if let d = fn.description, !d.isEmpty { line += ": \(d)" }
            if let p = fn.parameters { line += "\n  JSON Schema for arguments: \(p.jsonString)" }
            return line
        }.joined(separator: "\n")

        let obligation: String
        switch toolChoice {
        case .required:
            obligation = "You MUST emit at least one directive this turn (respond with ONLY the JSON)."
        case .function(let name):
            obligation = "You MUST emit the \"\(name)\" directive this turn (respond with ONLY the JSON)."
        default:
            obligation = "If a directive can fulfil the request, emit its JSON rather than answering from your own knowledge."
        }

        return """
        When the user's request matches one of the directives below, output ONLY a \
        single JSON object and nothing else — no prose, no explanation, no markdown \
        code fences — in exactly this shape:
        {"tool_calls": [{"name": "<directive_name>", "arguments": { <arguments matching the directive's JSON Schema> }}]}
        Include multiple entries in the array to invoke several directives at once. \
        \(obligation) If no directive matches, reply in plain text.

        The external system performs each action and returns the result on a later \
        turn as a line like "Tool result (for tool_call_id ...): ..." — use those \
        results to answer the user in plain text. NEVER claim you can't do something, \
        that a directive is "unavailable", or that an action "failed": you are only \
        writing the directive JSON, not performing it.

        Supported directives:
        \(list)
        """
    }

    /// Parse the model's raw output into tool calls, or nil if it isn't a
    /// tool-call response (i.e. the model replied with plain text). Tolerant of
    /// markdown fences and surrounding whitespace; accepts the `tool_calls` array
    /// form, a single `tool_call` object, or a bare `{name, arguments}` object.
    static func parseToolCalls(_ raw: String) -> [ToolCall]? {
        let candidate = extractJSONObject(from: raw)
        guard let data = candidate.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var entries: [[String: Any]] = []
        if let arr = obj["tool_calls"] as? [[String: Any]] {
            entries = arr
        } else if let single = obj["tool_call"] as? [String: Any] {
            entries = [single]
        } else if obj["name"] is String {
            entries = [obj]
        } else {
            return nil
        }

        let calls: [ToolCall] = entries.compactMap { entry in
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            let argsString: String
            if let s = entry["arguments"] as? String {
                argsString = s
            } else if let anyArgs = entry["arguments"],
                      let d = try? JSONSerialization.data(withJSONObject: anyArgs),
                      let s = String(data: d, encoding: .utf8) {
                argsString = s
            } else {
                argsString = "{}"
            }
            return ToolCall(id: OpenAIIDs.toolCallID(), name: name, arguments: argsString)
        }
        return calls.isEmpty ? nil : calls
    }

    /// Strip markdown fences and, if the output has surrounding prose, isolate the
    /// outermost `{ ... }` so a stray sentence doesn't defeat JSON parsing.
    private static func extractJSONObject(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // Drop the opening fence line (```json / ```) and the closing fence.
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let fence = s.range(of: "```", options: .backwards) {
                s = String(s[..<fence.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasPrefix("{") && s.hasSuffix("}") { return s }
        if let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"), open < close {
            return String(s[open...close])
        }
        return s
    }

    /// Launch the CLI and stream text deltas. Throws if `claude` can't be found
    /// or the process fails before producing output.
    static func stream(model: String, messages: [ChatMessage],
                       tools: [Tool]? = nil, toolChoice: ToolChoice? = nil) throws -> StreamResult {
        guard let cli = ToolLocator.resolve() else {
            throw BackendError.claudeNotFound
        }
        let (system, prompt) = buildPrompt(messages, tools: tools, toolChoice: toolChoice)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli.claudePath)
        process.arguments = [
            "-p",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--model", model,
            "--system-prompt", system,
            "--disallowedTools"
        ] + disallowedTools

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = cli.path             // so claude can find node
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        try process.run()

        // Feed the prompt over stdin, then close it so the model knows the turn
        // is complete.
        let stdin = stdinPipe.fileHandleForWriting
        stdin.write(Data(prompt.utf8))
        try? stdin.close()

        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    var sawText = false
                    for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                        if let text = Self.textDelta(fromLine: line) {
                            sawText = true
                            continuation.yield(text)
                        }
                        if let errMessage = Self.errorResult(fromLine: line) {
                            continuation.finish(throwing: BackendError.modelError(errMessage))
                            process.terminate()
                            return
                        }
                    }
                    process.waitUntilExit()
                    if !sawText && process.terminationStatus != 0 {
                        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let msg = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.finish(throwing: BackendError.modelError(
                            msg.isEmpty ? "claude exited with status \(process.terminationStatus)" : msg))
                        return
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning { process.terminate() }
            }
        }

        return StreamResult(deltas: stream)
    }

    /// Extract a text delta from one stream-json line, if present.
    private static func textDelta(fromLine line: String) -> String? {
        guard let obj = jsonObject(line),
              obj["type"] as? String == "stream_event",
              let event = obj["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String else {
            return nil
        }
        return text
    }

    /// Detect a terminal error reported in a `result` line.
    private static func errorResult(fromLine line: String) -> String? {
        guard let obj = jsonObject(line),
              obj["type"] as? String == "result",
              (obj["is_error"] as? Bool == true) else {
            return nil
        }
        return (obj["result"] as? String) ?? "claude reported an error"
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum BackendError: LocalizedError {
    case claudeNotFound
    case modelError(String)

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Could not find the `claude` CLI on your login PATH. Make sure Claude Code is installed and logged in."
        case .modelError(let m):
            return m
        }
    }
}
