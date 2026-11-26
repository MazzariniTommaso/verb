import Foundation

/// Tells whether the field Verb is about to paste into is still the one the dictation was for.
public enum FieldIdentity {
    /// A window title without what apps change on their own while you speak: unread counts,
    /// the edited dot, spinners. Nil when nothing is left to compare.
    public static func plainTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let letters = String(String.UnicodeScalarView(title.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) }))
        return letters.isEmpty ? nil : letters
    }

    /// Whether the field in front now is the one dictated into. Some apps keep one field for
    /// every conversation or file, so the same field must also be in the same window, with the
    /// same text before the cursor. A field the app drew again, as a chat may when a message
    /// arrives, counts as the same when its window and the text before the cursor match and
    /// there is text to compare. Terminals retitle themselves as they work: there the field is enough.
    public static func same(element: Bool, title: String?, titleNow: String?, before: String?, beforeNow: String?, terminal: Bool) -> Bool {
        if terminal { return element }
        let then = plainTitle(title), now = plainTitle(titleNow)
        if element {
            let sameWindow = then == nil || now == nil || then == now
            let sameText = before == nil || beforeNow == nil || before == beforeNow
            return sameWindow && sameText
        }
        guard let then, let now, then == now, let before, let beforeNow, !before.isEmpty else { return false }
        return before == beforeNow
    }
}

/// What an app said about the text it copied.
public enum CopiedText {
    /// VS Code, Cursor and their kin copy the whole line when nothing is selected, and say so in
    /// the JSON they put on the clipboard next to the text.
    public static func isWholeLine(metadata: String) -> Bool {
        guard let data = metadata.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["isFromEmptySelection"] as? Bool == true
    }

    /// The extra kinds of data a Chromium or Electron app put on the clipboard, by name. They
    /// travel together as one pickled record: its size, a count, then each name and value as
    /// UTF-16, every part padded to four bytes.
    public static func chromiumCustomData(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var offset = 4
        func number() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            let value = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
            offset += 4
            return value
        }
        func text() -> String? {
            guard let count = number(), count >= 0, count < 10_000_000 else { return nil }
            let length = count * 2
            guard offset + length <= bytes.count else { return nil }
            let units = stride(from: offset, to: offset + length, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
            offset += (length + 3) & ~3
            return String(decoding: units, as: UTF16.self)
        }
        guard let entries = number(), entries >= 0, entries < 10_000 else { return [:] }
        var result: [String: String] = [:]
        for _ in 0..<entries {
            guard let name = text(), let value = text() else { break }
            result[name] = value
        }
        return result
    }
}
