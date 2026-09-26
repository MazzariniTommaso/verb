import AppKit
import CoreGraphics

/// What is just before the cursor in apps that don't show their text to Accessibility, such as
/// Sublime Text, VS Code or a browser's address bar: the last characters typed there, and the
/// text Verb itself pasted. It is kept in memory only, never saved, at most 40 characters, and
/// forgotten at a click, an arrow key, a shortcut or a switch to another app. Password fields
/// hide their keys from every app, Verb included.
@MainActor final class TypingContext {
    /// Set on the key events Verb posts itself (⌘V, ⌘C, arrows), so they are not taken for typing.
    static let marker: Int64 = 0x5645_5242
    private var tail = ""
    private var app: pid_t = 0

    /// The text just before the cursor in the app, when Verb can vouch for it.
    func before(in pid: pid_t) -> String? { app == pid && !tail.isEmpty ? tail : nil }

    /// Verb pasted `text` where the cursor was: it is now right before the cursor.
    func wrote(_ text: String, in pid: pid_t) {
        if app != pid { tail = "" }
        app = pid
        tail = String((tail + text).suffix(40))
    }

    func forget() { tail = "" }

    /// A key that reached an app.
    func typed(_ event: CGEvent) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if front != app { app = front; tail = "" }
        // Shortcuts (⌘V of something unknown, ⌘Z, ⌘←) move or change what Verb can't see.
        if !event.flags.intersection([.maskCommand, .maskControl]).isEmpty { tail = ""; return }
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case 51: if !tail.isEmpty { tail.removeLast() }                              // Delete
        case 117: break                                                                // Forward delete leaves what is before
        case 36, 76: tail = String((tail + "\n").suffix(40))                           // Return
        case 48, 53, 115, 116, 119, 121, 123, 124, 125, 126: tail = ""                 // Tab, Escape, Home, Page, End, arrows
        default:
            var length = 0, characters = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &characters)
            let typed = String(utf16CodeUnits: characters, count: length)
            guard !typed.isEmpty, !typed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return }
            tail = String((tail + typed).suffix(40))
        }
    }
}
