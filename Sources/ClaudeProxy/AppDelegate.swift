import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let claude = ChatController(backend: .claude)
    private let codex = ChatController(backend: .codex)
    private let voice = VoiceController()
    private let apiKey = APIKeyController()
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }

        let settingsWindow = SettingsWindowController(
            claude: claude,
            codex: codex,
            voice: voice,
            apiKey: apiKey
        )
        self.settingsWindow = settingsWindow

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                claude: claude,
                codex: codex,
                onOpenSettings: { [weak self] tab in self?.openSettings(tab) }
            )
                .environmentObject(voice)
                .environmentObject(apiKey)
        )
        // Both endpoints auto-start (if configured) inside their controllers'
        // init — nothing to kick off here.

        // Small launch hook used by the UI smoke test. It also makes Settings
        // directly reachable from Terminal when diagnosing a menu-bar issue.
        if CommandLine.arguments.contains("--open-settings") {
            let tab = CommandLine.arguments
                .first(where: { $0.hasPrefix("--settings-tab=") })
                .flatMap { SettingsTab(rawValue: String($0.dropFirst("--settings-tab=".count))) }
                ?? .claude
            openSettings(tab)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        claude.stop()
        codex.stop()
        voice.stop()
    }

    /// A menu-bar (`.accessory`) app shows no menu bar, but it still needs a main
    /// menu installed for the standard editing key equivalents (⌘C/⌘V/⌘X/⌘A/⌘Z)
    /// to route to the focused text field. Without this, text fields in the
    /// popover accept typing but Copy/Paste do nothing — the keystrokes have no
    /// menu item to dispatch their `copy:`/`paste:` actions through.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit LLM Proxy",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    /// The menu-bar glyph: the same Lucide `arrow-left-right` motif as the app
    /// icon, drawn as a template image so macOS tints it for light/dark menus.
    private static func menuBarIcon() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let s = size / 24.0   // Lucide's 24-unit viewBox → 18pt
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: x * s, y: (24 - y) * s)   // flip: SVG is y-down
            }
            let path = NSBezierPath()
            path.lineWidth = 2 * s
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            // Top arrow (points left) + its line.
            path.move(to: p(8, 3));  path.line(to: p(4, 7));  path.line(to: p(8, 11))
            path.move(to: p(4, 7));  path.line(to: p(20, 7))
            // Bottom arrow (points right) + its line.
            path.move(to: p(16, 21)); path.line(to: p(20, 17)); path.line(to: p(16, 13))
            path.move(to: p(20, 17)); path.line(to: p(4, 17))
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true   // adapts to light/dark menu bar
        image.accessibilityDescription = "LLM Proxy"
        return image
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func openSettings(_ tab: SettingsTab) {
        popover.performClose(nil)
        settingsWindow?.show(tab: tab)
    }
}
