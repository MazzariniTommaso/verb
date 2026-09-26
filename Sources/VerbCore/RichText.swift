import Foundation

/// A snippet written with a little Markdown (**bold**, *italic*, `code`, [links](https://…),
/// lists) pasted as formatted text. Apps that read formatting get the HTML; the others, such
/// as terminals, get the plain text.
public enum RichText {
    /// Whether the text uses any of the Markdown Verb formats.
    public static func hasFormatting(_ text: String) -> Bool {
        text.range(of: #"\*\*[^*\n]+\*\*|(?<![\w*])\*[^*\s][^*\n]*\*(?![\w*])|(?<![\w`])`[^`\n]+`|\[[^\]\n]+\]\([^)\s]+\)|(?m)^\s*(?:[-*•]|\d+[.)])\s+\S"#, options: .regularExpression) != nil
    }

    /// The Markdown as HTML: paragraphs and line breaks, bold, italic, code, links and lists.
    public static func html(fromMarkdown text: String) -> String {
        var blocks: [String] = [], paragraph: [String] = [], list: [String] = [], ordered = false
        func closeParagraph() { if !paragraph.isEmpty { blocks.append("<p>" + paragraph.joined(separator: "<br>") + "</p>"); paragraph = [] } }
        func closeList() { if !list.isEmpty { let tag = ordered ? "ol" : "ul"; blocks.append("<\(tag)>" + list.map { "<li>\($0)</li>" }.joined() + "</\(tag)>"); list = [] } }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let item = listItem(trimmed) {
                closeParagraph()
                if !list.isEmpty && ordered != item.ordered { closeList() }
                ordered = item.ordered; list.append(inline(item.text))
            } else if trimmed.isEmpty {
                closeParagraph(); closeList()
            } else {
                closeList(); paragraph.append(inline(trimmed))
            }
        }
        closeParagraph(); closeList()
        return blocks.joined()
    }

    /// The Markdown as plain text: the marks gone, links as "text (address)", list items
    /// with a bullet or their number.
    public static func plain(fromMarkdown text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let item = listItem(trimmed) else { return stripped(line) }
            return (item.ordered ? item.marker + " " : "• ") + stripped(item.text)
        }.joined(separator: "\n")
    }

    private static func listItem(_ line: String) -> (text: String, ordered: Bool, marker: String)? {
        if let match = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) { return (String(line[match.upperBound...]), false, "•") }
        if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return (String(line[match.upperBound...]), true, line[match].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    private static func inline(_ text: String) -> String {
        var html = escaped(text)
        html = html.replacingOccurrences(of: #"\[([^\]\n]+)\]\((https?://[^)\s]+|mailto:[^)\s]+)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        html = html.replacingOccurrences(of: #"(?<![\w`])`([^`\n]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        html = html.replacingOccurrences(of: #"\*\*([^*\n]+)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        html = html.replacingOccurrences(of: #"(?<![\w*])\*([^*\s][^*\n]*?)\*(?![\w*])"#, with: "<em>$1</em>", options: .regularExpression)
        html = html.replacingOccurrences(of: #"(?<![\w_])_([^_\s][^_\n]*?)_(?![\w_])"#, with: "<em>$1</em>", options: .regularExpression)
        return html
    }
    private static func stripped(_ text: String) -> String {
        var plain = text.replacingOccurrences(of: #"\[([^\]\n]+)\]\((?:mailto:)?([^)\s]+)\)"#, with: "$1 ($2)", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"(?<![\w`])`([^`\n]+)`"#, with: "$1", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"\*\*([^*\n]+)\*\*"#, with: "$1", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"(?<![\w*])\*([^*\s][^*\n]*?)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"(?<![\w_])_([^_\s][^_\n]*?)_(?![\w_])"#, with: "$1", options: .regularExpression)
        return plain
    }
}
