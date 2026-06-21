import Foundation

// Minimal OpenAI-compatible wire types. We decode only the fields we use and
// stay lenient about the rest so a wide range of clients work.

struct ChatCompletionRequest: Decodable {
    let model: String?
    let messages: [ChatMessage]
    let stream: Bool?
}

struct ChatMessage: Decodable {
    let role: String
    let content: String

    private enum CodingKeys: String, CodingKey { case role, content }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        // `content` is either a plain string or an array of typed parts
        // (vision/multimodal). We concatenate any text parts and ignore the
        // rest, since the Claude CLI text interface only accepts text.
        if let text = try? c.decode(String.self, forKey: .content) {
            content = text
        } else if let parts = try? c.decode([ContentPart].self, forKey: .content) {
            content = parts.compactMap { $0.text }.joined()
        } else {
            content = ""
        }
    }

    private struct ContentPart: Decodable {
        let type: String?
        let text: String?
    }
}

// MARK: - Responses (Encodable)

struct ModelListResponse: Encodable {
    let object = "list"
    let data: [ModelEntry]
}

struct ModelEntry: Encodable {
    let id: String
    let object = "model"
    let created: Int
    let owned_by = "anthropic"
}

struct ChatCompletionResponse: Encodable {
    let id: String
    let object = "chat.completion"
    let created: Int
    let model: String
    let choices: [Choice]

    struct Choice: Encodable {
        let index = 0
        let message: Message
        let finish_reason: String
    }
    struct Message: Encodable {
        let role = "assistant"
        let content: String
    }
}

struct ChatCompletionChunk: Encodable {
    let id: String
    let object = "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [Choice]

    struct Choice: Encodable {
        let index = 0
        let delta: Delta
        let finish_reason: String?
    }
    struct Delta: Encodable {
        let role: String?
        let content: String?
    }
}

struct OpenAIError: Encodable {
    struct Body: Encodable {
        let message: String
        let type: String
    }
    let error: Body
    init(_ message: String, type: String = "proxy_error") {
        self.error = Body(message: message, type: type)
    }
}

enum OpenAIIDs {
    static func chatID() -> String { "chatcmpl-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)) }
    static var now: Int { Int(Date().timeIntervalSince1970) }
}
