import Foundation

/// Fits a dictation into the text around the cursor, as you would type it: a space before it
/// when it follows a word, a small letter when it carries on a sentence, and a space after it,
/// without its full stop, when the sentence goes on after it.
public enum FieldFormatting {
    /// `before` and `after` are the field's text on either side of the insertion point; a
    /// little of each is enough. `isOrdinary` says whether a word is a common Italian or English
    /// word, so a name keeps its capital; `keep` holds spellings that never change.
    public static func adjust(_ text: String, before: String, after: String, isOrdinary: (String) -> Bool, keep: Set<String> = []) -> String {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return text }
        var result = text
        // Casing: a sentence starts after . ! ? … or a new line, or at the top of the field.
        var context = Substring(before)
        while let last = context.last, last == " " || last == "\t" || ")]}\"”’»'".contains(last) { context = context.dropLast() }
        let startsSentence = context.isEmpty || ".!?…\n\r".contains(context.last!)
        if let firstLetter = result.firstIndex(where: \.isLetter), result[..<firstLetter].allSatisfy({ !$0.isNumber }) {
            let word = String(result[firstLetter...].prefix { $0.isLetter || $0 == "'" || $0 == "’" })
            // Code keeps its case: userId, index.ts, max_size.
            let rest = result[firstLetter...].dropFirst(word.count)
            let isCode = word.dropFirst().contains(where: \.isUppercase) || rest.first == "_" || rest.first == "." && rest.dropFirst().first?.isLetter == true
            if isCode {
            } else if startsSentence {
                if result[firstLetter].isLowercase { result.replaceSubrange(firstLetter...firstLetter, with: result[firstLetter].uppercased()) }
            } else if result[firstLetter].isUppercase, lowercasesSafely(word, isOrdinary: isOrdinary, keep: keep) {
                result.replaceSubrange(firstLetter...firstLetter, with: result[firstLetter].lowercased())
            }
        }
        // A space before, after a word or a mark that ends a sentence. A straight quote opens
        // when it follows a space, and closes when it follows a word.
        if let last = before.last, !last.isWhitespace, let first = result.first, first.isLetter || first.isNumber || "“\"«([".contains(first) {
            let previous = before.dropLast().last
            let straight = last == "\"" || last == "'"
            var opens = straight ? previous?.isWhitespace ?? true : "([{“‘«/@#-–—".contains(last)
            // An elided word joins the next: "l’amico", "dell'anno".
            if last == "'" || last == "’", elides(before.dropLast()) { opens = true }
            // A dash set off by spaces is punctuation, not part of a word: "Il risultato – ottimo".
            if "-–—".contains(last), let previous, previous.isWhitespace, !previous.isNewline { opens = false }
            if !opens { result = " " + result }
        }
        // Inside a sentence: no full stop of its own, and a space before the words that follow,
        // unless the field has one there already ("Il film è | bello").
        let spaced = after.first == " " || after.first == "\t"
        if let next = after.first(where: { $0 != " " && $0 != "\t" }) {
            if next.isLetter || next.isNumber {
                if next.isLowercase, result.hasSuffix("."), !result.hasSuffix("..") { result.removeLast() }
                if let last = result.last, !last.isWhitespace, !spaced { result += " " }
            } else if ".,;:!?".contains(next), result.hasSuffix("."), !result.hasSuffix("..") {
                result.removeLast()
            }
        }
        return result
    }

    /// Italian words that lose their vowel before the next word: "l’", "un’", "dell’", "c’".
    static let elisions: Set<String> = ["l", "un", "d", "c", "m", "t", "s", "v", "n", "dell", "all", "dall", "nell", "sull", "coll", "pell", "quest", "quell",
                                        "bell", "sant", "tutt", "anch", "com", "dov", "cos", "quand", "mezz", "senz", "nient", "qualcos", "gliel", "ciascun", "nessun"]
    /// Whether the text ends with an elided word, the apostrophe already taken off.
    static func elides(_ text: Substring) -> Bool {
        let word = text.reversed().prefix { $0.isLetter }
        return !word.isEmpty && elisions.contains(String(word.reversed()).lowercased())
    }

    /// A capital can go when the word is common and is neither an acronym nor "I".
    static func lowercasesSafely(_ word: String, isOrdinary: (String) -> Bool, keep: Set<String>) -> Bool {
        guard word.count >= 2 || word.lowercased() != "i" else { return false }
        if ["I", "I'm", "I’m", "I'll", "I’ll", "I've", "I’ve", "I'd", "I’d"].contains(word) { return false }
        let letters = word.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return false }
        if letters.dropFirst().contains(where: \.isUppercase) { return false }
        if keep.contains(word) { return false }
        return isOrdinary(word.lowercased())
    }
}

