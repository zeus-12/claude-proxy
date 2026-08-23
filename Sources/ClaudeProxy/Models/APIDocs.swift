import Foundation

/// The single source of truth for the API reference. `APIReferencePane` renders
/// these structures, and the "Copy docs" buttons serialize the *same* structures
/// to Markdown — so the on-screen reference and the copied text can never drift.
///
/// The copied Markdown is meant to be pasted straight into an LLM, so it spells
/// out the things a coding agent otherwise guesses wrong: that the base URL is a
/// base URL and not a request path, which fields are honoured, and which are
/// accepted but ignored.
enum APIDocs {

    struct Entry {
        let title: String
        let detail: String
        let code: String
    }

    /// A worked example. Kept as title + body rather than pre-formatted Markdown
    /// so each renderer can pick the heading level that matches its nesting —
    /// the standalone and combined documents nest sections differently.
    struct Example {
        let title: String
        let body: String
    }

    struct Section {
        let title: String
        let systemImage: String
        /// Prose that opens the copied document. Not shown in the UI, which has
        /// its own section header.
        let summary: String
        let entries: [Entry]
        let examples: [Example]
    }

    // MARK: - Chat

    static func chat(backend: ChatBackend, baseURL: String) -> Section {
        let providerModels = backend.models
        let models = backend.allowedIDs.joined(separator: ", ")
        let defaultModel = providerModels.first?.rawValue ?? ""
        let runtime = backend == .claude ? "the local Claude Code CLI" : "one warm `codex app-server` process (not `codex exec`)"
        let webDetail = backend == .claude
            ? "Claude can fetch public URLs through its single guarded WebFetch tool. Loopback, localhost and cloud-metadata addresses are refused."
            : "Codex can use hosted web search and browse public pages. Shell tools, command networking, MCP, apps, agents and file changes are disabled."
        let isolation = backend == .claude
            ? "A scratch working directory is used; MCP, skills, user settings and file tools are disabled."
            : "Every request gets an ephemeral thread and scratch directory with approvals off and no model-initiated filesystem or command-network access."
        return Section(
            title: "\(backend.title) chat",
            systemImage: backend.icon,
            summary: """
            A local, OpenAI-compatible Chat Completions server backed only by your \
            \(backend.subtitle). This endpoint is independent and never routes \
            requests to the other provider. It uses \(runtime).

            `\(baseURL)` is a **base URL**, not a request path. OpenAI SDKs append \
            the route themselves — pass it to the client's `base_url`/`baseURL` \
            option. If you are calling it by hand, the full chat endpoint is \
            `POST \(baseURL)/chat/completions`.

            An access key is required before this endpoint can run. Create or \
            paste one under \(backend.title), then send it as \
            `Authorization: Bearer <access-key>` (or `x-api-key`). This is a local \
            proxy key—not your provider credential—and Claude, Codex and Voice \
            each use a separate key.
            """,
            entries: [
                Entry(title: "Base URL",
                      detail: "Point any OpenAI-compatible client here. Create the required local access key under \(backend.title) first.",
                      code: baseURL),
                Entry(title: "Access key",
                      detail: "Required and separate from your provider sign-in. Copy the \(backend.title) access key from Settings.",
                      code: "Authorization: Bearer <access-key>"),
                Entry(title: "Chat completions",
                      detail: "OpenAI Chat Completions. Send `messages`; get a `chat.completion` back.",
                      code: "POST \(baseURL)/chat/completions"),
                Entry(title: "Models",
                      detail: "The request `model` is required and must be one of these. Models from the other provider are rejected with a 400.",
                      code: models),
                Entry(title: "Streaming",
                      detail: "Set `\"stream\": true` to receive Server-Sent Events — a stream of `chat.completion.chunk` deltas ending in `[DONE]`.",
                      code: "{ \"stream\": true }"),
                Entry(title: "Images (vision)",
                      detail: "Send a content-part array mixing `text` and `image_url` parts. Data URLs and http(s) URLs both work, as do the Anthropic (`image` + `source`) and Responses (`input_image`) spellings. Parts keep the order you sent them, so a label next to an image stays next to it. Media type must be png, jpeg, gif, or webp — an image that cannot be forwarded is a 400, never a silent drop.",
                      code: "{ \"type\": \"image_url\", \"image_url\": { \"url\": \"data:image/png;base64,…\" } }"),
                Entry(title: "Tools / function calling",
                      detail: "Send OpenAI `tools` (type `function`) and optional `tool_choice`. The model replies with `tool_calls` and `finish_reason: \"tool_calls\"`; feed results back as `role: \"tool\"` messages.",
                      code: "{ \"tools\": [...], \"tool_choice\": \"auto\" }"),
                Entry(title: "List models",
                      detail: "Returns the allowed models in OpenAI's model-list shape.",
                      code: "GET \(baseURL)/models"),
                Entry(title: "Health",
                      detail: "Liveness check. Returns `{ \"status\": \"ok\", \"models\": [...] }`.",
                      code: "GET \(rootURL(from: baseURL))/health"),
                Entry(title: backend == .claude ? "Web fetch" : "Chat-only runtime",
                      detail: webDetail,
                      code: "\"Summarise https://example.com\""),
                Entry(title: "Isolation",
                      detail: "\(isolation) OpenAI `tools` are returned as JSON directives for your client; the proxy does not execute them.",
                      code: "ephemeral · no host file or command-network access"),
                Entry(title: "Unsupported fields",
                      detail: "Accepted for compatibility and then ignored — the CLI backend exposes no controls for them. Do not rely on them having any effect.",
                      code: "temperature, top_p, max_tokens, n, stop, penalties, seed"),
            ],
            examples: [
                Example(title: "curl", body: """
                ```bash
                curl \(baseURL)/chat/completions \\
                  -H "Content-Type: application/json" \\
                  -H "Authorization: Bearer <access-key>" \\
                  -d '{
                    "model": "\(defaultModel)",
                    "messages": [{"role": "user", "content": "Hello!"}]
                  }'
                ```
                """),
                Example(title: "curl (streaming)", body: """
                ```bash
                curl -N \(baseURL)/chat/completions \\
                  -H "Content-Type: application/json" \\
                  -H "Authorization: Bearer <access-key>" \\
                  -d '{
                    "model": "\(defaultModel)",
                    "stream": true,
                    "messages": [{"role": "user", "content": "Count to five."}]
                  }'
                ```
                """),
                Example(title: "curl (image)", body: """
                ```bash
                curl \(baseURL)/chat/completions \\
                  -H "Content-Type: application/json" \\
                  -H "Authorization: Bearer <access-key>" \\
                  -d '{
                    "model": "\(defaultModel)",
                    "messages": [{"role": "user", "content": [
                      {"type": "text", "text": "What is in this image?"},
                      {"type": "image_url", "image_url": {"url": "data:image/png;base64,'"$(base64 -i shape.png)"'"}}
                    ]}]
                  }'
                ```
                """),
                Example(title: "Python (openai SDK)", body: """
                ```python
                from openai import OpenAI

                client = OpenAI(base_url="\(baseURL)", api_key="<access-key>")

                response = client.chat.completions.create(
                    model="\(defaultModel)",
                    messages=[{"role": "user", "content": "Hello!"}],
                )
                print(response.choices[0].message.content)
                ```
                """),
                Example(title: "TypeScript (openai SDK)", body: """
                ```ts
                import OpenAI from "openai";

                const client = new OpenAI({
                  baseURL: "\(baseURL)",
                  apiKey: "<access-key>",
                });

                const response = await client.chat.completions.create({
                  model: "\(defaultModel)",
                  messages: [{ role: "user", content: "Hello!" }],
                });
                console.log(response.choices[0].message.content);
                ```
                """),
                Example(title: "Errors", body: """
                Errors use OpenAI's shape: `{ "error": { "message": ..., "type": ... } }`.

                - `401` — the access key is missing or wrong. Copy the \
                \(backend.title) key from Settings and send it as \
                `Authorization: Bearer <access-key>`.
                - `400` — `model` missing or not in (\(models)); `messages` empty; a \
                message has an unknown `role`; a `role: "tool"` message is missing \
                `tool_call_id`; an image has an unsupported media type, invalid \
                base64, or a URL scheme other than `data:`/`http(s)`.
                - `404` — wrong path. Remember `\(baseURL)` is a base URL; the \
                request path is `\(baseURL)/chat/completions`.
                - `502` — the \(backend.title) runtime could not be found, was not \
                signed in, or failed to run.
                """),
            ]
        )
    }

