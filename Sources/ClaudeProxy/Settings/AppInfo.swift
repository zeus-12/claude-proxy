import AppKit

/// Static app metadata. An SPM executable has no Info.plist, so we keep the
/// version here rather than reading a (missing) bundle dictionary.
enum AppInfo {
    static let name = "Claude Proxy"
    static let version = "1.0"
    static let build = "1"
    static var versionString: String { "Version \(version) (\(build))" }
}

/// UserDefaults keys for app-wide preferences set in Settings and read when
/// creating new instances.
enum DefaultsKey {
    static let defaultModel = "defaultModel"
    static let basePort = "basePort"
}

/// Reference-counted activation policy for a menu-bar-only (.accessory) app.
/// Opening a real window (Settings) flips the app to .regular so it can take
/// focus; closing the last one returns to .accessory (no Dock icon).
@MainActor
enum AppActivationPolicy {
    private static var count = 0

    static func enter() {
        count += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func leave() {
        count = max(0, count - 1)
        guard count == 0 else { return }
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
