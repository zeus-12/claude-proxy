import SwiftUI

/// The "?" reference: two sections (Chat and Voice) describing exactly what each
/// endpoint exposes. Ports come from the live config so the URLs are accurate.
struct APIReferencePane: View {
    @EnvironmentObject var chat: ChatController
    @EnvironmentObject var voice: VoiceController

    var body: some View {
        Form {
            Section {
                FeatureRow(
                    title: "Base URL",
                    detail: "Point any OpenAI-compatible client here. The API key is ignored.",
                    code: chat.config.baseURL)
                FeatureRow(
                    title: "Chat completions",
                    detail: "OpenAI Chat Completions. Send `messages`; get a `chat.completion` back.",
                    code: "POST /v1/chat/completions")
                FeatureRow(
                    title: "Models",
                    detail: "The request `model` is required and must be one of these, else the request is rejected with a 400.",
                    code: ChatModel.allowedIDs.joined(separator: ", "))
                FeatureRow(
                    title: "Streaming",
                    detail: "Set `\"stream\": true` to receive Server-Sent Events — a stream of `chat.completion.chunk` deltas ending in `[DONE]`.",
                    code: "{ \"stream\": true }")
                FeatureRow(
                    title: "Tools / function calling",
                    detail: "Send OpenAI `tools` (type `function`) and optional `tool_choice`. The model replies with `tool_calls` and `finish_reason: \"tool_calls\"`; feed results back as `role: \"tool\"` messages.",
                    code: "{ \"tools\": [...], \"tool_choice\": \"auto\" }")
                FeatureRow(
                    title: "List models",
                    detail: "Returns the allowed models in OpenAI's model-list shape.",
                    code: "GET /v1/models")
            } header: {
                Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
            }

            Section {
                FeatureRow(
                    title: "WebSocket URL",
                    detail: "Connect over WebSocket to stream speech to text through your Claude subscription. Any client can connect.",
                    code: voice.config.endpointURL)
                FeatureRow(
                    title: "Send audio",
                    detail: "Send 16 kHz mono linear16 PCM as binary frames while the user speaks.",
                    code: "binary: Int16 PCM @ 16 kHz mono")
                FeatureRow(
                    title: "Finish",
                    detail: "Signal end-of-speech with a text frame; the server flushes and returns the final transcript.",
                    code: "{ \"type\": \"end\" }")
                FeatureRow(
                    title: "Receive transcripts",
                    detail: "Interim results arrive as `transcript` messages; the final result as a `final` message; failures as an `error` message.",
                    code: "{ \"type\": \"transcript\" | \"final\" | \"error\" }")
            } header: {
                Label("Voice", systemImage: "waveform")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
    }
}

private struct FeatureRow: View {
    let title: String
    let detail: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                CopyButton(code)
            }
        }
        .padding(.vertical, 3)
    }
}