    // MARK: - Voice

    static func voice(endpointURL: String) -> Section {
        // Third-party clients are configured with an http(s) base URL and append
        // `/listen` themselves, so show them that form rather than the ws:// one.
        let baseURL = endpointURL
            .replacingOccurrences(of: "ws://", with: "http://") + "/v1"

        return Section(
            title: "Voice",
            systemImage: "waveform",
            summary: """
            A local speech-to-text WebSocket backed by the same Claude \
            subscription, speaking two protocols on one port:

            - **Deepgram** (`/v1/listen`) — the de facto standard for streaming \
            transcription, so existing clients work without code changes.
            - **Legacy** (`/`) — the original minimal protocol, still used by the \
            TypeWhisper plugin.

            An access key is required before Voice can run. Create or paste one \
            under Voice, then send it as `Authorization: Token <access-key>`, as \
            `?token=<access-key>`, or as the `token, <access-key>` WebSocket \
            subprotocol — browser clients cannot set \
            headers, so the last two exist for them. The key is in the app under \
            Voice, and is separate from the Claude and Codex keys.

            Read the limitations below before wiring this into anything that \
            relies on word-level timing — Claude returns transcript text only.
            """,
            entries: [
                Entry(title: "Base URL (Deepgram clients)",
                      detail: "Configure this as the API base. Clients append `/listen` themselves, giving `\(baseURL)/listen`.",
                      code: baseURL),
                Entry(title: "Access key",
                      detail: "Required and separate from the Claude and Codex keys. Copy it from Voice Settings.",
                      code: "Authorization: Token <access-key>   ·   ?token=<access-key>"),
                Entry(title: "WebSocket URL",
                      detail: "The full Deepgram route, if you are connecting by hand. `\(endpointURL)/listen` also works.",
                      code: "\(endpointURL)/v1/listen"),
                Entry(title: "Required query parameters",
                      detail: "`encoding` must be `linear16` — raw PCM only, so containers cannot be auto-detected. `sample_rate` is required; `channels` defaults to 1. Any rate is accepted and resampled to what Claude needs.",
                      code: "?encoding=linear16&sample_rate=16000&channels=1"),
                Entry(title: "Send audio",
                      detail: "Send interleaved signed 16-bit PCM as binary frames, at the rate and channel count you declared. Multi-channel input is downmixed to mono.",
                      code: "binary: interleaved Int16 PCM"),
                Entry(title: "Control messages",
                      detail: "`CloseStream` finishes the stream and returns the terminal `Metadata`. `Finalize` settles the in-progress segment. `KeepAlive` is accepted and ignored — the socket needs no poking.",
                      code: "{ \"type\": \"CloseStream\" | \"Finalize\" | \"KeepAlive\" }"),
                Entry(title: "Receive transcripts",
                      detail: "Interim hypotheses arrive as `Results` with `is_final: false`, settled segments as `Results` with `is_final: true` followed by `UtteranceEnd`, and the stream ends with `Metadata`. Failures arrive as `Error`.",
                      code: "{ \"type\": \"Results\" | \"UtteranceEnd\" | \"Metadata\" | \"Error\" }"),
                Entry(title: "Legacy protocol",
                      detail: "At the server root. Binary 16 kHz mono PCM in, `{\"type\":\"end\"}` to finish; `transcript` / `final` / `error` out. Unchanged.",
                      code: endpointURL),
                Entry(title: "Unsupported Deepgram parameters",
                      detail: "Accepted for compatibility and then ignored — Claude's speech-to-text backend exposes no controls for them. Do not rely on them having any effect.",
                      code: "diarize, punctuate, smart_format, numerals, utterances, vad_events, interim_results, model, language"),
            ],
            examples: [
                Example(title: "Limitations", body: """
                Claude's speech-to-text returns **transcript text and segment \
                boundaries — nothing else**. These are consequences of that, not \
                bugs, and they will not be fixed by configuration:

                - **No word-level timing.** Each `Results` message carries one \
                entry in `words` spanning the whole segment, rather than one per \
                word. Clients that seek by word land on the containing segment. \
                Per-word offsets are not invented.
                - **Timestamps are biased late.** Nothing upstream carries a \
                timestamp, so segment times are derived from audio submitted. A \
                transcript arrives after the speech it describes has been \
                processed, so times run late by roughly the recognition latency \
                — on the order of a second. Ordering and durations are sound; \
                absolute alignment to the recording is approximate.
                - **No confidence scores.** `confidence` is a fixed placeholder, \
                not a measurement. It reads 1.0 rather than 0.0 only so that \
                clients filtering on a threshold do not discard everything.
                - **No diarization.** `speaker` is always null, and multi-channel \
                input is downmixed, so per-channel speaker separation is lost.
                - **Streaming only.** There is no batch endpoint, because there is \
                no batch API upstream to proxy to. Audio is also processed at \
                roughly real time: pushing a file faster than realtime causes the \
                upstream to drop what it has not yet processed when the stream \
                closes.
                """),
                Example(title: "curl (handshake check)", body: """
                ```bash
                curl -i -N \\
                  -H "Connection: Upgrade" \\
                  -H "Upgrade: websocket" \\
                  -H "Sec-WebSocket-Version: 13" \\
                  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \\
                  -H "Authorization: Token <access-key>" \\
                  "\(baseURL)/listen?encoding=linear16&sample_rate=16000"
                ```

                A `101 Switching Protocols` response means the endpoint is live.
                """),
                Example(title: "Python (Deepgram protocol)", body: """
                ```python
                import json, websockets

                url = "\(endpointURL)/v1/listen?encoding=linear16&sample_rate=16000&channels=1&token=<access-key>"

                async with websockets.connect(url) as ws:
                    # Stream interleaved Int16 PCM as binary frames, in real time.
                    for chunk in pcm_chunks:
                        await ws.send(chunk)

                    await ws.send(json.dumps({"type": "CloseStream"}))

                    async for message in ws:
                        event = json.loads(message)
                        if event["type"] == "Results":
                            alt = event["channel"]["alternatives"][0]
                            print(event["is_final"], alt["transcript"])
                        elif event["type"] == "Metadata":
                            break
                ```
                """),
                Example(title: "Python (legacy protocol)", body: """
                ```python
                import json, websockets

                async with websockets.connect("\(endpointURL)?token=<access-key>") as ws:
                    # Stream Int16 PCM @ 16 kHz mono as binary frames.
                    for chunk in pcm_chunks:
                        await ws.send(chunk)

                    await ws.send(json.dumps({"type": "end"}))

                    async for message in ws:
                        event = json.loads(message)
                        if event["type"] == "final":
                            print(event)
                            break
                ```
                """),
                Example(title: "Errors", body: """
                Deepgram-protocol failures arrive as an `Error` message and the \
                socket closes:

                - A missing or wrong access key — refused with a 401 before the \
                socket opens, not as an `Error` message.
                - Missing `encoding`, or an `encoding` other than `linear16`.
                - Missing or invalid `sample_rate`, or `channels` outside 1–8.
                - An unknown path. Use `/v1/listen` or `/listen` for the Deepgram \
                protocol, or `/` for the legacy one.
                - The Claude OAuth token could not be read or has expired — run \
                Claude Code once to refresh it.
                """),
            ]
        )
    }

