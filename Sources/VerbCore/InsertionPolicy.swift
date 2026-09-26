import Foundation

/// Whether the element in front can take text, judged from what Accessibility reports about it.
public enum InsertionPolicy {
    public enum Verdict: Equatable, Sendable {
        /// A text field, text area or editor: paste into it.
        case textField
        /// Something is focused but may not take text, as in some web and Electron apps.
        /// Paste anyway, and leave the text on the clipboard in case nothing arrived.
        case unknown
        /// Nothing can take text here, such as the desktop: copy the text for ⌘V instead.
        case none
    }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    public static func verdict(hasElement: Bool, role: String?, hasTextRange: Bool, bundleID: String, isVerb: Bool) -> Verdict {
        guard hasElement, !isVerb else { return .none }
        if hasTextRange || textRoles.contains(role ?? "") { return .textField }
        // The desktop and Finder windows take files, not text.
        if bundleID == "com.apple.finder" { return .none }
        return .unknown
    }
}
