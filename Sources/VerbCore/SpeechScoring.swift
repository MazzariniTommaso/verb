import Foundation

/// Word (or character) edits between a reference and a transcript.
public struct EditCounts: Codable, Equatable, Sendable {
    public var substitutions: Int, deletions: Int, insertions: Int, reference: Int
    public init(substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0, reference: Int = 0) {
        self.substitutions = substitutions; self.deletions = deletions; self.insertions = insertions; self.reference = reference
    }
    public var errors: Int { substitutions + deletions + insertions }
    /// Errors per reference unit; nil when there was nothing to recognize.
    public var rate: Double? { reference > 0 ? Double(errors) / Double(reference) : nil }
    public static func + (a: EditCounts, b: EditCounts) -> EditCounts {
        EditCounts(substitutions: a.substitutions + b.substitutions, deletions: a.deletions + b.deletions, insertions: a.insertions + b.insertions, reference: a.reference + b.reference)
    }
}

/// Scores transcripts the way speech benchmarks do, so results compare with the public leaderboards:
/// case, punctuation and symbols are dropped and only the words count. A second, stricter score keeps
/// case and punctuation, because a dictation is inserted as it comes out of the model.
public enum SpeechScoring {
    /// Written without spaces between words, so they are scored by character.
    public static let characterLanguages: Set<String> = ["zh", "ja", "ko", "th", "yue", "lo", "my", "km"]

    public static func score(reference: String, hypothesis: String, language: String) -> EditCounts {
        edits(reference: units(reference, language: language), hypothesis: units(hypothesis, language: language))
    }
    public static func scoreFormatted(reference: String, hypothesis: String, language: String) -> EditCounts {
        edits(reference: formattedUnits(reference, language: language), hypothesis: formattedUnits(hypothesis, language: language))
    }

    /// Lowercased words without punctuation or symbols, with spoken numbers as digits. Combining
    /// marks stay, unlike Whisper's normalizer, so Devanagari and similar scripts keep their words
    /// whole. Words in parentheses stay too: in FLEURS they were read aloud.
    public static func units(_ text: String, language: String) -> [String] {
        var text = text.precomposedStringWithCompatibilityMapping.lowercased()
        text = text.replacingOccurrences(of: #"[<\[][^>\]]*[>\]]"#, with: " ", options: .regularExpression)
        // "10.000", "10,000" and "10 000" are one number.
        text = text.replacingOccurrences(of: #"(?<=\d)[.,'’\x{00A0}\x{202F} ](?=\d{3}(?!\d))"#, with: "", options: .regularExpression)
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { isPunctuationOrSymbol($0) ? " " : $0 }))
        if characterLanguages.contains(base(language)) { return cleaned.filter { !$0.isWhitespace }.map(String.init) }
        return SpokenNumbers.digits(cleaned.split(whereSeparator: \.isWhitespace).map(String.init), language: language)
    }

    /// Words with their case, and each punctuation mark as a unit of its own.
    public static func formattedUnits(_ text: String, language: String) -> [String] {
        let text = text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        let byCharacter = characterLanguages.contains(base(language))
        var result: [String] = [], word = ""
        for character in text {
            let scalar = character.unicodeScalars.first!
            if character.isWhitespace || isPunctuationOrSymbol(scalar) {
                if !word.isEmpty { result.append(word); word = "" }
                if !character.isWhitespace { result.append(String(character)) }
            } else if byCharacter { result.append(String(character)) } else { word.append(character) }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }

    /// Levenshtein alignment over units. On ties a substitution wins over a deletion, and a deletion
    /// over an insertion, as in the usual WER tools.
    public static func edits(reference: [String], hypothesis: [String]) -> EditCounts {
        if reference.isEmpty { return EditCounts(insertions: hypothesis.count) }
        if hypothesis.isEmpty { return EditCounts(deletions: reference.count, reference: reference.count) }
        struct Cell { var cost = 0, s = 0, d = 0, i = 0 }
        var previous = (0...hypothesis.count).map { Cell(cost: $0, i: $0) }
        for (row, word) in reference.enumerated() {
            var current = [Cell(cost: row + 1, d: row + 1)]
            current.reserveCapacity(hypothesis.count + 1)
            for column in 1...hypothesis.count {
                var best = previous[column - 1]
                if word != hypothesis[column - 1] { best.cost += 1; best.s += 1 }
                var deletion = previous[column]; deletion.cost += 1; deletion.d += 1
                var insertion = current[column - 1]; insertion.cost += 1; insertion.i += 1
                if deletion.cost < best.cost { best = deletion }
                if insertion.cost < best.cost { best = insertion }
                current.append(best)
            }
            previous = current
        }
        let last = previous[hypothesis.count]
        return EditCounts(substitutions: last.s, deletions: last.d, insertions: last.i, reference: reference.count)
    }

    /// The value below which the given share of the values falls, by linear interpolation.
    public static func percentile(_ values: [Double], _ share: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), position = share * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// "zh-CN" and "pt_br" score as "zh" and "pt".
    public static func base(_ language: String) -> String {
        String(language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    private static func isPunctuationOrSymbol(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return true
        default: return false
        }
    }
}
