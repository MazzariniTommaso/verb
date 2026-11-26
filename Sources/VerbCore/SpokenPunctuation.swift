import Foundation

/// Punctuation and addresses said as words: “Ciao Marco virgola ci vediamo”, “are you free
/// question mark”, “mario punto rossi chiocciola gmail punto com”. The speech engines punctuate
/// by themselves, so a name counts as a mark only where nothing else could be meant. After an
/// article or a preposition it stays a word (“il punto è”, “manca una virgola”, “alle tre in
/// punto”, “add a comma”), and “punto” or “period”, which are mostly ordinary words, count only
/// where a sentence ends: at the end of what was said, on their own between two sentences, or
/// before a line command.
public enum SpokenPunctuation {
    struct Command {
        let phrase: String, mark: String
        /// Mostly an ordinary word: it counts only where a sentence ends.
        var restricted = false
    }
    static let italian: [Command] = [
        Command(phrase: "punto e a capo", mark: ".\n"), Command(phrase: "punto a capo", mark: ".\n"),
        Command(phrase: "punto e virgola", mark: ";"), Command(phrase: "punto interrogativo", mark: "?"),
        Command(phrase: "punto di domanda", mark: "?"), Command(phrase: "punto esclamativo", mark: "!"),
        Command(phrase: "virgola", mark: ","), Command(phrase: "punto", mark: ".", restricted: true),
    ]
    static let english: [Command] = [
        Command(phrase: "question mark", mark: "?"), Command(phrase: "exclamation mark", mark: "!"),
        Command(phrase: "exclamation point", mark: "!"), Command(phrase: "semicolon", mark: ";"),
        Command(phrase: "semi colon", mark: ";"), Command(phrase: "full stop", mark: "."),
        Command(phrase: "comma", mark: ","), Command(phrase: "period", mark: ".", restricted: true),
    ]
    /// Words before a mark's name that make it the thing itself: “una virgola”, “the comma”, “in punto”.
    static let wordsBefore: Set<String> = [
        "il", "lo", "la", "l", "i", "gli", "le", "un", "uno", "una", "del", "dello", "della", "dell", "dei", "degli", "delle", "al", "allo", "alla", "all", "ai", "agli", "alle",
        "dall", "nell", "sull", "quell",
        "dal", "dallo", "dalla", "nel", "nello", "nella", "sul", "sullo", "sulla", "quel", "quello", "quella", "questo", "questa", "ogni", "che", "in", "di", "da", "per",
        "come", "su", "tra", "fra", "ultimo", "ultima", "primo", "prima", "secondo", "terzo", "nessun", "nessuna", "qualche", "ciascun", "a",
        "an", "the", "this", "that", "these", "those", "each", "every", "any", "my", "your", "our", "their", "his", "her", "its", "no", "one",
        "oxford", "serial", "inverted", "same", "first", "last", "next", "previous",
    ]
    /// Words that make “period” a stretch of time: “the trial period”.
    static let periodWords: Set<String> = [
        "trial", "grace", "waiting", "cooling", "notice", "time", "study", "transition", "probation", "billing", "reporting", "rest", "free", "school", "lunch",
        "class", "sample", "holiday", "vacation", "warranty", "payment", "contract", "introductory", "initial", "final", "short", "long", "whole", "entire",
        "given", "certain", "fiscal", "financial", "reference", "review", "recovery", "adjustment", "honeymoon", "incubation", "settlement", "testing",
        "evaluation", "assessment", "election", "campaign",
    ]
    /// Words after “punto” or “period” that make it a noun: “punto di vista”, “punto e basta”, “period of”.
    static let nounWordsAfter: Set<String> = ["di", "e", "per", "in", "a", "da", "che", "su", "sul", "sulla", "del", "della", "vendita", "fermo",
                                              "of", "for", "when", "during", "where", "after", "before", "between"]

