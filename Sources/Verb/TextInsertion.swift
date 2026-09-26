import AppKit
import ApplicationServices
import VerbCore

@MainActor struct TextTarget {
    let pid: pid_t
    let appName: String
    let bundleID: String
    let element: AXUIElement?
    let range: CFRange?
    let role: String?
    let selection: String
    let secure: Bool
    /// Whether the focused element can take the text, or Verb should copy it for ⌘V instead.
    var verdict: InsertionPolicy.Verdict {
        InsertionPolicy.verdict(hasElement: element != nil, role: role, hasTextRange: range != nil, bundleID: bundleID, isVerb: pid == ProcessInfo.processInfo.processIdentifier)
    }
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func focused(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let value = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }
    static func capture(includeSelection: Bool = false) -> TextTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXIsProcessTrusted() ? focused(app.processIdentifier) : nil
        let subrole = element.flatMap { attribute($0, kAXSubroleAttribute) as? String } ?? ""
        let secure = subrole == kAXSecureTextFieldSubrole || ["com.agilebits.onepassword7", "com.1password.1password", "com.apple.Passwords"].contains(app.bundleIdentifier ?? "")
        return TextTarget(pid: app.processIdentifier, appName: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? app.bundleIdentifier ?? "?", bundleID: app.bundleIdentifier ?? "", element: element, range: element.flatMap(selectedRange),
                          role: element.flatMap { attribute($0, kAXRoleAttribute) as? String },
                          selection: !secure && includeSelection ? (element.flatMap { attribute($0, kAXSelectedTextAttribute) as? String } ?? "") : "", secure: secure)
    }
    func stillMatches(requireSelection: Bool = false) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let element, let current = Self.focused(pid), CFEqual(element, current) else { return false }
        if let range {
            guard let currentRange = Self.selectedRange(current), range.location == currentRange.location, range.length == currentRange.length else { return false }
        }
        if requireSelection, (Self.attribute(current, kAXSelectedTextAttribute) as? String ?? "") != selection { return false }
        return true
    }
}

/// The text on either side of the cursor in the field Verb writes into, read through
/// Accessibility. Apps that don't show their text, such as VS Code, give nothing.
@MainActor struct FieldContext {
    let before: String
    let after: String

    /// Up to `reach` characters before the insertion point and `afterReach` after it.
    static func read(_ target: TextTarget, reach: Int = 400, afterReach: Int = 80) -> FieldContext? {
        guard !target.secure, let element = target.element, let range = target.range, range.location >= 0 else { return nil }
        // An app that doesn't answer quickly gets the text as dictated rather than a wait.
        AXUIElementSetMessagingTimeout(element, 0.5)
        let start = max(0, range.location - reach), afterStart = range.location + max(0, range.length)
        if let before = string(element, CFRange(location: start, length: range.location - start)) {
            let count = TextTarget.attribute(element, kAXNumberOfCharactersAttribute) as? Int
            let length = count.map { max(0, min(afterReach, $0 - afterStart)) } ?? afterReach
            return FieldContext(before: before, after: length > 0 ? string(element, CFRange(location: afterStart, length: length)) ?? "" : "")
        }
        guard let value = TextTarget.attribute(element, kAXValueAttribute) as? String else { return nil }
        let text = value as NSString
        guard text.length < 500_000, range.location <= text.length else { return nil }
        let afterLength = max(0, min(afterReach, text.length - afterStart))
        return FieldContext(before: text.substring(with: NSRange(location: start, length: range.location - start)),
                            after: afterStart <= text.length ? text.substring(with: NSRange(location: afterStart, length: afterLength)) : "")
    }

    /// The field's text near the cursor, and the window's title, for the names they hold.
    static func nearbyText(_ target: TextTarget, reach: Int = 3000) -> String? {
        guard !target.secure else { return nil }
        var parts: [String] = []
        if let element = target.element, let range = target.range {
            AXUIElementSetMessagingTimeout(element, 0.5)
            let start = max(0, range.location - reach)
            if let text = string(element, CFRange(location: start, length: range.location - start + 800)) ?? window(of: element, around: range, reach: reach) { parts.append(text) }
        }
        let app = AXUIElementCreateApplication(target.pid)
        if let value = TextTarget.attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID(),
           let title = TextTarget.attribute(unsafeBitCast(value, to: AXUIElement.self), kAXTitleAttribute) as? String, !title.isEmpty { parts.append(title) }
        return parts.isEmpty ? nil : parts.joined(separator: ".\n")
    }

