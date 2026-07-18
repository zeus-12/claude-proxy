import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let chat = ChatController()
    private let voice = VoiceController()
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 388)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView()
                .environmentObject(chat)
                .environmentObject(voice)
        )
        // Both endpoints auto-start (if configured) inside their controllers'
        // init — nothing to kick off here.
    }

    func applicationWillTerminate(_ notification: Notification) {
        chat.stop()
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
        appMenu.addItem(withTitle: "Quit Claude Proxy",
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
        image.accessibilityDescription = "Claude Proxy"
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
}
