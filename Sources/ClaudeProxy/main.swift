import AppKit

// A `claude` child that exits while we are still writing its stdin would
// otherwise take the whole app down with SIGPIPE. Writes report EPIPE instead.
signal(SIGPIPE, SIG_IGN)

// `--selftest`: run the framework-free unit checks and exit (no Xcode needed).
if CommandLine.arguments.contains("--selftest") {
    let passed = [VoiceSelfTest.run(), ProxySelfTest.run()].allSatisfy { $0 }
    exit(passed ? 0 : 1)
}

// `--codex-probe [model]`: exercise the real Codex app-server bridge without
// starting HTTP or reading the proxy access-key file. This gives release
// checks a narrow end-to-end path through the locally signed-in Codex runtime.
if let flag = CommandLine.arguments.firstIndex(of: "--codex-probe") {
    let model = CommandLine.arguments.count > flag + 1
        ? CommandLine.arguments[flag + 1]
        : ChatModel.gpt56Luna.rawValue
    let count = CommandLine.arguments.count > flag + 2
        ? max(1, Int(CommandLine.arguments[flag + 2]) ?? 1)
        : 1
    let requestData = try JSONSerialization.data(withJSONObject: [
        "model": model,
        "messages": [["role": "user", "content": "Reply with exactly CODEX_PROXY_OK"]]
    ])
    let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: requestData)
    try request.validate(allowedModels: ChatBackend.codex.allowedIDs)

    Task {
        do {
            for _ in 0..<count {
                let result = try CodexBackend.stream(model: model, messages: request.messages)
                for try await delta in result.deltas {
                    FileHandle.standardOutput.write(Data(delta.utf8))
                }
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            CodexBackend.shutdown()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Codex probe failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

// `--voice-client <ws-url> <pcm-file>`: stream a raw linear16 PCM file to a
// running voice server and print the transcripts. Exercises the endpoint
// end-to-end against the real Claude backend without the menu-bar UI.
if let flag = CommandLine.arguments.firstIndex(of: "--voice-client") {
    let args = CommandLine.arguments
    guard args.count > flag + 2 else {
        print("usage: --voice-client <ws-url> <pcm-file>")
        exit(2)
    }
    exit(VoiceLiveClient.run(url: args[flag + 1], pcmPath: args[flag + 2]) ? 0 : 1)
}

// `--voice-server [port]`: run only the voice WebSocket server, with no menu-bar
// UI. The protocol is otherwise only reachable by launching the whole app, which
// makes it awkward to exercise end-to-end from a script or from CI.
if let flag = CommandLine.arguments.firstIndex(of: "--voice-server") {
    let port = CommandLine.arguments.count > flag + 1
        ? UInt16(CommandLine.arguments[flag + 1]) ?? 8765
        : 8765
    let server = VoiceServer(port: port) { running, error in
        if let error { print("voice server error: \(error)") }
        else { print(running ? "voice server listening on \(port)" : "voice server stopped") }
    }
    server.start()
    dispatchMain()
}

// `--print-api-key`: print the endpoint's local API key for scripts and
// headless clients.
if let flag = CommandLine.arguments.firstIndex(of: "--print-api-key") {
    let name = CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : "claude"
    guard let scope = APIKeyScope(rawValue: name) else {
        print("usage: --print-api-key [claude|codex|voice]")
        exit(2)
    }
    switch APIKey.state(scope) {
    case .required(let key):
        print(key)
        exit(0)
    case .disabled:
        print("")
        exit(0)
    case .unavailable(let reason):
        FileHandle.standardError.write(Data("Could not read \(scope.label) API key: \(reason)\n".utf8))
        exit(1)
    }
}

// `--chat-server [port]`: run only the Chat HTTP server, with no menu-bar UI —
// the counterpart to `--voice-server`, for exercising the endpoint from a script.
if let flag = CommandLine.arguments.firstIndex(where: { $0 == "--claude-server" || $0 == "--chat-server" }) {
    let port = CommandLine.arguments.count > flag + 1
        ? Int(CommandLine.arguments[flag + 1]) ?? 8787
        : 8787
    let server = ProxyServer(endpoint: ChatEndpoint(port: port), backend: .claude) { status in
        print("claude server: \(status)")
    }
    server.start()
    dispatchMain()
}

if let flag = CommandLine.arguments.firstIndex(of: "--codex-server") {
    let defaultPort = ChatBackend.codex.defaultPort
    let port = CommandLine.arguments.count > flag + 1
        ? Int(CommandLine.arguments[flag + 1]) ?? defaultPort
        : defaultPort
    let server = ProxyServer(endpoint: ChatEndpoint(port: port), backend: .codex) { status in
        print("codex server: \(status)")
    }
    try? CodexBackend.prepare()
    server.start()
    dispatchMain()
}

// Menu-bar-only app: no Dock icon, no main window. Packaged builds declare
// LSUIElement; direct executable launches use `.accessory` as a fallback.
// Top-level code runs on the main thread, so we assert main-actor isolation to
// construct the (main-actor) delegate and controller.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    if Bundle.main.object(forInfoDictionaryKey: "LSUIElement") == nil {
        app.setActivationPolicy(.accessory)
    }
    withExtendedLifetime(delegate) {
        app.run()
    }
}