    /// Part of an element's text, by range, or cut from its whole text for apps (Chromium, Electron)
    /// that give the whole but not a part.
    static func text(_ element: AXUIElement, _ range: CFRange) -> String? {
        if let part = string(element, range) { return part }
        guard let value = TextTarget.attribute(element, kAXValueAttribute) as? String else { return nil }
        let whole = value as NSString
        guard range.location >= 0, range.location <= whole.length, whole.length < 500_000 else { return nil }
        return whole.substring(with: NSRange(location: range.location, length: min(range.length, whole.length - range.location)))
    }
    /// Part of an element's text, by range.
    static func string(_ element: AXUIElement, _ range: CFRange) -> String? {
        guard range.location >= 0, range.length > 0 else { return range.length == 0 ? "" : nil }
        var value = range
        guard let parameter = AXValueCreate(.cfRange, &value) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result) == .success else {
            // Some fields refuse a range past their end: ask again within it.
            if let count = TextTarget.attribute(element, kAXNumberOfCharactersAttribute) as? Int, range.location + range.length > count, range.location < count {
                return string(element, CFRange(location: range.location, length: count - range.location))
            }
            return nil
        }
        return result as? String
    }
    private static func window(of element: AXUIElement, around range: CFRange, reach: Int) -> String? {
        guard let value = TextTarget.attribute(element, kAXValueAttribute) as? String else { return nil }
        let text = value as NSString
        guard range.location <= text.length else { return nil }
        let start = max(0, range.location - reach), end = min(text.length, range.location + 800)
        return text.substring(with: NSRange(location: start, length: end - start))
    }
}

/// Gives the pasted text to the app that asks for it, and tells Verb the moment it did.
private final class PasteSupply: NSObject, NSPasteboardItemDataProvider {
    let text: String, html: String?, rtf: Data?
    var read: () -> Void = {}
    init(text: String, html: String?, rtf: Data?) { self.text = text; self.html = html; self.rtf = rtf }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .html: if let html { item.setString(html, forType: .html) }
        case .rtf: if let rtf { item.setData(rtf, forType: .rtf) }
        default: item.setString(text, forType: .string)
        }
        read()
    }
}

