import Foundation
import Network

/// Reads one HTTP request off a connection, routes it, writes the response, and
/// closes. One connection = one request (`Connection: close`).
final class HTTPConnection {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    /// Keeps this object alive for the duration of the connection. The
    /// NWConnection's callbacks capture `self` weakly, so without this strong
    /// self-reference the handler would deallocate the moment `accept()`
    /// returns. Cleared in `close()`.
    private var selfRetain: HTTPConnection?

    init(conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn
        self.queue = queue
    }

    func start() {
        selfRetain = self
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    // MARK: - Reading

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }

            if let request = HTTPRequest.parse(self.buffer) {
                self.route(request)
                return
            }
            if error != nil || isComplete {
                self.close()
                return
            }
            self.receive()
        }
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest) {
        // CORS preflight so browser-based clients work.
        if request.method == "OPTIONS" {
            writeRaw(status: 204, headers: corsHeaders, body: Data())
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            handleModels()
        case ("POST", "/v1/chat/completions"):
            handleChat(request)
        case ("GET", "/"), ("GET", "/health"):
            writeJSON(status: 200, object: ["status": "ok", "models": ChatModel.allowedIDs])
        default:
            writeError(status: 404, message: "Not found: \(request.method) \(request.path)")
        }
    }

    private func handleModels() {
        let response = ModelListResponse(data: ChatModel.allowedIDs.map {
            ModelEntry(id: $0, created: OpenAIIDs.now)
        })
        writeEncodable(status: 200, response)
    }

    private func handleChat(_ request: HTTPRequest) {
        guard let body = request.body else {
            writeError(status: 400, message: "Missing request body")
            return
        }
        let decoded: ChatCompletionRequest
        do {
            decoded = try JSONDecoder().decode(ChatCompletionRequest.self, from: body)
            try decoded.validate()
        } catch let e as ProxyRequestError {
            writeError(status: 400, message: e.message)
            return
        } catch let e as DecodingError {
            writeError(status: 400, message: "Invalid request body: \(Self.describe(e))")
            return
        } catch {
            writeError(status: 400, message: "Invalid request body: \(error.localizedDescription)")
            return
        }

        let wantsStream = decoded.stream ?? false
        // `validate()` has already guaranteed `model` is present and allowed.
        let model = decoded.model ?? ChatModel.sonnet.rawValue

        // Tool calling: the model emits the tool call as JSON in its full output,
        // which we must inspect before responding — so we buffer rather than
        // stream-through. Only engaged when tools are present and not disabled.
        let toolsActive: Bool = {
            guard let tools = decoded.tools, !tools.isEmpty else { return false }
            if case .none? = decoded.tool_choice { return false }
            return true
        }()

        let result: ClaudeBackend.StreamResult
        do {
            result = try ClaudeBackend.stream(model: model, messages: decoded.messages,
                                              tools: decoded.tools, toolChoice: decoded.tool_choice)
        } catch {
            writeError(status: 502, message: error.localizedDescription)
            return
        }

        if toolsActive {
            respondToolAware(result, model: model, stream: wantsStream)
        } else if wantsStream {
            streamChat(result, model: model)
        } else {
            collectChat(result, model: model)
        }
    }

    /// Buffer the full output, then decide whether it's a tool call or plain text
    /// and respond in the requested shape (JSON or SSE).
    private func respondToolAware(_ result: ClaudeBackend.StreamResult, model: String, stream: Bool) {
        Task {
            var text = ""
            do {
                for try await delta in result.deltas { text += delta }
            } catch {
                // Nothing has been written yet, so a normal error response is fine
                // even if the client asked to stream.
                writeError(status: 502, message: error.localizedDescription)
                return
            }
            let calls = ClaudeBackend.parseToolCalls(text)
            if stream {
                streamToolAware(model: model, calls: calls, text: text)
            } else {
                let message: ChatCompletionResponse.Message
                let finish: String
                if let calls {
                    message = .init(content: nil, tool_calls: calls)
                    finish = "tool_calls"
                } else {
                    message = .init(content: text, tool_calls: nil)
                    finish = "stop"
                }
                let response = ChatCompletionResponse(
                    id: OpenAIIDs.chatID(), created: OpenAIIDs.now, model: model,
                    choices: [.init(message: message, finish_reason: finish)]
                )
                writeEncodable(status: 200, response)
            }
        }
    }

    /// Emit a buffered tool-aware result as SSE deltas (one full tool-call delta
    /// per call, or the text as a single content delta), then `[DONE]`.
    private func streamToolAware(model: String, calls: [ToolCall]?, text: String) {
        let id = OpenAIIDs.chatID()
        let created = OpenAIIDs.now
        writeRaw(status: 200, headers: sseHeaders, body: Data(), keepOpen: true)

        func send(_ delta: ChatCompletionChunk.Delta, finish: String?) {
            let chunk = ChatCompletionChunk(
                id: id, created: created, model: model,
                choices: [.init(delta: delta, finish_reason: finish)]
            )
            if let data = try? JSONEncoder().encode(chunk) {
                sendSSE(Data("data: ".utf8) + data + Data("\n\n".utf8))
            }
        }

        send(.init(role: "assistant"), finish: nil)
        if let calls {
            let deltas = calls.enumerated().map { i, c in
                ChatCompletionChunk.ToolCallDelta(
                    index: i, id: c.id,
                    function: .init(name: c.function.name, arguments: c.function.arguments))
            }
            send(.init(tool_calls: deltas), finish: nil)
            send(.init(), finish: "tool_calls")
        } else {
            send(.init(content: text), finish: nil)
            send(.init(), finish: "stop")
        }
        conn.send(content: Data("data: [DONE]\n\n".utf8), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    // MARK: - Streaming (SSE)

    private func streamChat(_ result: ClaudeBackend.StreamResult, model: String) {
        let id = OpenAIIDs.chatID()
        let created = OpenAIIDs.now
        writeRaw(status: 200, headers: sseHeaders, body: Data(), keepOpen: true)

        Task {
            // First chunk announces the assistant role.
            sendChunk(id: id, created: created, model: model, role: "assistant", content: nil, finish: nil)
            do {
                for try await delta in result.deltas {
                    sendChunk(id: id, created: created, model: model, role: nil, content: delta, finish: nil)
                }
                sendChunk(id: id, created: created, model: model, role: nil, content: nil, finish: "stop")
            } catch {
                // Mid-stream failure: surface it as an SSE error event, then end.
                let payload = OpenAIError(error.localizedDescription)
                if let data = try? JSONEncoder().encode(payload) {
                    sendSSE(Data("data: ".utf8) + data + Data("\n\n".utf8))
                }
            }
            // Close only after the final bytes have actually flushed — calling
            // cancel() right after queueing a send races and drops the data.
            conn.send(content: Data("data: [DONE]\n\n".utf8), completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }
    }

    private func sendChunk(id: String, created: Int, model: String, role: String?, content: String?, finish: String?) {
        let chunk = ChatCompletionChunk(
            id: id, created: created, model: model,
            choices: [.init(delta: .init(role: role, content: content), finish_reason: finish)]
        )
        guard let data = try? JSONEncoder().encode(chunk) else { return }
        sendSSE(Data("data: ".utf8) + data + Data("\n\n".utf8))
    }

    private func sendSSE(_ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Non-streaming

    private func collectChat(_ result: ClaudeBackend.StreamResult, model: String) {
        Task {
            var text = ""
            do {
                for try await delta in result.deltas { text += delta }
            } catch {
                writeError(status: 502, message: error.localizedDescription)
                return
            }
            let response = ChatCompletionResponse(
                id: OpenAIIDs.chatID(), created: OpenAIIDs.now, model: model,
                choices: [.init(message: .init(content: text, tool_calls: nil), finish_reason: "stop")]
            )
            writeEncodable(status: 200, response)
        }
    }

    /// Human-readable summary of a JSON decoding failure, including the key path,
    /// so clients get an actionable 400 instead of "Invalid request body".
    private static func describe(_ error: DecodingError) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let ctx):
            let p = path(ctx)
            return "missing required field `\(key.stringValue)`\(p.isEmpty ? "" : " at \(p)")"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            let p = path(ctx)
            return "\(ctx.debugDescription)\(p.isEmpty ? "" : " at \(p)")"
        case .dataCorrupted(let ctx):
            let p = path(ctx)
            return "\(ctx.debugDescription)\(p.isEmpty ? "" : " at \(p)")"
        @unknown default:
            return error.localizedDescription
        }
    }

    // MARK: - Writing helpers

    private var corsHeaders: [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization"
        ]
    }

    private var sseHeaders: [String: String] {
        var h = corsHeaders
        h["Content-Type"] = "text/event-stream"
        h["Cache-Control"] = "no-cache"
        return h
    }

    private func writeEncodable<T: Encodable>(status: Int, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else {
            writeError(status: 500, message: "Failed to encode response")
            return
        }
        var headers = corsHeaders
        headers["Content-Type"] = "application/json"
        writeRaw(status: status, headers: headers, body: data)
    }

    private func writeJSON(status: Int, object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        var headers = corsHeaders
        headers["Content-Type"] = "application/json"
        writeRaw(status: status, headers: headers, body: data)
    }

    private func writeError(status: Int, message: String) {
        writeEncodable(status: status, OpenAIError(message))
    }

    /// Write a full HTTP response. When `keepOpen` is true (SSE) we leave the
    /// connection open for subsequent `sendSSE` writes.
    private func writeRaw(status: Int, headers: [String: String], body: Data, keepOpen: Bool = false) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var headers = headers
        if !keepOpen {
            headers["Content-Length"] = String(body.count)
        }
        headers["Connection"] = "close"
        for (k, v) in headers {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(body)

        conn.send(content: data, completion: .contentProcessed { [weak self] _ in
            if !keepOpen { self?.close() }
        })
    }

    private func close() {
        conn.cancel()
        selfRetain = nil
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "OK"
        }
    }
}
