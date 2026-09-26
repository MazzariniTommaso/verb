import Foundation

/// A note: a Markdown file in the notes folder. Meeting notes open with a few lines of front
/// matter ("type: meeting"), which Obsidian and similar apps read too.
public struct Note: Identifiable, Equatable, Sendable {
    public let url: URL
    public var text: String
    public var modified: Date
    public var id: URL { url }
    public init(url: URL, text: String, modified: Date) { self.url = url; self.text = text; self.modified = modified }

    public var isMeeting: Bool { Note.frontMatter(of: text)?.contains("type: meeting") == true }
    /// The text without its front matter.
    public var body: String {
        guard let matter = Note.frontMatter(of: text) else { return text }
        return String(text.dropFirst(matter.count)).trimmingCharacters(in: .newlines)
    }
    /// The first line with words, without Markdown's heading marks; nil for an empty note.
    public var title: String? {
        for line in body.split(separator: "\n") {
            let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*-> \t")).trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { return String(clean.prefix(80)) }
        }
        return nil
    }
    /// A few words after the title, for the list. List items read apart, "slide · provare la
    /// demo", unless a full stop already ends the line before.
    public var preview: String {
        let lines = body.split(separator: "\n").map(String.init)
        // Headings and bold section names ("## Notes", "**In short**") are not content.
        let content = lines.dropFirst(lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0 + 1 } ?? 0)
            .filter { line in let trimmed = line.trimmingCharacters(in: .whitespaces); return !trimmed.hasPrefix("#") && trimmed.range(of: #"^\*\*[^*]+\*\*:?$"#, options: .regularExpression) == nil }
            .map { line in (text: line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "-*>• \t_")),
                            item: line.range(of: #"^\s*(?:[-*+•]|\d+[.)])\s"#, options: .regularExpression) != nil) }
            .filter { !$0.text.isEmpty }
        var preview = ""
        for (index, line) in content.enumerated() {
            if index > 0 { preview += (line.item || content[index - 1].item) && !".!?…:;".contains(preview.last ?? " ") ? " · " : " " }
            preview += line.text
            if preview.count >= 120 { break }
        }
        return String(preview.prefix(120))
    }
    static func frontMatter(of text: String) -> String? {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else { return nil }
        return String(text[..<end.upperBound])
    }
}

public enum NotesStore {
    /// The notes in the folder, the most recently changed first.
    public static func list(in folder: URL) -> [Note] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Note(url: url, text: text, modified: modified)
        }.sorted { $0.modified > $1.modified }
    }

    /// A new note file, named after the moment it was made: "2026-09-26 10.30.md".
    public static func create(in folder: URL, text: String = "", suffix: String? = nil, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let base = formatter.string(from: now) + (suffix.map { " " + $0 } ?? "")
        var url = folder.appendingPathComponent(base + ".md"), number = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(base) \(number).md"); number += 1 }
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    public static func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url, options: .atomic) }
}

/// Who spoke in a meeting: you, heard by the microphone, or the others, heard through the Mac.
public enum Speaker: String, Codable, Sendable { case you, others }

public struct Utterance: Equatable, Sendable {
    public let speaker: Speaker
    public let start: Double
    public let end: Double
    public let text: String
    public init(speaker: Speaker, start: Double, end: Double, text: String) { self.speaker = speaker; self.start = start; self.end = end; self.text = text }
}

/// The notes of a meeting recorded on this Mac: both sides in time order, and the document.
public enum MeetingNotes {
    /// Both sides in time order. What the microphone caught of the others, played through the
    /// speakers, is left out; a side's lines close together become one.
    public static func merge(you: [Utterance], others: [Utterance]) -> [Utterance] {
        let mine = you.filter { line in
            !others.contains { other in
                let overlap = min(line.end, other.end) - max(line.start, other.start)
                return overlap > 0.5 * max(line.end - line.start, 0.1) && shared(line.text, other.text) >= 0.5
            }
        }
        var merged: [Utterance] = []
        for line in (mine + others).filter({ !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }).sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, last.speaker == line.speaker, line.start - last.end < 1.5 {
                merged[merged.count - 1] = Utterance(speaker: last.speaker, start: last.start, end: line.end, text: last.text + " " + line.text)
            } else { merged.append(line) }
        }
        return merged
    }

    /// The share of the shorter text's words that the other has too.
    static func shared(_ a: String, _ b: String) -> Double {
        func words(_ text: String) -> Set<String> { Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)) }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count))
    }

    /// "**You** (00:12): what was said", one line each.
    public static func transcript(_ lines: [Utterance], you: String, others: String) -> String {
        lines.map { line in
            let seconds = Int(line.start)
            let time = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
            return "**\(line.speaker == .you ? you : others)** (\(time)): \(line.text)"
        }.joined(separator: "\n\n")
    }

    /// The whole note: front matter, title, summary and transcript. The date is the local time
    /// with its offset from UTC ("2026-09-26T10:30:00+02:00"), so other apps read the same moment.
    /// The transcript goes in as given; the caller words an empty one in the note's language.
    public static func document(title: String, date: Date, minutes: Int, summary: String?, transcript: String, headings: (summary: String, transcript: String), timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]; formatter.timeZone = timeZone
        var parts = ["---\ntype: meeting\ndate: \(formatter.string(from: date))\nminutes: \(minutes)\n---", "# \(title)"]
        if let summary, !summary.isEmpty { parts.append("## \(headings.summary)\n\n" + summary) }
        parts.append(transcript.isEmpty ? "## \(headings.transcript)" : "## \(headings.transcript)\n\n" + transcript)
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// What the writing model is asked for, in the meeting's language.
    public static func summaryInstruction(italian: Bool) -> String {
        italian
            ? "Scrivi le note di questa riunione a partire dalla trascrizione. Usa Markdown con queste sezioni, omettendo quelle vuote: **In breve** (da tre a sei punti, per argomento), **Decisioni**, **Prossimi passi** (ogni punto con chi lo fa, se è stato detto), **Da fare per me** (le azioni di “Tu”). Scrivi in italiano. Non aggiungere nulla che non sia nella trascrizione."
            : "Write the notes of this meeting from the transcript. Use Markdown with these sections, leaving out any that would be empty: **In short** (three to six points, by topic), **Decisions**, **Next steps** (each with who does it, when that was said), **My to-dos** (the actions of “You”). Write in English. Add nothing that is not in the transcript."
    }

    /// A long transcript in parts of about `words` words, split between lines, for a model
    /// that reads a limited amount at once.
    public static func parts(_ transcript: String, words: Int) -> [String] {
        var parts: [String] = [], current: [Substring] = [], count = 0
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            let size = line.split(separator: " ").count
            if count + size > words, !current.isEmpty { parts.append(current.joined(separator: "\n\n")); current = []; count = 0 }
            current.append(line); count += size
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\n\n")) }
        return parts
    }
}
