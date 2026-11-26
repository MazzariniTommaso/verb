import Foundation

extension TextRules {
    /// Letters spelled one by one written as one word: "C O M P" and "c-o-m-p" become "COMP"
    /// and "comp". Three letters at least; vowels alone ("e i o") are words in Italian, not a spelling.
    public static func joiningSpelledLetters(_ text: String) -> String {
        let ns = text as NSString
        let result = NSMutableString(string: text)
        for match in spelledLetters.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let letters = ns.substring(with: match.range).filter(\.isLetter)
            guard letters.count >= 3 else { continue }
            if letters.allSatisfy({ "aeiouyAEIOUY".contains($0) }) && !letters.allSatisfy(\.isUppercase) { continue }
            // A dot after the last letter is the spelling's, unless it also ends the sentence there.
            var joined = letters
            if ns.substring(with: match.range).hasSuffix(".") {
                let rest = ns.substring(from: NSMaxRange(match.range))
                let next = rest.drop { $0 == " " }.first
                if next == nil || next?.isNewline == true || (rest.hasPrefix(" ") && next?.isUppercase == true) { joined += "." }
            }
            result.replaceCharacters(in: match.range, with: joined)
        }
        return result as String
    }
    /// One letter, then two or more letters each after a space, a hyphen, a comma or a dot, all
    /// capitals or all small: "è" and "à" are words, and "e C O M P" is "e" and a spelling.
    private static let spelledLetters = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(?:[A-Z](?:(?:, ?| |-|\. ?)[A-Z](?![\p{L}\p{N}])){2,}|[a-z](?:(?:, ?| |-|\. ?)[a-z](?![\p{L}\p{N}])){2,})\.?"#)

    /// The chat style: sentences open in small letters and the last full stop goes, as people
    /// write to friends. Names, acronyms and "I" keep their capitals.
    public static func chatCase(_ text: String, keep: Set<String> = []) -> String {
        var result = ""
        var opens = true
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if opens, character.isLetter {
                let end = text[index...].firstIndex { !$0.isLetter && $0 != "'" && $0 != "’" } ?? text.endIndex
                let word = String(text[index..<end])
                let titleCase = word.first?.isUppercase == true && !word.dropFirst().contains(where: \.isUppercase)
                let pronoun = word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’")
                result += titleCase && !pronoun && !keep.contains(word) && word.count > 1 ? word.prefix(1).lowercased() + word.dropFirst() : word
                index = end; opens = false; continue
            }
            if ".!?…".contains(character) || character.isNewline { opens = true }
            else if !character.isWhitespace && !"\"“«(".contains(character) { opens = false }
            result.append(character)
            index = text.index(after: index)
        }
        // The full stop at the very end goes; an ellipsis, a question and an exclamation stay.
        if result.hasSuffix("."), !result.hasSuffix(".."), !result.hasSuffix("…") { result.removeLast() }
        return result
    }
}