/// Learns from the corrections you make to text Verb has just written: a word you retype,
/// such as "Tomaso" into "Tommaso" or "mercio" into "merge", can become a dictionary entry.
public enum CorrectionLearner {
    public struct Change: Equatable, Sendable {
        public let heard: String
        public let written: String
        public init(heard: String, written: String) { self.heard = heard; self.written = written }
    }
    public enum Suggestion: Equatable, Sendable {
        /// Replace what the engine writes with your spelling, every time.
        case replace(heard: String, word: String)
        /// Only a spelling to prefer: what the engine wrote is a common word, which a
        /// replacement would change everywhere.
        case spelling(String)
    }

    /// The words that changed between `inserted`, as Verb wrote it, and `current`, as the
    /// field reads now from the same point. Only retyped words count: added or removed text,
    /// and rewritten passages, don't.
    public static func changes(inserted: String, current: String) -> [Change] {
        let old = tokens(inserted), new = tokens(current)
        guard !old.isEmpty, !new.isEmpty, old.count <= 400, new.count <= 480 else { return [] }
        // Longest common run of words, then the gaps between the matches.
        var table = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        // Most of Verb's words must still be there, or this is not the same text any more.
        guard Double(table[0][0]) >= Double(old.count) * 0.5 else { return [] }
        var changes: [Change] = []
        var i = 0, j = 0, removed: [String] = [], added: [String] = []
        func flush(atEnd: Bool) {
            defer { removed = []; added = [] }
            guard !removed.isEmpty, !added.isEmpty, removed.count <= 3 else { return }
            // At the end, the field goes on past Verb's words: keep only as many new words as were replaced, plus one.
            let written = atEnd ? Array(added.prefix(removed.count + 1)) : added
            guard written.count <= 3 else { return }
            let heardText = removed.joined(separator: " "), writtenText = written.joined(separator: " ")
            if similar(heardText, writtenText) { changes.append(Change(heard: heardText, written: writtenText)); return }
            // "cloud" retyped as "Claude", with the field's next word after it.
            if atEnd, written.count > removed.count {
                let trimmed = written.prefix(removed.count).joined(separator: " ")
                if similar(heardText, trimmed) { changes.append(Change(heard: heardText, written: trimmed)) }
            }
        }
        while i < old.count && j < new.count {
            if old[i] == new[j] { flush(atEnd: false); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { removed.append(old[i]); i += 1 }
            else { added.append(new[j]); j += 1 }
        }
        removed += old[i...]
        if !removed.isEmpty { added += new[j...] }
        flush(atEnd: true)
        return changes
    }

    /// Whether the change is worth a dictionary entry, and which kind. A grammar fix between
    /// two common words ("va" into "vado") isn't; a name is, though it is also a word ("Cloud"
    /// retyped as "Claude"). `isName` says whether a word is a name where it stands.
    public static func suggestion(for change: Change, isOrdinary: (String) -> Bool, isName: (String) -> Bool = { _ in false }) -> Suggestion? {
        guard change.written.contains(where: \.isLetter), change.written.count >= 2, change.heard != change.written else { return nil }
        let heardOrdinary = isOrdinary(change.heard.lowercased()), writtenOrdinary = isOrdinary(change.written.lowercased())
        // Several words together ("cloud code") are rare enough to replace wherever they come.
        let phrase = change.heard.split(separator: " ").count > 1
        if change.heard.lowercased() == change.written.lowercased() {
            // Only a capital: "iphone" into "iPhone", "verb" into "Verb".
            guard change.written.contains(where: \.isUppercase) else { return nil }
            return heardOrdinary && !phrase ? .spelling(change.written) : .replace(heard: change.heard, word: change.written)
        }
        let named = change.written.split(separator: " ").contains { isName(String($0)) }
        if heardOrdinary && writtenOrdinary && !named && !phrase { return nil }
        return heardOrdinary && !phrase ? .spelling(change.written) : .replace(heard: change.heard, word: change.written)
    }

    static func tokens(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "-" || $0 == "_") }.map(String.init)
    }
    /// Close enough to be the same word retyped: at most half the letters differ.
    static func similar(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        guard x != y else { return true }
        return Double(distance(x, y)) / Double(max(x.count, y.count)) <= 0.5
    }
    /// The number of letters to change, add or remove to turn one word into the other.
    public static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var previous = Array(0...y.count), current = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count { current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}