    /// The text with marks and addresses said as words written as such. `language` is the
    /// dictation's: Italian names apply to Italian, English ones to English. With the language
    /// unknown, only the names no other language uses for anything else.
    public static func apply(_ text: String, language: String?) -> String {
        let base = TextRules.baseLanguage(language)
        var commands: [Command] = []
        if base == "it" || base == nil { commands += italian }
        if base == "en" || base == nil { commands += english }
        if base == nil { commands.removeAll { ["comma", "period", "punto"].contains($0.phrase) } }
        let text = addresses(text, language: base)
        guard !commands.isEmpty else { return text }
        let sorted = commands.sorted { $0.phrase.count > $1.phrase.count }
        let names = sorted.map { NSRegularExpression.escapedPattern(for: $0.phrase).replacingOccurrences(of: " ", with: #"\s+"#) }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}_'’])("# + names + #")(?![\p{L}\p{N}_])"#) else { return text }
        let ns = text as NSString
        let result = NSMutableString(string: text)
        // Matches are handled from the end, so everything before `limit` is still as it was.
        var limit = ns.length, changed = false
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard NSMaxRange(match.range) <= limit else { continue }
            let said = ns.substring(with: match.range).lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard let command = sorted.first(where: { $0.phrase == said }) else { continue }
            let before = ns.substring(to: match.range.location), after = ns.substring(with: NSRange(location: NSMaxRange(match.range), length: limit - NSMaxRange(match.range)))
            let previous = neighbour(before, last: true), next = neighbour(after, last: false)
            if let previous, wordsBefore.contains(previous) { continue }
            if command.phrase == "period", let previous, periodWords.contains(previous) { continue }
            // “3 virgola 5” is a decimal number.
            if command.phrase == "virgola", let digitsBefore = before.range(of: #"\p{N}[ \t]*$"#, options: .regularExpression),
               after.range(of: #"^[ \t]*\p{N}"#, options: .regularExpression) != nil {
                let start = (before as NSString).length - before[digitsBefore].utf16.count + 1
                var end = NSMaxRange(match.range)
                while end < limit, isBlank(ns.character(at: end)) { end += 1 }
                result.replaceCharacters(in: NSRange(location: start, length: end - start), with: ",")
                limit = start; changed = true
                continue
            }
            if command.restricted {
                if let next, nounWordsAfter.contains(next) { continue }
                guard endsSentence(after: after, setOffBefore: previous == nil) else { continue }
            }
            // Spaces before go, and a mark the engine guessed there gives way to the one you said,
            // except a question or exclamation mark before a plain full stop.
            var start = match.range.location, end = NSMaxRange(match.range)
            while start > 0, isBlank(ns.character(at: start - 1)) { start -= 1 }
            var keepEngineMark = false
            if start > 0, let mark = character(ns, at: start - 1), ".,;:!?".contains(mark) {
                if command.mark == ".", "?!".contains(mark) { keepEngineMark = true } else { start -= 1 }
            }
            // The mark the engine put right after the name goes too, and so do the spaces.
            if end < limit, let mark = character(ns, at: end), ".,;:!?".contains(mark) { end += 1 }
            while end < limit, isBlank(ns.character(at: end)) { end += 1 }
            let goesOn = end < ns.length && character(ns, at: end)?.isNewline == false
            var replacement = keepEngineMark ? "" : command.mark
            if goesOn, !replacement.hasSuffix("\n") { replacement += " " }
            result.replaceCharacters(in: NSRange(location: start, length: end - start), with: replacement)
            if keepEngineMark || ".?!".contains(command.mark.first!) { TextRules.capitalise(result, at: start + (replacement as NSString).length) }
            limit = start; changed = true
        }
        guard changed else { return text }
        var clean = result as String
        clean = clean.replacingOccurrences(of: #"[ \t]+([,;:!?]|\.(?![\p{L}\p{N}]))"#, with: "$1", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return clean.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a full stop said as a word ends a sentence there: nothing but marks follows, or a
    /// line command, or the engine's own sentence end and a capital, or a capital after a pause.
    private static func endsSentence(after: String, setOffBefore: Bool) -> Bool {
        let rest = after.drop { $0 == " " || $0 == "\t" }
        if rest.allSatisfy({ $0.isWhitespace || ".,;:!?…".contains($0) }) { return true }
        let markedEnd = rest.first.map { ".!?".contains($0) } == true
        let following = rest.first.map { ".!?,;:".contains($0) } == true ? rest.dropFirst().drop { $0 == " " || $0 == "\t" } : rest
        if following.first?.isNewline == true { return true }
        if String(following).range(of: #"^(?i)(a\s+capo|new\s+line|nuovo\s+paragrafo|new\s+paragraph)(?![\p{L}\p{N}])"#, options: .regularExpression) != nil { return true }
        return (markedEnd || setOffBefore) && following.first?.isUppercase == true
    }

    /// Addresses said as words: “mario punto rossi chiocciola gmail punto com” is
    /// mario.rossi@gmail.com, “google dot com” is google.com. An English address needs its dots
    /// spelled out, and a plain word before “at” is no mailbox: “look at google dot com”.
    static func addresses(_ text: String, language base: String?) -> String {
        var text = text
        if base == "it" || base == nil {
            text = rewrite(text, email(at: "chiocciola", dot: "punto"), dot: "punto")
            text = rewrite(text, site(dot: "punto"), dot: "punto")
        }
        if base == "en" || base == nil {
            text = rewrite(text, email(at: "at", dot: "dot"), dot: "dot", plainWords: notMailboxes)
            text = rewrite(text, site(dot: "dot"), dot: "dot")
        }
        return text
    }
    private static let domainEnds = "com|it|org|net|eu|io|dev|app|info|ch|uk|de|fr|es|co"
    private static func email(at: String, dot: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}_.@-])((?:[\p{L}\p{N}_+-]+\s+"# + dot + #"\s+)*[\p{L}\p{N}._+-]+)\s+"# + at
                                 + #"\s+((?:[\p{L}\p{N}-]+\s+"# + dot + #"\s+)+(?:"# + domainEnds + #")|[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)+)(?![\p{L}\p{N}_])"#)
    }
    private static func site(dot: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}_.@/-])([\p{L}\p{N}-]+(?:\s+"# + dot + #"\s+[\p{L}\p{N}-]+)*\s+"# + dot + #"\s+(?:"# + domainEnds + #"))(?![\p{L}\p{N}_])"#)
    }
    /// Words that come before “at” in a sentence, not before an address.
    static let notMailboxes: Set<String> = ["look", "looking", "looked", "see", "check", "go", "come", "visit", "find", "it", "me", "us", "them", "you", "him", "her",
                                            "this", "that", "here", "there", "back", "home", "work", "school", "meet", "met", "stay", "arrive", "arrived", "is", "are",
                                            "was", "were", "be", "and", "or", "but", "then", "all", "one", "everyone", "someone", "anyone", "people", "team", "available", "online"]
    private static func rewrite(_ text: String, _ regex: NSRegularExpression, dot: String, plainWords: Set<String> = []) -> String {
        let ns = text as NSString
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let whole = ns.substring(with: match.range)
            let first = whole.prefix { $0.isLetter || $0.isNumber }.lowercased()
            if wordsBefore.contains(first) { continue }
            // A one-word mailbox that is an ordinary word is part of the sentence.
            if match.numberOfRanges > 2, !plainWords.isEmpty {
                let mailbox = ns.substring(with: match.range(at: 1))
                if !mailbox.contains(where: { $0 == "." || $0.isWhitespace }), plainWords.contains(mailbox.lowercased()) { continue }
            }
            let spaced = #"\s+"# + dot + #"\s+"#
            var address: String
            if match.numberOfRanges > 2 {
                let mailbox = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: spaced, with: ".", options: [.regularExpression, .caseInsensitive])
                let domain = ns.substring(with: match.range(at: 2)).replacingOccurrences(of: spaced, with: ".", options: [.regularExpression, .caseInsensitive])
                address = mailbox + "@" + domain
            } else {
                address = whole.replacingOccurrences(of: spaced, with: ".", options: [.regularExpression, .caseInsensitive])
            }
            address = address.lowercased()
            result.replaceCharacters(in: match.range, with: address)
        }
        return result as String
    }

    private static func isBlank(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }
    private static func character(_ text: NSString, at index: Int) -> Character? {
        guard index >= 0, index < text.length else { return nil }
        return Character(text.substring(with: text.rangeOfComposedCharacterSequence(at: index)))
    }
    /// The word right next to a name, lowercased, when only spaces separate them: with a mark in
    /// between, the name stands on its own.
    private static func neighbour(_ text: String, last: Bool) -> String? {
        let side = last ? String(text.reversed()) : text
        let gap = side.prefix { $0 == " " || $0 == "\t" }
        let word = side.dropFirst(gap.count).prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
        guard !gap.isEmpty, !word.isEmpty else { return nil }
        let found = (last ? String(word.reversed()) : String(word)).lowercased()
        // “dell’” and “l’” count as the article they are.
        return found.split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? found
    }
}
