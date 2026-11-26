import AppKit
import ApplicationServices
import Carbon
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
    /// The window's title and the characters just before the cursor, to tell the field from the
    /// same field showing another conversation or file.
    var title: String? = nil
    var before: String? = nil
    /// The app was too slow to say what has focus: it is asked again when the text is ready.
    var unanswered = false
    /// Whether the focused element can take the text, or Verb should copy it for ⌘V instead.
    var verdict: InsertionPolicy.Verdict {
        InsertionPolicy.verdict(hasElement: element != nil, role: role, hasTextRange: range != nil, bundleID: bundleID, isVerb: pid == ProcessInfo.processInfo.processIdentifier)
    }
    /// Apps that hold passwords: nothing typed or read there.
    static let sensitiveApps: Set<String> = ["com.agilebits.onepassword7", "com.1password.1password", "com.apple.Passwords", "com.apple.keychainaccess", "com.bitwarden.desktop",
                                             "org.keepassxc.keepassxc", "com.lastpass.LastPass", "in.sinew.Enpass-Desktop"]
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    static func focused(_ pid: pid_t) -> AXUIElement? { element(attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)) }
    /// What has the keyboard: the focused element of the whole Mac, which is where a panel such
    /// as Spotlight's or Alfred's types although it never becomes the app in front. The front
    /// app when the Mac can't say, `unanswered` when that app didn't reply in time.
    static func focusedNow() -> (pid: pid_t, element: AXUIElement?, unanswered: Bool)? {
        let front = NSWorkspace.shared.frontmostApplication
        guard AXIsProcessTrusted() else { return front.map { ($0.processIdentifier, nil, false) } }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value)
        if result == .success, let found = element(value) {
            var pid: pid_t = 0
            if AXUIElementGetPid(found, &pid) == .success, pid > 0 { return (pid, found, false) }
        }
        guard let front else { return nil }
        if result == .cannotComplete { return (front.processIdentifier, nil, true) }
        var own: CFTypeRef?
        let answer = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(front.processIdentifier), kAXFocusedUIElementAttribute as CFString, &own)
        return (front.processIdentifier, answer == .success ? element(own) : nil, answer == .cannotComplete)
    }
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }
    /// The title of the window the element is in.
    static func windowTitle(_ element: AXUIElement, pid: pid_t) -> String? {
        let window = self.element(attribute(element, kAXWindowAttribute)) ?? self.element(attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute))
        return window.flatMap { attribute($0, kAXTitleAttribute) as? String }
    }
    /// The few characters before the cursor, when the field shows them.
    static func textBefore(_ element: AXUIElement, range: CFRange?) -> String? {
        guard let range, range.location >= 0 else { return nil }
        let start = max(0, range.location - 48)
        return FieldContext.string(element, CFRange(location: start, length: range.location - start))
    }
    static func capture(includeSelection: Bool = false) -> TextTarget? {
        guard let focus = focusedNow() else { return nil }
        let app = NSRunningApplication(processIdentifier: focus.pid)
        let bundleID = app?.bundleIdentifier ?? "", element = focus.element
        let subrole = element.flatMap { attribute($0, kAXSubroleAttribute) as? String } ?? ""
        let secure = subrole == kAXSecureTextFieldSubrole || sensitiveApps.contains(bundleID)
        let range = element.flatMap(selectedRange)
        return TextTarget(pid: focus.pid, appName: app?.localizedName ?? app?.bundleURL?.deletingPathExtension().lastPathComponent ?? (bundleID.isEmpty ? "?" : bundleID), bundleID: bundleID, element: element, range: range,
                          role: element.flatMap { attribute($0, kAXRoleAttribute) as? String },
                          selection: !secure && includeSelection ? (element.flatMap { attribute($0, kAXSelectedTextAttribute) as? String } ?? "") : "", secure: secure,
                          title: element.flatMap { windowTitle($0, pid: focus.pid) }, before: secure ? nil : element.flatMap { textBefore($0, range: range) },
                          unanswered: focus.unanswered || (element == nil && FieldReach.recentlyWoken(focus.pid)))
    }
    func stillMatches(requireSelection: Bool = false) -> Bool {
        guard let element, let now = Self.focusedNow(), now.pid == pid, let current = now.element else { return false }
        if let range {
            guard let currentRange = Self.selectedRange(current), range.location == currentRange.location, range.length == currentRange.length else { return false }
        }
        let same = CFEqual(element, current)
        let terminal = CodeBundles.terminals.contains(bundleID)
        guard FieldIdentity.same(element: same, title: title, titleNow: terminal ? nil : Self.windowTitle(current, pid: pid), before: before,
                                 beforeNow: terminal || before == nil ? nil : Self.textBefore(current, range: range), terminal: terminal) else { return false }
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

/// The keys that type “v” and “c” with ⌘ held on the keyboard layout in use: Dvorak and other
/// layouts move them. QWERTY's keys when the layout can't say.
@MainActor enum CommandKeys {
    private static var known: (layout: String, keys: [Character: CGKeyCode])?
    static var paste: CGKeyCode { key("v", standard: 9) }
    static var copy: CGKeyCode { key("c", standard: 8) }

    private static func key(_ letter: Character, standard: CGKeyCode) -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return standard }
        let layout = TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
        if known?.layout != layout {
            let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
            known = (layout, keys(in: source) ?? ascii.flatMap(keys) ?? [:])
        }
        return known?.keys[letter] ?? standard
    }
    /// The key that types each of Verb's letters with ⌘ held, QWERTY's own first when it still does.
    private static func keys(in source: TISInputSource) -> [Character: CGKeyCode]? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let command = UInt32((cmdKey >> 8) & 0xFF), keyboard = UInt32(LMGetKbdType())
        var found: [Character: CGKeyCode] = [:]
        for code in [9, 8] + Array(0..<128) {
            var dead: UInt32 = 0, length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            guard UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), command, keyboard, OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, characters.count, &length, &characters) == noErr,
                  length == 1, let letter = String(utf16CodeUnits: characters, count: 1).lowercased().first, letter == "v" || letter == "c", found[letter] == nil else { continue }
            found[letter] = CGKeyCode(code)
        }
        return found.count == 2 ? found : nil
    }
}

