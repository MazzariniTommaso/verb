import Foundation

/// The dictionary's words in a transcript the speech engine spelled its own way, the entries a
/// text needs, and the names that keep coming back in what you dictate. Parakeet takes no hints,
/// so what it misspells is put back here, after it.
public enum VocabularyMatch {
    /// How a word sounds, roughly, in Italian and in English: letters that sound alike become
    /// one, doubled letters single, a silent h goes. "Komposio" and "Composio" sound the same,
    /// as do "Filippo" and "Philippo".
    public static func sound(_ word: String) -> String {
        var text = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).filter(\.isLetter)
        for (from, to) in [("ph", "f"), ("ck", "k"), ("ch", "k"), ("gh", "g"), ("qu", "k"), ("q", "k"), ("c", "k"), ("x", "ks"), ("y", "i"), ("w", "v"), ("z", "s"), ("j", "i"), ("h", "")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        var collapsed = ""
        for letter in text where letter != collapsed.last { collapsed.append(letter) }
        return collapsed
    }

    /// Whether `heard` is the engine's spelling of `word`: the same sound, or a close spelling
    /// that starts the same way. Short words need to be closer.
    static func resembles(_ heard: String, _ word: String) -> Bool {
        let a = heard.lowercased(), b = word.lowercased()
        guard a != b else { return true }
        let soundA = sound(a), soundB = sound(b)
        guard !soundA.isEmpty, !soundB.isEmpty else { return false }
        if soundA == soundB { return true }
        guard soundA.first == soundB.first else { return false }
        let limit = max(a.count, b.count) <= 6 ? 0.2 : 0.3
        return Double(CorrectionLearner.distance(soundA, soundB)) / Double(max(soundA.count, soundB.count)) <= limit
    }

    /// Puts back the dictionary's spelling where the engine wrote a word that sounds like it and
    /// isn't a word of its own: "Komposio" becomes "Composio", "Open AI" becomes "OpenAI". Only
    /// to one clear match, never over a common word, and never to other digits. `isOrdinary` is
    /// asked with the word as written and in small letters. Returns the text and how many words changed.
    public static func correct(_ text: String, words: [String], isOrdinary: (String) -> Bool) -> (text: String, changes: Int) {
        let known = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 4 && !$0.contains(" ") }
        guard !known.isEmpty, !text.isEmpty else { return (text, 0) }
        let exact = Set(known.map { $0.lowercased() })
        let tokens = try! NSRegularExpression(pattern: #"[\p{L}\p{N}][\p{L}\p{N}'’_-]*"#).matches(in: text, range: NSRange(text.startIndex..., in: text))
        let ns = text as NSString
        var replacements: [(NSRange, String)] = []
        var index = 0
        while index < tokens.count {
            let range = tokens[index].range, token = ns.substring(with: range)
            // Two words heard for one: "Open AI", "Git Hub". Only with a space between them.
            if index + 1 < tokens.count {
                let next = tokens[index + 1].range
                let gap = ns.substring(with: NSRange(location: NSMaxRange(range), length: next.location - NSMaxRange(range)))
                if gap == " " {
                    let joined = token + ns.substring(with: next)
                    if let word = known.first(where: { $0.lowercased() == joined.lowercased() }) {
                        replacements.append((NSRange(location: range.location, length: NSMaxRange(next) - range.location), word))
                        index += 2; continue
                    }
                }
            }
            index += 1
            guard token.count >= 4, !exact.contains(token.lowercased()), !isOrdinary(token), !isOrdinary(token.lowercased()) else { continue }
            let digits = token.filter(\.isNumber)
            let matches = known.filter { $0.filter(\.isNumber) == digits && resembles(token, $0) }
            // One word, or the same word in several entries.
            guard let word = matches.first, Set(matches.map { $0.lowercased() }).count == 1, word != token else { continue }
            replacements.append((range, word))
        }
        guard !replacements.isEmpty else { return (text, 0) }
        let result = NSMutableString(string: text)
        for (range, word) in replacements.reversed() { result.replaceCharacters(in: range, with: word) }
        return (result as String, replacements.count)
    }

    /// The entries a text needs, in the dictionary's order: those whose word or spoken form is in
    /// it, or sounds like one of its words. A writing model reads these instead of the whole
    /// dictionary, which keeps its instructions short and to the point.
    public static func relevant(_ vocabulary: [VocabularyEntry], to text: String, limit: Int = 40) -> [VocabularyEntry] {
        guard !vocabulary.isEmpty else { return [] }
        let folded = " " + TextRules.canonical(text).lowercased() + " "
        let sounds = Set(folded.split(separator: " ").filter { $0.count >= 3 }.map { sound(String($0)) })
        let picked = vocabulary.filter { entry in
            for phrase in [entry.word, entry.heardAs] where !phrase.trimmingCharacters(in: .whitespaces).isEmpty {
                let canonical = TextRules.canonical(phrase).lowercased()
                if !canonical.isEmpty, folded.contains(" " + canonical + " ") { return true }
                let parts = canonical.split(separator: " ").filter { $0.count >= 3 }
                if !parts.isEmpty, parts.allSatisfy({ part in sounds.contains(sound(String(part))) || sounds.contains { resembles($0, sound(String(part))) } }) { return true }
            }
            return false
        }
        return Array(picked.prefix(limit))
    }

    /// Names you dictate again and again that the dictionary doesn't have yet: a word written
    /// with a capital inside a sentence, that no spelling checker knows, in at least `minimum`
    /// different dictations. The most frequent first.
    public static func recurringNames(in texts: [String], isOrdinary: (String) -> Bool, known: [String], minimum: Int = 3, limit: Int = 10) -> [String] {
        let have = Set(known.map { $0.lowercased() })
        var counts: [String: Int] = [:]
        for text in texts {
            var seen = Set<String>()
            for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?…\n")) {
                let words = sentence.split { !$0.isLetter && $0 != "'" && $0 != "’" }.map(String.init)
                for (position, word) in words.enumerated() where position > 0 {
                    guard word.count >= 3, let first = word.first, first.isUppercase, word.dropFirst().contains(where: \.isLowercase),
                          !have.contains(word.lowercased()), !isOrdinary(word.lowercased()) else { continue }
                    seen.insert(word)
                }
            }
            for word in seen { counts[word, default: 0] += 1 }
        }
        return counts.filter { $0.value >= minimum }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
    }
}
