import AppKit
import SwiftUI

@MainActor
enum AppActivationPolicy {
    private static var visibleWindowCount = 0

    static func enter() {
        visibleWindowCount += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func leave() {
        visibleWindowCount = max(0, visibleWindowCount - 1)
        guard visibleWindowCount == 0 else { return }
        Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selectedTab: SettingsTab = .claude
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let navigation = SettingsNavigation()
    private var presented = false

    init(
        claude: ChatController,
        codex: ChatController,
        voice: VoiceController,
        apiKey: APIKeyController
    ) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 860, height: 650)),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .miniaturizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "LLM Proxy Settings"
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 760, height: 540)
        window.setFrameAutosaveName("LLMProxySettingsWindow")
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                navigation: navigation,
                claude: claude,
                codex: codex,
                voice: voice,
                apiKey: apiKey
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(tab: SettingsTab) {
        navigation.selectedTab = tab
        if !presented {
            presented = true
            AppActivationPolicy.enter()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard presented else { return }
        presented = false
        AppActivationPolicy.leave()
    }
}
