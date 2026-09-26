import Foundation

/// The parts of a snippet filled in when it is said: today's date, the time, the day, what is
/// on the clipboard, and where the cursor stops. Each has an Italian and an English name, and
/// the name sets the language: {data} is "26 settembre 2026", {date} is "September 26, 2026".
public enum SnippetVariables {
    /// Stands in for {cursore} until the text is in place. A private-use character, so no
    /// dictation or model ever writes it.
    public static let cursorMark: Character = "\u{E000}"
    public static let names = ["data", "ora", "giorno", "appunti", "cursore", "date", "time", "weekday", "clipboard", "cursor"]
    private static let pattern = try! NSRegularExpression(pattern: #"\{\s*(data|date|ora|time|giorno|weekday|appunti|clipboard|cursore|cursor)\s*\}"#, options: [.caseInsensitive])

    public static func hasVariables(_ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The snippet with its variables filled in. Only the first {cursore} counts.
    public static func fill(_ text: String, now: Date = Date(), clipboard: () -> String? = { nil }) -> String {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let firstCursor = matches.first { ["cursore", "cursor"].contains(ns.substring(with: $0.range(at: 1)).lowercased()) }?.range
        var copied: String??
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let value: String
            switch ns.substring(with: match.range(at: 1)).lowercased() {
            case "data": value = format(now, "d MMMM yyyy", "it_IT")
            case "date": value = format(now, "MMMM d, yyyy", "en_US")
            case "ora": value = format(now, "HH:mm", "it_IT")
            case "time": value = format(now, "h:mm a", "en_US")
            case "giorno": value = format(now, "EEEE", "it_IT")
            case "weekday": value = format(now, "EEEE", "en_US")
            case "appunti", "clipboard":
                if copied == nil { copied = .some(clipboard()) }
                value = (copied ?? nil) ?? ""
            default: value = match.range == firstCursor ? String(cursorMark) : ""
            }
            result.replaceCharacters(in: match.range, with: value)
        }
        return result as String
    }

    /// The text without the cursor mark, and how many characters come after it: the cursor
    /// goes back that far once the text is in.
    public static func placeCursor(in text: String) -> (text: String, back: Int) {
        guard let index = text.firstIndex(of: cursorMark) else { return (text, 0) }
        let back = text[text.index(after: index)...].count
        return (text.replacingOccurrences(of: String(cursorMark), with: ""), back)
    }

    private static func format(_ date: Date, _ template: String, _ locale: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.dateFormat = template
        return formatter.string(from: date)
    }
}