@MainActor final class TextInserter {
    private var previousClipboard: [[NSPasteboard.PasteboardType: Data]] = []
    private var pastedChangeCount: Int?
    private var supply: PasteSupply?
    private var restoreSoon = false
    var hasPreviousClipboard: Bool { pastedChangeCount != nil }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); pastedChangeCount = nil; previousClipboard = [] }
    func restoreClipboard() {
        guard let count = pastedChangeCount, NSPasteboard.general.changeCount == count else { pastedChangeCount = nil; return }
        Self.write(previousClipboard, to: NSPasteboard.general); pastedChangeCount = nil; previousClipboard = []
        supply = nil; restoreSoon = false
    }
    /// Every item on the clipboard, with every kind of data it holds.
    private static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }) }
    }
    private static func write(_ saved: [[NSPasteboard.PasteboardType: Data]], to board: NSPasteboard) {
        let items = saved.map { values -> NSPasteboardItem in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }
        board.clearContents(); board.writeObjects(items)
    }
    /// The app took the paste: what you had copied comes back a quarter of a second later, time
    /// enough for it to read every kind of text it wants, so your next ⌘V is yours.
    private func pasteWasRead() {
        guard let count = pastedChangeCount, !restoreSoon else { return }
        restoreSoon = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.pastedChangeCount == count else { return }
            self.restoreClipboard()
        }
    }
    /// Delivery notes for text that was not pasted. The clipboard is left alone: the text waits
    /// as the last dictation, for the paste-last and copy keys. They all end the same way, which
    /// is how the rest of the app tells them apart from a paste.
    static let keptNoField = "No text field · kept as your last dictation"
    static let keptMoved = "Destination changed · kept as your last dictation"

    /// `html` carries a formatted snippet's formatting; apps that don't read it get `text`.
    func insert(_ text: String, html: String? = nil, target: TextTarget?, requireSelection: Bool = false) async throws -> String {
        guard let target else { return Self.keptNoField }
        guard !target.secure else { return "Sensitive field · ready to copy" }
        guard AXIsProcessTrusted() else { return "Accessibility is off · kept as your last dictation" }
        // With nothing to type into, such as the desktop, the text waits as the last dictation.
        guard target.verdict != .none else { return Self.keptNoField }
        guard target.stillMatches(requireSelection: requireSelection) else { return Self.keptMoved }

        // Paste must run after the dictation/paste-last shortcut has been released.
        // Otherwise a physical Control/Option/Fn modifier can alter Command-V. Someone holding the
        // keys to dictate again gets the paste as soon as they let go.
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let deadline = Date().addingTimeInterval(8)
        while !CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty {
            try Task.checkCancellation()
            guard Date() < deadline else { return "Keys still held · kept as your last dictation" }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try Task.checkCancellation()
        guard target.stillMatches(requireSelection: requireSelection) else { return Self.keptMoved }
        guard let source = CGEventSource(stateID: .privateState), let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return "Could not send paste · kept as your last dictation" }

        // AXSelectedText can report success without updating web/Electron editors
        // or firing their input events. Use the application's normal paste path.
        guard stage(text, html: html), let changeCount = pastedChangeCount else { return "Clipboard unavailable · kept as your last dictation" }
        guard target.stillMatches(requireSelection: requireSelection) else { restoreClipboard(); return Self.keptMoved }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: TypingContext.marker); up.setIntegerValueField(.eventSourceUserData, value: TypingContext.marker)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // What you had copied comes back as soon as the app has read the paste (see
        // pasteWasRead), or after a second and a half if it never does; unless something new was
        // copied in the meantime.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.pastedChangeCount == changeCount else { return }
            self.restoreClipboard()
        }
        // Posting an event has no delivery acknowledgement; don't claim AX success.
        return "Paste sent to \(target.appName)"
    }

    /// Reads the selection by copying it, for apps that don't show their selection to
    /// Accessibility, such as VS Code, Sublime Text and many Electron apps. It waits for the
    /// keys to be let go, as a held ⌃ or ⌥ would change ⌘C, and gives the clipboard its
    /// contents back straight after.
    func copySelection() async throws -> String? {
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let deadline = Date().addingTimeInterval(1.5)
        while !CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty {
            try Task.checkCancellation()
            guard Date() < deadline else { return nil }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { return nil }
        let board = NSPasteboard.general
        // While the last paste is still on the clipboard, what you had copied is the one saved before it.
        let pending = pastedChangeCount == board.changeCount
        let saved = pending ? previousClipboard : Self.snapshot(board)
        if pending { pastedChangeCount = nil; previousClipboard = []; supply = nil; restoreSoon = false }
        let before = board.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: TypingContext.marker); up.setIntegerValueField(.eventSourceUserData, value: TypingContext.marker)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // The app copies in its own time; half a second is plenty. Nothing copied means nothing selected.
        var copied: String?
        for _ in 0..<25 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if board.changeCount != before { copied = board.string(forType: .string); break }
        }
        let putBack = { Self.write(saved, to: board) }
        if board.changeCount != before || pending { putBack() }
        if copied == nil {
            // An app slow to copy gets the clipboard back all the same, when it does.
            let now = board.changeCount
            Task { @MainActor in
                for _ in 0..<40 { try? await Task.sleep(nanoseconds: 50_000_000); if board.changeCount != now { putBack(); return } }
            }
        }
        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return copied
    }

    /// Moves the cursor back over the last `count` characters just pasted, to where a
    /// snippet's {cursore} was. The arrows follow the paste in the same queue of events.
    func moveCursorBack(_ count: Int) {
        let steps = min(count, 400)
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let source = CGEventSource(stateID: .privateState) else { return }
            for _ in 0..<steps {
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: false) else { return }
                down.flags = []; up.flags = []
                down.setIntegerValueField(.eventSourceUserData, value: TypingContext.marker); up.setIntegerValueField(.eventSourceUserData, value: TypingContext.marker)
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            }
        }
    }

    /// Puts the text on the clipboard for the paste, keeping what was there to put it back.
    /// Clipboard managers are told it is transient, so it stays out of their history.
    private func stage(_ text: String, html: String? = nil) -> Bool {
        let board = NSPasteboard.general
        // While the last paste is still on the clipboard, what you had copied stays the one saved before it.
        if pastedChangeCount != board.changeCount { previousClipboard = Self.snapshot(board) }
        board.clearContents()
        let item = NSPasteboardItem()
        var document: String?, rtf: Data?
        if let html {
            // Web apps read the HTML, Mail and Notes the RTF; the fonts stay the app's own.
            document = "<meta charset=\"utf-8\">" + html
            if let data = document?.data(using: .utf8),
               let attributed = try? NSMutableAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
                attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                    guard let font = value as? NSFont else { return }
                    let traits = font.fontDescriptor.symbolicTraits
                    let base = traits.contains(.monoSpace) ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 13)
                    let styled = NSFontManager.shared.convert(base, toHaveTrait: NSFontTraitMask(rawValue: UInt(traits.intersection([.bold, .italic]).rawValue)))
                    attributed.addAttribute(.font, value: styled, range: range)
                }
                rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            }
        }
        // The text is handed over when the app asks for it, which is how Verb knows the paste was taken.
        let supply = PasteSupply(text: text, html: document, rtf: rtf)
        supply.read = { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.pasteWasRead() } } }
        item.setDataProvider(supply, forTypes: [.string] + (document == nil ? [] : [.html]) + (rtf == nil ? [] : [.rtf]))
        self.supply = supply; restoreSoon = false
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        guard board.writeObjects([item]) else { pastedChangeCount = board.changeCount; restoreClipboard(); return false }
        pastedChangeCount = board.changeCount
        return true
    }
}
