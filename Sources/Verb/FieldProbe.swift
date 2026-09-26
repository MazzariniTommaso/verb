import AppKit
import ApplicationServices

/// Reports what each open app shows Accessibility about its focused text field: its role, how
/// long its text is, where the cursor is, and whether a range of it can be read. Only sizes and
/// flags are written, never the text:
///
///     open -n -g release/Verb.app --args --probe-fields /path/to/result.txt [--wake]
///
/// With --wake, Chromium and Electron apps are first asked to switch their accessibility on
/// (AXManualAccessibility), as Verb does before a dictation.
@MainActor enum FieldProbe {
    static func run(output: URL, wake: Bool) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        if wake { for app in apps { FieldReach.wake(app) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + (wake ? 1.5 : 0.1)) {
            var lines = ["trusted: \(AXIsProcessTrusted())"]
            for app in apps.sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) { lines.append(describe(app)) }
            try? lines.joined(separator: "\n").appending("\n").write(to: output, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private static func describe(_ app: NSRunningApplication) -> String {
        let name = (app.localizedName ?? "?") + " (" + (app.bundleIdentifier ?? "?") + ")"
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        guard let focused = TextTarget.attribute(element, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return "\(name): no focused element" }
        let field = unsafeBitCast(focused, to: AXUIElement.self)
        let role = TextTarget.attribute(field, kAXRoleAttribute) as? String ?? "-"
        let subrole = TextTarget.attribute(field, kAXSubroleAttribute) as? String ?? "-"
        let value = TextTarget.attribute(field, kAXValueAttribute)
        let valueText = (value as? String).map { "text \(($0 as NSString).length)" } ?? (value == nil ? "none" : "not text")
        let count = TextTarget.attribute(field, kAXNumberOfCharactersAttribute) as? Int
        let range = TextTarget.selectedRange(field)
        var readable = "-"
        if let range {
            let start = max(0, range.location - 20)
            readable = FieldContext.string(field, CFRange(location: start, length: range.location - start)).map { "reads \(($0 as NSString).length) before" } ?? "range unreadable"
        }
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(field, &names)
        let stringForRange = ((names as? [String]) ?? []).contains(kAXStringForRangeParameterizedAttribute)
        return "\(name): role \(role)/\(subrole), value \(valueText), characters \(count.map(String.init) ?? "-"), cursor \(range.map { "\($0.location)+\($0.length)" } ?? "none"), \(readable), string-for-range \(stringForRange)"
    }
}
