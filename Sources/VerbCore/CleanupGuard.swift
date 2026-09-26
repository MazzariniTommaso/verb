import Foundation

/// Checks a writing model's clean-up against the words that were said, before it replaces
/// them. A clean-up may drop fillers and repeats, and settle a correction the speaker made
/// out loud; it may not change a number, a date, a name or a "not", turn a statement into a
/// question, or answer the dictation instead of tidying it. When it does, Verb keeps the words
/// as they were said.
public enum CleanupGuard {
    public enum Finding: Equatable, Sendable {
        /// It reads as a reply to the dictation, not as the dictation.
        case answered
        /// A number that wasn't said, or one that was said and is gone.
        case number
        /// A "not" added or lost.
        case negation
        /// A statement turned into a question, or a question into a statement.
        case question
        /// A name, a date or a dictionary word that is gone or changed.
        case name(String)

        /// Why the words were kept, for History.
        public var message: String {
            switch self {
            case .answered: return "Kept your words: the writing model answered the dictation instead of tidying it."
            case .number: return "Kept your words: the writing model changed a number."
            case .negation: return "Kept your words: the writing model added or dropped a negation."
            case .question: return "Kept your words: the writing model changed a question."
            case .name(let word): return "Kept your words: the writing model changed “\(word)”."
            }
        }
    }

    /// What is wrong with `cleaned`, or nil when it keeps the meaning of `said`. `vocabulary`
    /// holds the dictionary's spellings, which must survive like names; `names` the names found
    /// in `said` from the words around them, which count wherever they stand, even where a
    /// capital proves nothing, at the start of a sentence.
    public static func check(said: String, cleaned: String, vocabulary: [String] = [], names known: Set<String> = []) -> Finding? {
        let said = withoutPlaceholders(said), cleaned = withoutPlaceholders(cleaned)
        // What a spoken correction takes back may go; every other number, "not", date and name stays.
        let firm = withoutCorrections(said)
        if answered(said: said, cleaned: cleaned, firm: firm) { return .answered }
        // A new number never appears, though "sei" may become 6. A list's "1." counts as kept, never as new.
        let cleanedNumbers = numbers(in: cleaned)
        if !cleanedNumbers.isSubset(of: numbers(in: said, loose: true)) || !numbers(in: firm).isSubset(of: cleanedNumbers.adding(listMarkers(in: cleaned))) { return .number }
        let cleanedNot = negations(in: cleaned)
        if cleanedNot > negations(in: said) || cleanedNot < negations(in: firm) { return .negation }
        // Days and months: a new one is never right.
        let cleanedDates = calendarWords(in: cleaned)
        if let added = cleanedDates.subtracting(calendarWords(in: said)).sorted().first { return .name(added) }
        if let lost = calendarWords(in: firm).subtracting(cleanedDates).sorted().first { return .name(lost) }
        let kept = Set(words(in: cleaned))
        for name in names(in: firm, vocabulary: vocabulary, known: known) where !contains(name, words: kept, text: cleaned) { return .name(name) }
        let saidAsks = said.contains("?"), cleanedAsks = cleaned.contains("?")
        if saidAsks && !cleanedAsks { return .question }
        if !saidAsks && cleanedAsks && !asksSomething(said) { return .question }
        return nil
    }

    // MARK: Words

