import AppKit

// `--selftest`: run the framework-free unit checks and exit (no Xcode needed).
if CommandLine.arguments.contains("--selftest") {
    exit(VoiceSelfTest.run() ? 0 : 1)
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

// Menu-bar-only app: no Dock icon, no main window. The status item lives in
// AppDelegate. We set `.accessory` before `run()` so the Dock never flashes.
// Top-level code runs on the main thread, so we assert main-actor isolation to
// construct the (main-actor) delegate and controller.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
