import Foundation
import Network

/// Reads one HTTP request off a connection, routes it, writes the response, and
/// closes. One connection = one request (`Connection: close`).
final class HTTPConnection {
    private let conn: NWConnection
    private let instance: ProxyInstance
    private let queue: DispatchQueue
    private var buffer = Data()
    /// Keeps this object alive for the duration of the connection. The
    /// NWConnection's callbacks capture `self` weakly, so without this strong
    /// self-reference the handler would deallocate the moment `accept()`
    /// returns. Cleared in `close()`.
    private var selfRetain: HTTPConnection?

    init(conn: NWConnection, instance: ProxyInstance, queue: DispatchQueue) {
        self.conn = conn
        self.instance = instance
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
            writeJSON(status: 200, object: ["status": "ok", "instance": instance.name, "model": instance.model])
        default:
            writeError(status: 404, message: "Not found: \(request.method) \(request.path)")
        }
    }

    private func handleModels() {
        let response = ModelListResponse(data: [
            ModelEntry(id: instance.advertisedModelID, created: OpenAIIDs.now)
        ])
        writeEncodable(status: 200, response)
    }

    private func handleChat(_ request: HTTPRequest) {
        guard let body = request.body,
              let decoded = try? JSONDecoder().decode(ChatCompletionRequest.self, from: body) else {
            writeError(status: 400, message: "Invalid request body")
            return
        }
        guard !decoded.messages.isEmpty else {
            writeError(status: 400, message: "`messages` must not be empty")
            return
        }

        let wantsStream = decoded.stream ?? false
        let model = instance.model

        let result: ClaudeBackend.StreamResult
        do {
            result = try ClaudeBackend.stream(model: model, messages: decoded.messages)
        } catch {
            writeError(status: 502, message: error.localizedDescription)
            return
        }

        if wantsStream {
            streamChat(result, model: model)
        } else {
            collectChat(result, model: model)
        }
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
                choices: [.init(message: .init(content: text), finish_reason: "stop")]
            )
            writeEncodable(status: 200, response)
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