    private static let placeholder = try! NSRegularExpression(pattern: #"\[VERB_SNIPPET_[^\]]*\]"#)
    static func withoutPlaceholders(_ text: String) -> String {
        placeholder.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }
    /// Lowercased words without accents, for comparing: "Perché" and "perche" are one word.
    static func words(in text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// Spoken corrections, after which a word or a number may rightly go.
    static let correctionCues = ["anzi", "no scusa", "scusa no", "cioe no", "volevo dire", "no aspetta", "anzi no", "correggo", "no volevo", "o meglio", "o per meglio dire",
                                 "actually", "i mean", "i meant", "no wait", "scratch that", "sorry i meant", "let me rephrase", "or rather"]
    /// Cues that open a sentence as often to go on as to correct: "Actually, I don't think…".
    static let discourseCues: Set<String> = ["actually", "i mean"]
    /// The text without what its spoken corrections take back: the words before a cue in its
    /// sentence ("martedì, anzi mercoledì"), or the sentence before one that opens with it
    /// ("Alle cinque. Anzi, alle sei."). What follows a cue is the speaker's final choice and
    /// stays, and so does every sentence without one. "Actually" and "I mean" that open a
    /// sentence take nothing back. Without punctuation, the whole text is one sentence.
    static func withoutCorrections(_ text: String) -> String {
        let ns = text as NSString
        var sentences: [NSRange] = [], start = 0
        for end in sentenceEnd.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            sentences.append(NSRange(location: start, length: NSMaxRange(end.range) - start)); start = NSMaxRange(end.range)
        }
        if start < ns.length { sentences.append(NSRange(location: start, length: ns.length - start)) }
        var spans: [NSRange] = []
        for cue in cues(in: text) {
            guard let index = sentences.firstIndex(where: { NSLocationInRange(cue.location, $0) }) else { continue }
            let opens = !ns.substring(with: NSRange(location: sentences[index].location, length: cue.location - sentences[index].location)).contains { $0.isLetter || $0.isNumber }
            let back = index > 0 && !discourseCues.contains(words(in: ns.substring(with: cue)).joined(separator: " "))
            let from = !opens ? sentences[index].location : back ? sentences[index - 1].location : cue.location
            spans.append(NSRange(location: from, length: NSMaxRange(cue) - from))
        }
        var merged: [NSRange] = []
        for span in spans.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, span.location <= NSMaxRange(last) { merged[merged.count - 1] = NSUnionRange(last, span) } else { merged.append(span) }
        }
        // Each span becomes a full stop, so what is left never joins across it.
        let result = NSMutableString(string: text)
        for span in merged.reversed() { result.replaceCharacters(in: span, with: ".") }
        return result as String
    }
    /// Where a sentence ends: a closing mark before a space, or a line break.
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[.!?…]+["”’»)\]]*(?=\s|$)|\n"#)
    /// Where the correction cues are, as ranges of the text.
    static func cues(in text: String) -> [NSRange] {
        let ns = text as NSString
        let tokens = wordPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { (words(in: ns.substring(with: $0.range)).joined(), $0.range) }
        var found: [NSRange] = []
        for cue in correctionCues.map({ $0.split(separator: " ").map(String.init) }) {
            for start in tokens.indices where start + cue.count <= tokens.count && tokens[start..<(start + cue.count)].map(\.0) == cue {
                found.append(NSUnionRange(tokens[start].1, tokens[start + cue.count - 1].1))
            }
        }
        // "Per quattro persone, no, per cinque."
        found += noCorrection.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range(at: 1) }
        return found
    }
    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+"#)
    private static let noCorrection = try! NSRegularExpression(pattern: #"(?i),\s*(no)\s*[,.;]"#)

    // MARK: Answers

    /// How assistants open a reply, which a dictation almost never does.
    static let replyOpenings = ["certo", "certamente", "ecco", "sure", "of course", "certainly", "here is", "here s", "heres", "mi dispiace", "sorry i", "i can t", "i cannot",
                                "non posso", "come assistente", "as an ai", "posso aiutarti", "happy to help", "ottima domanda", "great question", "absolutely", "assolutamente"]
    /// Words a speaker opens with, which a clean-up may drop: "So,", "Allora,".
    static let openers: Set<String> = ["so", "well", "now", "and", "but", "ok", "okay", "oh", "allora", "quindi", "ecco", "dunque", "beh", "bene", "insomma", "senti", "ora", "e", "ma"]
    /// Whether `cleaned` reads as a reply. `firm` is `said` without what its corrections take
    /// back, which a clean-up rightly leaves out: "Porto il vino, no scusa, porto la birra" is
    /// "Porto la birra".
    static func answered(said: String, cleaned: String, firm: String? = nil) -> Bool {
        let saidWords = words(in: said), cleanedWords = words(in: cleaned)
        let cleanedStart = cleanedWords.prefix(4).joined(separator: " ") + " "
        // The dictation may open the same way once its "So," or "Allora," is gone.
        let lead = saidWords.prefix { openers.contains($0) }.count
        let saidStarts = (0...lead).map { saidWords.dropFirst($0).prefix(4).joined(separator: " ") + " " }
        if replyOpenings.contains(where: { opening in cleanedStart.hasPrefix(opening + " ") && !saidStarts.contains { $0.hasPrefix(opening + " ") } }) { return true }
        if cleaned.contains("```") && !said.contains("```") { return true }
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") && !said.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") { return true }
        // A short dictation grows by a few words at most: a poem for "Write a haiku about cats" is an answer.
        guard saidWords.count >= 8 else { return cleanedWords.count > saidWords.count * 2 + 3 }
        // A tidy-up keeps most of the words that must stay, and adds few of its own.
        let firmCount = firm.map { words(in: $0).count } ?? saidWords.count
        if Double(cleanedWords.count) < 0.45 * Double(firmCount) || Double(cleanedWords.count) > 1.8 * Double(saidWords.count) { return true }
        let saidContent = Set(saidWords.filter { $0.count >= 4 })
        let cleanedContent = cleanedWords.filter { $0.count >= 4 }
        guard cleanedContent.count >= 5 else { return false }
        let own = Double(cleanedContent.filter { saidContent.contains($0) }.count) / Double(cleanedContent.count)
        return own < 0.55
    }

