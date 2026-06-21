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

    struct StreamResult {
        /// Async stream of text deltas as the model produces them.
        let deltas: AsyncThrowingStream<String, Error>
    }

    /// Flatten OpenAI messages into (systemPrompt, userPrompt). OpenAI is
    /// stateless — the client resends full history every call — so we replay the
    /// conversation as a transcript in the prompt. The model sees all context;
    /// it is not relying on any server-side session. This is faithful, just not
    /// native multi-turn.
    static func buildPrompt(_ messages: [ChatMessage]) -> (system: String, prompt: String) {
        let systemParts = messages.filter { $0.role == "system" }.map(\.content)
        let convo = messages.filter { $0.role != "system" }

        let system = ([baseSystemPrompt] + systemParts).joined(separator: "\n\n")

        let prompt: String
        if convo.count == 1, convo[0].role == "user" {
            prompt = convo[0].content
        } else {
            let transcript = convo.map { msg -> String in
                let label = msg.role == "assistant" ? "Assistant" : "User"
                return "\(label): \(msg.content)"
            }.joined(separator: "\n\n")
            prompt = transcript + "\n\nAssistant:"
        }
        return (system, prompt)
    }

    /// Launch the CLI and stream text deltas. Throws if `claude` can't be found
    /// or the process fails before producing output.
    static func stream(model: String, messages: [ChatMessage]) throws -> StreamResult {
        guard let tools = ToolLocator.resolve() else {
            throw BackendError.claudeNotFound
        }
        let (system, prompt) = buildPrompt(messages)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tools.claudePath)
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
        env["PATH"] = tools.path           // so claude can find node
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