    // MARK: - Markdown

    /// Serialize one section as standalone Markdown.
    static func markdown(for section: Section) -> String {
        """
        # LLM Proxy — \(section.title) API

        \(section.summary)

        ## Reference

        \(body(of: section, headingLevel: 3))
        """
    }

    /// Serialize several sections as one document, for the "copy everything" case.
    static func markdown(for sections: [Section]) -> String {
        let body = sections.map { section in
            """
            ## \(section.title)

            \(section.summary)

            ### Reference

            \(self.body(of: section, headingLevel: 4))
            """
        }.joined(separator: "\n\n---\n\n")

        return """
        # LLM Proxy — API reference

        LLM Proxy runs local servers on this machine. Chat exposes Claude Code \
        and Codex models through an OpenAI-compatible API; Voice exposes Claude \
        speech-to-text through WebSocket APIs. Both are loopback-only \
        (`127.0.0.1`). A separate local access key is required for each endpoint.

        \(body)
        """
    }

    /// A section's entries and examples, with entry/example headings rendered at
    /// `headingLevel` and the "Examples" divider one level above it.
    private static func body(of section: Section, headingLevel: Int) -> String {
        let hash = String(repeating: "#", count: headingLevel)
        let parentHash = String(repeating: "#", count: headingLevel - 1)

        let entries = section.entries.map { entry in
            "\(hash) \(entry.title)\n\n\(entry.detail)\n\n```\n\(entry.code)\n```"
        }.joined(separator: "\n\n")

        let examples = section.examples.map { example in
            "\(hash) \(example.title)\n\n\(example.body)"
        }.joined(separator: "\n\n")

        return "\(entries)\n\n\(parentHash) Examples\n\n\(examples)"
    }

    /// `http://127.0.0.1:8787/v1` → `http://127.0.0.1:8787`. `/health` lives at
    /// the server root, not under `/v1`.
    private static func rootURL(from baseURL: String) -> String {
        guard baseURL.hasSuffix("/v1") else { return baseURL }
        return String(baseURL.dropLast(3))
    }
}
