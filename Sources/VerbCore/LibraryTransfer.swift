import Foundation

/// Moves the dictionary and the snippets in and out of Verb, as CSV (to edit in Numbers or
/// Excel) or as JSON (everything, as Verb keeps it). An import only adds: what is already
/// there, or would clash with it, is left out and counted.
public enum LibraryTransfer {
    public struct Outcome: Equatable, Sendable {
        public var added = 0
        public var skipped = 0
        public init(added: Int = 0, skipped: Int = 0) { self.added = added; self.skipped = skipped }
    }

    // MARK: Export

    public static func csv(vocabulary: [VocabularyEntry]) -> String {
        (["word,heard_as"] + vocabulary.map { row([$0.word, $0.heardAs]) }).joined(separator: "\n") + "\n"
    }
    public static func csv(snippets: [Snippet]) -> String {
        (["trigger,expansion"] + snippets.map { row([$0.trigger, $0.expansion]) }).joined(separator: "\n") + "\n"
    }
    public static func json(vocabulary: [VocabularyEntry]) throws -> Data { try encoder.encode(["vocabulary": vocabulary]) }
    public static func json(snippets: [Snippet]) throws -> Data { try encoder.encode(["snippets": snippets]) }
    private static var encoder: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return encoder }
    private static func row(_ fields: [String]) -> String {
        fields.map { field in
            field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == ";" }) ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
        }.joined(separator: ",")
    }

    // MARK: Import

    /// Words from a CSV (spelling, then optionally what it is heard as) or a JSON file:
    /// Verb's own export, a library.json, or a plain list.
    public static func vocabulary(from data: Data, isCSV: Bool) throws -> [VocabularyEntry] {
        if isCSV {
            return table(data, headers: ["word", "parola", "grafia", "spelling", "preferred spelling", "grafia preferita"]).compactMap { cells in
                guard let word = cells.first?.trimmed, !word.isEmpty else { return nil }
                return VocabularyEntry(word: word, heardAs: cells.count > 1 ? cells[1].trimmed : "")
            }
        }
        struct Loose: Decodable { var word: String; var heardAs: String? }
        struct Wrapped: Decodable { var vocabulary: [Loose] }
        let decoder = JSONDecoder()
        let loose = (try? decoder.decode(Wrapped.self, from: data).vocabulary) ?? (try? decoder.decode([Loose].self, from: data))
        guard let loose else { throw VerbError("This file has no dictionary Verb can read. Use a CSV with the spelling in the first column, or a JSON exported by Verb.") }
        return loose.map { VocabularyEntry(word: $0.word.trimmed, heardAs: ($0.heardAs ?? "").trimmed) }.filter { !$0.word.isEmpty }
    }

    /// Snippets from a CSV (the phrase, then the text) or a JSON file, which also says which
    /// snippets are formatted text.
    public static func snippets(from data: Data, isCSV: Bool) throws -> [Snippet] {
        if isCSV {
            return table(data, headers: ["trigger", "phrase", "frase", "quando dico", "when i say"]).compactMap { cells in
                guard cells.count >= 2, !cells[0].trimmed.isEmpty, !cells[1].isEmpty else { return nil }
                return Snippet(trigger: cells[0].trimmed, expansion: cells[1])
            }
        }
        struct Loose: Decodable { var trigger: String; var expansion: String; var formatted: Bool? }
        struct Wrapped: Decodable { var snippets: [Loose] }
        let decoder = JSONDecoder()
        let loose = (try? decoder.decode(Wrapped.self, from: data).snippets) ?? (try? decoder.decode([Loose].self, from: data))
        guard let loose else { throw VerbError("This file has no snippets Verb can read. Use a CSV with the phrase and the text in two columns, or a JSON exported by Verb.") }
        return loose.map { Snippet(trigger: $0.trigger.trimmed, expansion: $0.expansion, formatted: $0.formatted) }.filter { !$0.trigger.isEmpty && !$0.expansion.isEmpty }
    }

    /// Adds the new words to `existing`, with the rules of the word editor: one plain entry per
    /// spelling, one spelling per mishearing, and nothing that is already a snippet's phrase.
    public static func merge(_ incoming: [VocabularyEntry], into existing: inout [VocabularyEntry], snippets: [Snippet]) -> Outcome {
        var outcome = Outcome()
        for entry in incoming {
            let plainTaken = existing.contains { $0.heardAs.isEmpty && TextRules.canonical($0.word) == TextRules.canonical(entry.word) }
            let exact = existing.contains { TextRules.canonical($0.word) == TextRules.canonical(entry.word) && TextRules.canonical($0.heardAs) == TextRules.canonical(entry.heardAs) }
            let mishearingTaken = !entry.heardAs.isEmpty && existing.contains { !$0.heardAs.isEmpty && TextRules.canonical($0.heardAs) == TextRules.canonical(entry.heardAs) }
            let isSnippet = snippets.contains { TextRules.canonical($0.trigger) == TextRules.canonical(entry.word) }
            if exact || (entry.heardAs.isEmpty && plainTaken) || mishearingTaken || isSnippet || TextRules.canonical(entry.word).isEmpty || entry.word.count > 120 { outcome.skipped += 1; continue }
            existing.append(VocabularyEntry(word: entry.word, heardAs: entry.heardAs)); outcome.added += 1
        }
        return outcome
    }

    /// Adds the new snippets to `existing`: a phrase already used, by a snippet or as a
    /// dictionary word, is left out.
    public static func merge(_ incoming: [Snippet], into existing: inout [Snippet], vocabulary: [VocabularyEntry]) -> Outcome {
        var outcome = Outcome()
        for snippet in incoming {
            do {
                try TextRules.validate(trigger: snippet.trigger, existing: existing.map(\.trigger) + vocabulary.map(\.word))
                guard snippet.expansion.count <= 12000 else { throw VerbError("Too long.") }
                existing.append(Snippet(trigger: snippet.trigger, expansion: snippet.expansion, formatted: snippet.formatted)); outcome.added += 1
            } catch { outcome.skipped += 1 }
        }
        return outcome
    }

    // MARK: CSV

    /// The rows of a CSV file, without its header row. Commas, semicolons (as Excel writes in
    /// Italy) and tabs all work; quoted fields may hold any of them, and line breaks.
    static func table(_ data: Data, headers: [String]) -> [[String]] {
        let text = (String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "").replacingOccurrences(of: "\u{FEFF}", with: "")
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let delimiter: Character = [";", "\t", ","].max { a, b in firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count } ?? ","
        var rows = parse(text, delimiter: firstLine.contains(delimiter) ? delimiter : ",")
        if let first = rows.first?.first, headers.contains(first.trimmed.lowercased()) { rows.removeFirst() }
        return rows.filter { !$0.allSatisfy { $0.trimmed.isEmpty } }
    }

    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            if quoted {
                if character == "\"" {
                    if characters.first == "\"" { field.append("\""); characters.removeFirst() } else { quoted = false }
                } else { field.append(character) }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == delimiter {
                row.append(field); field = ""
            } else if character == "\n" || character == "\r" || character == "\r\n" {
                if character == "\r", characters.first == "\n" { characters.removeFirst() }
                row.append(field); rows.append(row); row = []; field = ""
            } else { field.append(character) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