    // MARK: Numbers

    /// Every number in the text, written in digits or in Italian or English words, counted:
    /// "15", "quindici" and "fifteen" are all 15, and digits count inside a word too ("10am",
    /// "3rd", "100mg"). Words that are also articles or verbs ("una", "one", "sei") count only
    /// inside a longer number; `loose` counts them alone too, with the ordinals, for the digits
    /// a clean-up may rightly write for them ("tra sei mesi" as "tra 6 mesi", "third" as "3rd").
    static func numbers(in text: String, loose: Bool = false) -> Multiset {
        var source = text
        // "2.000" and "1,000,000" are one number each.
        if let regex = try? NSRegularExpression(pattern: #"(?<![\d.,])\d{1,3}(?:[.,]\d{3})+(?!\d)"#) {
            let original = source as NSString
            for match in regex.matches(in: source, range: NSRange(location: 0, length: original.length)).reversed() {
                source = (source as NSString).replacingCharacters(in: match.range, with: original.substring(with: match.range).filter(\.isNumber))
            }
        }
        // A numbered list's "1." is layout, and "per cento" is a percentage, not a hundred.
        source = source.replacingOccurrences(of: listMarker.pattern, with: "", options: .regularExpression)
        source = source.replacingOccurrences(of: #"(?i)\bper\s+cento\b"#, with: "percento", options: .regularExpression)
        var values: [Int] = []
        var current = 0, total = 0, count = 0, lastMultiplier = false, lone: Int?
        func close() {
            // A lone "una", "one" or "sei" is an article, a pronoun or a verb.
            if count > 1 || count == 1 && lone == nil { values.append(total + current) } else if loose, let lone { values.append(lone) }
            current = 0; total = 0; count = 0; lastMultiplier = false; lone = nil
        }
        for (token, afterMark) in numberWords(in: source) {
            // Numbers never join across a comma or a full stop: "20. 3 persone" are two.
            if afterMark { close() }
            // "one hundred and five", "duemila e cinquecento".
            if (token == "and" || token == "e") && count > 0 && lastMultiplier { continue }
            let value: Int?, ambiguous: Bool
            if token.allSatisfy(\.isNumber) { value = token.count <= 15 ? Int(token) : nil; ambiguous = false }
            else if let english = englishWords[token] { value = english; ambiguous = token == "one" }
            else if ["un", "uno", "una"].contains(token) { value = 1; ambiguous = true }
            else if token == "sei" { value = 6; ambiguous = true }
            else { value = italianNumber(token); ambiguous = false }
            guard let value else {
                close()
                if loose, let ordinal = ordinals[token] { values.append(ordinal) }
                continue
            }
            let multiplier = [100, 1000, 1_000_000, 1_000_000_000].contains(value)
            if count > 0 {
                // Numbers said one after another stay apart ("tre, quattro"); a unit after a ten
                // ("twenty three") or anything around a multiplier joins the number.
                let joins = multiplier || lastMultiplier || (current % 100 >= 20 && current % 10 == 0 && value < 10)
                if !joins { close() }
            }
            // A number too big to hold ("cento cento cento…") starts again.
            if let joined = combine(total, current, value, multiplier: multiplier) { (total, current) = joined }
            else { close(); (total, current) = combine(0, 0, value, multiplier: multiplier) ?? (0, value) }
            count += 1; lastMultiplier = multiplier
            lone = count == 1 && ambiguous ? value : nil
        }
        close()
        return Multiset(values)
    }

    /// The numbers of a numbered list's items: the "1." and "2)" that open its lines.
    static func listMarkers(in text: String) -> Multiset {
        let ns = text as NSString
        return Multiset(listMarker.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { Int(ns.substring(with: $0.range(at: 1))) })
    }
    private static let listMarker = try! NSRegularExpression(pattern: #"(?m)^\s*(\d+)[.)]\s"#)

    /// The words of the text for reading numbers, folded like `words(in:)`, with digits apart
    /// from the letters around them, each marked when a comma, a full stop or a slash comes
    /// before it.
    static func numberWords(in text: String) -> [(word: String, afterMark: Bool)] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var result: [(word: String, afterMark: Bool)] = [], word = "", mark = false
        func flush() { if !word.isEmpty { result.append((word, mark)); word = ""; mark = false } }
        for character in folded {
            if character.isLetter || character.isNumber {
                if let last = word.last, last.isNumber != character.isNumber { flush() }
                word.append(character)
            } else {
                flush()
                if character.isNewline || ".,;:!?…/".contains(character) { mark = true }
            }
        }
        flush()
        return result
    }

    /// A number with one more part said after it ("cento" after "tre"), or nil when the result
    /// is too big to hold.
    static func combine(_ total: Int, _ current: Int, _ value: Int, multiplier: Bool) -> (Int, Int)? {
        var total = total, current = current, overflow = false
        if value == 100 { (current, overflow) = max(current, 1).multipliedReportingOverflow(by: 100) }
        else if multiplier {
            let (product, tooBig) = max(current, 1).multipliedReportingOverflow(by: value)
            (total, overflow) = total.addingReportingOverflow(product); overflow = overflow || tooBig; current = 0
        } else { (current, overflow) = current.addingReportingOverflow(value) }
        guard !overflow, !total.addingReportingOverflow(current).overflow else { return nil }
        return (total, current)
    }

    /// Ordinals, which a clean-up may write in digits: "third" as "3rd", "terzo" as "3°".
    static let ordinals: [String: Int] = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
                                          "primo": 1, "prima": 1, "secondo": 2, "seconda": 2, "terzo": 3, "terza": 3, "quarto": 4, "quarta": 4, "quinto": 5, "quinta": 5,
                                          "sesto": 6, "sesta": 6, "settimo": 7, "settima": 7, "ottavo": 8, "ottava": 8, "nono": 9, "nona": 9, "decimo": 10, "decima": 10]

