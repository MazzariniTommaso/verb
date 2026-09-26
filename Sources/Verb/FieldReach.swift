import AppKit
import ApplicationServices

/// Chromium browsers and Electron apps (Chrome, Edge, Brave, Arc, VS Code, Slack, Notion,
/// Discord, Claude, Obsidian…) build their accessibility only when asked. Verb asks, once per
/// app, with AXManualAccessibility: the attribute Electron made for this, which leaves window
/// management alone, unlike AXEnhancedUserInterface.
@MainActor enum FieldReach {
    private static var woken = Set<pid_t>()
    /// Editors that turn on their screen-reader mode when accessibility is on, which changes how
    /// they behave: they are left alone, and Verb follows what is typed there instead.
    static let leftAlone: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.vscodium"]
    static func wake(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, !leftAlone.contains(id), app.activationPolicy == .regular else { return }
        wake(app.processIdentifier)
    }
    static func wake(_ pid: pid_t) {
        guard !woken.contains(pid), AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        // Asked again later when the request couldn't be made at all, as before Accessibility is allowed.
        let result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if result != .apiDisabled && result != .cannotComplete { woken.insert(pid) }
    }
}