@MainActor final class TextInserter {
    private var previousClipboard: [[NSPasteboard.PasteboardType: Data]] = []
    private var pastedChangeCount: Int?
    private var supply: PasteSupply?
    /// When the app last read the paste, and when ⌘V went out.
    private var lastRead: Date?, posted: Date?
    /// Called if the app takes a paste after Verb said it hadn't.
    private var late: (() -> Void)?
    /// The clipboard as it was at a change count, so the next dictation doesn't read it again.
    private var known: (count: Int, items: [[NSPasteboard.PasteboardType: Data]])?
    var hasPreviousClipboard: Bool { pastedChangeCount != nil }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); pastedChangeCount = nil; previousClipboard = []; late = nil }
    func restoreClipboard() {
        guard let count = pastedChangeCount, NSPasteboard.general.changeCount == count else { pastedChangeCount = nil; late = nil; return }
        let saved = previousClipboard
        Self.write(saved, to: NSPasteboard.general); pastedChangeCount = nil; previousClipboard = []
        supply = nil; lastRead = nil; posted = nil; late = nil
        settle(saved)
    }
    /// What Verb put back is what you had copied: the next dictation needn't read it again. A
    /// password goes again after a minute and a half, as password managers clear it: putting it
    /// back would otherwise keep it there for good.
    private func settle(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        let board = NSPasteboard.general, count = board.changeCount
        known = (count, saved)
        guard saved.contains(where: { $0[Self.concealed] != nil }) else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard board.changeCount == count else { return }
            board.clearContents(); self?.known = nil
        }
    }
    /// Whether a modifier key is physically down. The paste and the copy wait until none is, as a
    /// held ⌃ or ⌥ would change the shortcut. It asks for the keys themselves: the modifier flags
    /// also keep the ⌘ of a shortcut Verb just posted, until a real key clears them.
    static var modifierKeysDown: Bool {
        // ⌘, ⇧, ⌥ and ⌃ on either side, and fn; Caps Lock locks rather than holds.
        [54, 55, 56, 58, 59, 60, 61, 62, 63].contains { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }
    }
    /// ⌘ and a key, as the app in front gets them from the keyboard, then ⌘ let go, so the Mac is
    /// never left believing ⌘ is still held.
    private static func postCommand(_ keyCode: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
              let release = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        release.type = .flagsChanged; release.flags = []
        for event in [down, up, release] {
            event.setIntegerValueField(.eventSourceUserData, value: TypingContext.marker)
            event.post(tap: .cghidEventTap)
        }
        return true
    }
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// Files an app promised to deliver: only that app can, so they can't be kept.
    private static let promised: Set<String> = ["com.apple.pasteboard.promised-file-content-type", "com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-suggested-file-name",
                                                "com.apple.NSFilePromiseItemMetaData", "NSPromiseContentsPboardType", "Apple files promise pasteboard type"]
    /// Every item on the clipboard, with every kind of data it holds. Past 200 MB, as with a large
    /// spreadsheet range or image, each further item keeps only its main kind.
    private func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        if let known, known.count == board.changeCount { return known.items }
        var total = 0
        let items = (board.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types where !Self.promised.contains(type.rawValue) && (total < 200_000_000 || values.isEmpty) {
                guard let data = item.data(forType: type) else { continue }
                values[type] = data; total += data.count
            }
            return values
        }.filter { !$0.isEmpty }
        known = (board.changeCount, items)
        return items
    }
    /// Puts back what was saved, marked as transient so clipboard managers don't take it for a new copy.
    private static func write(_ saved: [[NSPasteboard.PasteboardType: Data]], to board: NSPasteboard) {
        let items = saved.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            if values[transient] == nil { item.setData(Data(), forType: transient) }
            return item
        }
        board.clearContents(); board.writeObjects(items)
    }
    /// The app read the paste. What you had copied comes back a quarter of a second after its
    /// last read, time enough for every kind of text it wants, and half a second after ⌘V at the
    /// soonest, so your next ⌘V is yours. An app slower than Verb said gets its note put right.
    private func pasteWasRead() {
        guard pastedChangeCount != nil else { return }
        lastRead = Date()
        if let late { self.late = nil; late() }
    }
    private func restoreWhenRead(_ changeCount: Int) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, self.pastedChangeCount == changeCount else { return }
                let now = Date(), posted = self.posted ?? now
                // An app that never reads it gets ten seconds, for the slowest, then the clipboard is yours again.
                let done = self.lastRead.map { now.timeIntervalSince($0) >= 0.25 && now.timeIntervalSince(posted) >= 0.5 } ?? (now.timeIntervalSince(posted) >= 10)
                if done { self.restoreClipboard(); return }
            }
        }
    }
    /// Delivery notes for text that was not pasted. The clipboard is left alone: the text waits
    /// as the last dictation, for the paste-last and copy keys. They all end the same way, which
    /// is how the rest of the app tells them apart from a paste.
    static let keptNoField = "No text field · kept as your last dictation"
    static let keptInHistory = "Not pasted · kept in History"
    static let keptMoved = "Destination changed · kept as your last dictation"
    static let retried = "Retried · the new text is in History"
    static func notTaken(_ app: String) -> String { "\(app) didn’t take the paste · kept as your last dictation" }

    /// `html` carries a formatted snippet's formatting; apps that don't read it get `text`.
    /// `copied` is the selection read by copying it, for an app that hides it from Accessibility.
    /// `late` is called if the app takes the paste after Verb said it hadn't.
    func insert(_ text: String, html: String? = nil, target: TextTarget?, requireSelection: Bool = false, copied: String? = nil, late: (() -> Void)? = nil) async throws -> String {
        guard var target else { return Self.keptNoField }
        guard !target.secure else { return "Sensitive field · ready to copy" }
        guard AXIsProcessTrusted() else { return "Accessibility is off · kept as your last dictation" }
        // An app that was too slow to say what had focus is asked again, if it is still the one in front.
        if target.unanswered, !requireSelection, let again = TextTarget.capture(), again.pid == target.pid, !again.unanswered {
            target = again
            guard !target.secure else { return "Sensitive field · ready to copy" }
        }
        // With nothing to type into, such as the desktop, the text waits as the last dictation.
        guard target.verdict != .none else { return Self.keptNoField }
        guard target.stillMatches(requireSelection: requireSelection) else { return Self.keptMoved }

        // Paste must run after the dictation/paste-last shortcut has been released.
        // Otherwise a physical Control/Option/Fn modifier can alter Command-V. Someone holding the
        // keys to dictate again gets the paste as soon as they let go.
        let deadline = Date().addingTimeInterval(8)
        while Self.modifierKeysDown {
            try Task.checkCancellation()
            guard Date() < deadline else { return "Keys still held · kept as your last dictation" }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try Task.checkCancellation()
        guard target.stillMatches(requireSelection: requireSelection) else { return Self.keptMoved }
        // Accessibility can't tell whether a hidden selection moved: it is copied again, and the text
        // goes in only where that selection still is.
        if requireSelection, let copied {
            guard try await copySelection(for: target) == copied else { return Self.keptMoved }
            guard target.stillMatches(requireSelection: requireSelection) else { return Self.keptMoved }
        }

        // AXSelectedText can report success without updating web/Electron editors
        // or firing their input events. Use the application's normal paste path.
        guard stage(text, html: html), let changeCount = pastedChangeCount else { return "Clipboard unavailable · kept as your last dictation" }
        guard target.stillMatches(requireSelection: requireSelection) else { restoreClipboard(); return Self.keptMoved }
        guard Self.postCommand(CommandKeys.paste) else { restoreClipboard(); return "Could not send paste · kept as your last dictation" }
        posted = Date()
        restoreWhenRead(changeCount)
        // The app takes the paste by reading the clipboard, most within a tenth of a second. One
        // that hasn't in a second likely had nowhere to put it: the text stays on the clipboard
        // for a while all the same, in case it is only slow.
        for _ in 0..<50 {
            if lastRead != nil || pastedChangeCount != changeCount { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard lastRead == nil, pastedChangeCount == changeCount else { return "Paste sent to \(target.appName)" }
        self.late = late
        return Self.notTaken(target.appName)
    }

    /// Reads the selection by copying it, for apps that don't show their selection to
    /// Accessibility, such as VS Code, Sublime Text and many Electron apps. It waits for the
    /// keys to be let go, as a held ⌃ or ⌥ would change ⌘C, copies only while the field is still
    /// the one you spoke for, and gives the clipboard its contents back straight after.
    func copySelection(for target: TextTarget) async throws -> String? {
        let deadline = Date().addingTimeInterval(1.5)
        while Self.modifierKeysDown {
            try Task.checkCancellation()
            guard Date() < deadline else { return nil }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard AXIsProcessTrusted(), target.stillMatches() else { return nil }
        let board = NSPasteboard.general
        // While the last paste is still on the clipboard, what you had copied is the one saved before it.
        let pending = pastedChangeCount == board.changeCount
        let saved = pending ? previousClipboard : snapshot(board)
        if pending { pastedChangeCount = nil; previousClipboard = []; supply = nil; lastRead = nil; posted = nil; late = nil }
        let before = board.changeCount
        guard Self.postCommand(CommandKeys.copy) else { if pending { Self.write(saved, to: board); settle(saved) }; return nil }
        // The app copies in its own time; half a second is plenty. Nothing copied means nothing selected.
        var copied: String?
        for _ in 0..<25 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if board.changeCount != before { copied = Self.selection(on: board); break }
        }
        let putBack = { [weak self] in Self.write(saved, to: board); self?.settle(saved) }
        if board.changeCount != before || pending { putBack() }
        // An app slow to copy gets the clipboard back all the same, when it does; a password stays gone.
        if copied == nil, !saved.contains(where: { $0[Self.concealed] != nil }) {
            let now = board.changeCount
            Task { @MainActor in
                for _ in 0..<40 { try? await Task.sleep(nanoseconds: 50_000_000); if board.changeCount != now { putBack(); return } }
            }
        }
        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return copied
    }
    /// The text an app copied, unless it copied the whole line because nothing was selected, as
    /// VS Code and its kin do and say in the data they copy with it.
    private static func selection(on board: NSPasteboard) -> String? {
        let metadata = board.string(forType: NSPasteboard.PasteboardType("vscode-editor-data"))
            ?? ["org.chromium.web-custom-data", "chromium/x-web-custom-data"].lazy.compactMap { board.data(forType: NSPasteboard.PasteboardType($0)) }.first.flatMap { CopiedText.chromiumCustomData($0)["vscode-editor-data"] }
        if let metadata, CopiedText.isWholeLine(metadata: metadata) { return nil }
        return board.string(forType: .string)
    }

    /// Moves the cursor back over the last `count` characters just pasted, to where a
    /// snippet's {cursore} was. The arrows follow the paste in the same queue of events, and
    /// only while the app is still the one pasted into.
    func moveCursorBack(_ count: Int, in target: TextTarget) {
        let steps = min(count, 400)
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard TextTarget.focusedNow()?.pid == target.pid, let source = CGEventSource(stateID: .privateState) else { return }
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
        if pastedChangeCount != board.changeCount { previousClipboard = snapshot(board) }
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
        self.supply = supply; lastRead = nil; posted = nil; late = nil
        item.setData(Data(), forType: Self.transient)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        guard board.writeObjects([item]) else { pastedChangeCount = board.changeCount; restoreClipboard(); return false }
        pastedChangeCount = board.changeCount
        return true
    }
}