    static let englishWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100, "thousand": 1000, "million": 1_000_000, "millions": 1_000_000, "billion": 1_000_000_000,
    ]
    /// Italian writes a number as one word: "ventitré", "centottanta", "duemilaventisei".
    private static let italianParts: [(String, Int)] = [
        ("diciassette", 17), ("diciannove", 19), ("quattordici", 14), ("cinquanta", 50), ("diciotto", 18), ("quaranta", 40), ("sessanta", 60), ("settanta", 70),
        ("quindici", 15), ("cinquant", 50), ("quarant", 40), ("sessant", 60), ("settant", 70), ("miliardi", 1_000_000_000), ("miliardo", 1_000_000_000),
        ("quattro", 4), ("tredici", 13), ("ottanta", 80), ("novanta", 90), ("milioni", 1_000_000), ("milione", 1_000_000), ("cinque", 5), ("undici", 11),
        ("dodici", 12), ("sedici", 16), ("trenta", 30), ("ottant", 80), ("novant", 90), ("dieci", 10), ("venti", 20), ("trent", 30), ("cento", 100), ("mille", 1000),
        ("sette", 7), ("vent", 20), ("cent", 100), ("mila", 1000), ("zero", 0), ("otto", 8), ("nove", 9), ("uno", 1), ("una", 1), ("due", 2), ("tre", 3), ("sei", 6),
    ]
    static func italianNumber(_ word: String) -> Int? {
        guard word.count >= 3, word.allSatisfy(\.isLetter) else { return nil }
        func parse(_ rest: Substring) -> [Int]? {
            if rest.isEmpty { return [] }
            for (part, value) in italianParts where rest.hasPrefix(part) {
                if let tail = parse(rest.dropFirst(part.count)) { return [value] + tail }
            }
            return nil
        }
        guard let parts = parse(Substring(word)), !parts.isEmpty else { return nil }
        // One word is one number: fold its parts together ("ventitre" is 23, not 20 and 3).
        var total = 0, current = 0
        for value in parts {
            guard let joined = combine(total, current, value, multiplier: value >= 1000) else { return nil }
            (total, current) = joined
        }
        return total + current
    }

    // MARK: Negations, dates, names, questions

    static let negationWords: Set<String> = ["non", "né", "mai", "nessuno", "nessuna", "nessun", "niente", "nulla", "senza", "nemmeno", "neanche", "neppure", "mica",
                                             "no", "not", "never", "nothing", "nobody", "none", "without", "neither", "nor", "cannot"]
    static func negations(in text: String) -> Int {
        let lower = text.lowercased()
        let tokens = lower.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        var count = 0
        for (index, token) in tokens.enumerated() where negationWords.contains(token) {
            // "non non" is a stumble: one negation.
            if index > 0 && tokens[index - 1] == token { continue }
            count += 1
        }
        // "don't", "can't", "isn't".
        count += contraction.numberOfMatches(in: lower, range: NSRange(lower.startIndex..., in: lower))
        return count
    }
    private static let contraction = try! NSRegularExpression(pattern: #"[a-z]n['’]t\b"#)

    static let calendarNames: Set<String> = ["lunedi", "martedi", "mercoledi", "giovedi", "venerdi", "sabato", "domenica",
                                             "gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre",
                                             "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                                             "january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december"]
    static func calendarWords(in text: String) -> Set<String> { Set(words(in: text).filter { calendarNames.contains($0) }) }

    /// Names as the engine wrote them: capitalised words inside a sentence ("Atlas", "Claude"),
    /// acronyms, the dictionary's own spellings, and the `known` names wherever they stand.
    /// "I'm" and "OK" are none of these, though they have capitals.
    static func names(in text: String, vocabulary: [String], known: Set<String> = []) -> [String] {
        var found: [String] = []
        let knownKeys = Set(known.map { words(in: $0).joined(separator: " ") })
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?…:\n"))
        for sentence in sentences {
            let tokens = sentence.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }.map(String.init)
            for (index, token) in tokens.enumerated() {
                let letters = token.filter(\.isLetter)
                guard letters.count >= 2, let first = letters.first, first.isUppercase, !notNames.contains(token.replacingOccurrences(of: "’", with: "'")) else { continue }
                if index > 0 || knownKeys.contains(words(in: token).joined(separator: " ")) { found.append(token) }
            }
        }
        let canonical = " " + words(in: text).joined(separator: " ") + " "
        for word in vocabulary where !word.isEmpty {
            let folded = words(in: word).joined(separator: " ")
            if !folded.isEmpty, canonical.contains(" " + folded + " ") { found.append(word) }
        }
        var seen = Set<String>()
        return found.filter { seen.insert(words(in: $0).joined(separator: " ")).inserted }
    }
    /// Capitalised words that are not names.
    static let notNames: Set<String> = ["I'm", "I've", "I'll", "I'd", "OK", "Ok"]
    static func contains(_ name: String, words: Set<String>, text: String) -> Bool {
        let parts = CleanupGuard.words(in: name)
        guard parts.count > 1 else { return parts.first.map(words.contains) ?? true }
        return (" " + CleanupGuard.words(in: text).joined(separator: " ") + " ").contains(" " + parts.joined(separator: " ") + " ")
    }

    /// Words that open a question: a question word or an auxiliary.
    static let questionWords: Set<String> = ["come", "cosa", "perche", "quando", "dove", "chi", "quale", "quali", "quanto", "quanta", "quanti", "quante", "puoi", "potresti", "sai",
                                             "posso", "possiamo", "puo", "potete", "vuoi", "volete", "hai", "avete",
                                             "what", "why", "how", "when", "where", "who", "which", "whose", "can", "could", "would", "should", "do", "does", "did", "is", "are", "am",
                                             "was", "were", "will", "shall", "may", "might", "have", "has"]
    /// Words that end a statement to ask about it: "è pronto, vero", "it's done, right".
    static let questionTags: Set<String> = ["vero", "giusto", "no", "eh", "ok", "okay", "right"]
    /// The English tag after a comma: "isn't it", "don't you", "is it".
    private static let tag = try! NSRegularExpression(pattern: #"(?i),\s*(?:is|are|am|was|were|do|does|did|have|has|can|could|will|would|should|won|ain)(?:n['’]t)?\s+(?:it|you|they|we|he|she|i|there)\s*$"#)
    /// Whether the text has the shape of a question, though it has no question mark: a sentence
    /// or a clause that opens with a question word or an auxiliary ("Marco, can you send it"),
    /// or a sentence that ends with a tag ("è pronto, vero", "it's done, isn't it"). A word like
    /// "is" or "quando" inside a statement doesn't make it one.
    static func asksSomething(_ text: String) -> Bool {
        for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?…\n")) {
            guard let last = words(in: sentence).last else { continue }
            if questionTags.contains(last) || tag.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) != nil { return true }
            for clause in sentence.components(separatedBy: CharacterSet(charactersIn: ",;:")) {
                if let first = words(in: clause).first(where: { !openers.contains($0) }), questionWords.contains(first) { return true }
            }
        }
        return false
    }

    /// Values with how many times each appears.
    public struct Multiset: Equatable, Sendable {
        var counts: [Int: Int] = [:]
        init(_ values: [Int]) { for value in values { counts[value, default: 0] += 1 } }
        public var isEmpty: Bool { counts.isEmpty }
        func isSubset(of other: Multiset) -> Bool { counts.allSatisfy { other.counts[$0.key, default: 0] >= $0.value } }
        func adding(_ other: Multiset) -> Multiset { var sum = self; for (value, count) in other.counts { sum.counts[value, default: 0] += count }; return sum }
        public var values: [Int] { counts.flatMap { Array(repeating: $0.key, count: $0.value) }.sorted() }
    }
}
