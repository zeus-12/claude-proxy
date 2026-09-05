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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "LLMProxyStatusItem"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "arrow.left.arrow.right",
                accessibilityDescription: "LLM Proxy"
            )
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
            button.toolTip = "LLM Proxy"
            button.setAccessibilityLabel("LLM Proxy")
        }

        installMainMenu()

        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        let hostingController = NSHostingController(
            rootView: PopoverView(
                claude: claude,
                codex: codex
            )
                .environmentObject(voice)
                .environmentObject(apiKey)
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        // Enabled endpoints resume inside their controllers' initializers.

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

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

}
