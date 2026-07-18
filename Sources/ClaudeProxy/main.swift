import AppKit

// `--selftest`: run the framework-free unit checks and exit (no Xcode needed).
if CommandLine.arguments.contains("--selftest") {
    exit(VoiceSelfTest.run() ? 0 : 1)
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