/// The names and terms already written in the field you dictate into: a colleague's name in
/// the email, a project's name, a class in the code. The speech engine hears them as hints,
/// and a spelling it misses is put back.
public enum FieldTerms {
    /// Capitalised words inside sentences, identifiers (camelCase, snake_case), acronyms and
    /// words with digits, the most frequent and the nearest to the cursor first.
    public static func extract(from text: String, isOrdinary: (String) -> Bool, limit: Int = 40) -> [String] {
        var scores: [String: Double] = [:], openers: [String: Double] = [:]
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?…\n"))
        var position = 0.0
        let total = Double(max(text.count, 1))
        for sentence in sentences {
            let tokens = sentence.split { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "'" || $0 == "’") }.map(String.init)
            for (index, raw) in tokens.enumerated() {
                let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-_'’"))
                position += Double(raw.count + 1)
                guard token.count >= 2, token.contains(where: \.isLetter) else { continue }
                let letters = token.filter(\.isLetter)
                let camel = letters.dropFirst().contains(where: \.isUppercase) && letters.contains(where: \.isLowercase)
                let snake = token.contains("_")
                let digits = token.contains(where: \.isNumber) && token.contains(where: \.isLetter)
                let acronym = letters.count >= 2 && letters.count <= 6 && letters.allSatisfy(\.isUppercase)
                let capitalised = token.first!.isUppercase && token.count >= 3 && !isOrdinary(token.lowercased())
                // Nearer the cursor, at the end of the text, counts a little more.
                let score = 1 + min(position, total) / total
                if camel || snake || digits || acronym || (capitalised && index > 0) { scores[token, default: 0] += score }
                // A capital that opens a sentence proves nothing on its own; it counts for a name found elsewhere.
                else if capitalised { openers[token, default: 0] += score }
            }
        }
        for (token, score) in openers where scores[token] != nil { scores[token, default: 0] += score }
        return scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// Puts back a term the engine misspelled: "Tomaso" becomes "Tommaso" when the field has
    /// "Tommaso". Only words that aren't common words or known names change ("Paolo" stays
    /// though the field has "Paola"), only to one clear match, and never to other digits:
    /// "IPv4" is not a misspelling of "IPv6". `isOrdinary` is asked with the word's own casing.
    public static func correct(_ text: String, terms: [String], isOrdinary: (String) -> Bool) -> String {
        guard !terms.isEmpty else { return text }
        let known = Set(terms)
        var result = text
        let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_]{4,}"#)
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: match.range)
            guard !known.contains(word), !isOrdinary(word), !isOrdinary(word.lowercased()) else { continue }
            let limit = word.count <= 6 ? 0.25 : 0.34
            let digits = word.filter(\.isNumber)
            let scored = terms.compactMap { term -> (String, Double)? in
                guard term.count >= 4, term.first?.lowercased() == word.first?.lowercased(), term.filter(\.isNumber) == digits else { return nil }
                let score = Double(CorrectionLearner.distance(word.lowercased(), term.lowercased())) / Double(max(word.count, term.count))
                return score <= limit ? (term, score) : nil
            }.sorted { $0.1 < $1.1 }
            guard let best = scored.first, scored.count == 1 || scored[1].1 > best.1 else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: best.0)
        }
        return result
    }
}
