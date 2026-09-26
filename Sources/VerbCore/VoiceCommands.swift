import Foundation

/// The phrases that start and end a dictation by voice. "Ehi Verb" (or "Hey Verb") opens a
/// hands-free dictation, like "Ehi Siri"; "Ehi Verb stop", "Ehi Verb invia" or "Ehi Verb
/// interrompi la trascrizione" at the end closes it, and "Ehi Verb annulla" throws it away.
/// Said with a vowel at the end, as Italian speakers often do, "Ehi Verba" and "Verba stop" work too.
///
/// The speech engine writes these phrases in more than one way. Heard on Parakeet with the
/// macOS voices: "Ehi Verb" comes out as "Hey verb", "Ei verb", "E i verb", "Ei verbo", and,
/// once the phrase has ended, as "A verb" or "Everb"; "Ehi Verba" as "Ej verba", "El verba" or
/// "Hey Veraba"; "annulla" as "a nulla" or "nulla", "invia" as "in via" or "enviar". So
/// matching works on folded words from a fixed list of spellings, never on the exact text,
/// and never by similarity: "i verbi", "e verbale" and "a verb" are ordinary speech.
///
/// "Verb" is an ordinary word in English and close to one in Italian, so it always needs a
/// greeting in front. A weak greeting ("a", "e") only counts when the utterance is the
/// phrase and nothing else, because "A verb describes an action" is a sentence, and before a
/// closing command only with the name itself: "Ho ripassato i verbi, basta" is a sentence too.
public enum VoiceCommands {
    public enum Ending: Equatable, Sendable { case finish, cancel }

    /// What a checked moment of speech means for Verb.
    public enum Decision: Equatable, Sendable {
        case none
        /// Start a dictation that records from this stream position.
        case wake(from: Int)
        case finish
        case cancel
    }

    /// A word of the text and where it sits, so a phrase can be cut out of the original.
    /// `opensSentence` is set when a full stop, question or exclamation mark comes before it:
    /// a greeting never reaches across one ("Ciao. Ehi Verb stop." keeps "Ciao.").
    struct Word { let folded: String; let range: Range<String.Index>; var opensSentence = false }

    /// Greetings that open the wake phrase on their own.
    static let wakeGreetings: Set<String> = ["ehi", "hey", "hei", "ei", "ej", "el", "evi", "eli", "ey", "ehy", "hej", "hi", "ay", "ai", "oh", "ohi", "oi"]
    /// "Ehi" heard as two words.
    static let splitGreetings: [[String]] = [["e", "i"], ["e", "hi"], ["eh", "i"]]
    /// Short words that are a greeting only in front of the name, when nothing else is said,
    /// or in front of the name itself and a closing command.
    static let weakGreetings: Set<String> = ["e", "i", "eh", "a", "ok", "okay"]
    static let greetings = wakeGreetings.union(weakGreetings)
    static let courtesies: [[String]] = [["grazie"], ["per", "favore"], ["thanks"], ["thank", "you"], ["please"]]

    /// The closing and cancelling words Verb starts with. Settings shows them and they can be changed.
    public static let standardFinishes = ["stop", "invia", "interrompi", "interrompi la trascrizione", "basta", "fine", "send", "done"]
    public static let standardCancels = ["annulla", "cancel"]
    /// How the engine splits or bends some commands, added whenever the command itself is chosen.
    static let heardAs: [String: [[String]]] = ["invia": [["in", "via"], ["enviar"]], "annulla": [["a", "nulla"], ["nulla"]], "send": [["sends"]]]

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// What Verb listens for: the name said after the greeting, the words that close or cancel
    /// a dictation, and the dictionary. The dictionary's corrections run before any matching,
    /// so a spelling the engine keeps getting wrong can be taught to mean the phrase.
    public struct Phrases: Sendable {
        /// Spellings that need no greeting because they are never ordinary words.
        let names: Set<String>
        /// Spellings that also count after a weak greeting when more words follow ("I Verba scrivi…").
        let canonicalNames: Set<String>
        /// Spellings that are, or are close to, ordinary words, so they always need a greeting.
        let shortNames: Set<String>
        /// Heard only in front of a closing command ("e i verbi in via"), never as a wake phrase.
        let closingOnlyNames: Set<String>
        /// The names as chosen, the only spellings a weak greeting counts before in a closing
        /// phrase: "e verb stop" closes, "i verbi, basta" and "e verbo stop" don't.
        let exactNames: Set<String>
        let finishes: [[String]]
        let cancels: [[String]]
        /// How each command is written in the settings, by its folded words: "interrompi la trascrizione".
        let spellings: [[String]: String]
        let corrections: [VocabularyEntry]
        /// Spellings taught to the dictionary for the wake phrase ("e verbe" for "Ehi Verb"), as
        /// folded words. They find the phrase at the start or before a command, and nowhere else.
        private(set) var taughtWakes: [[String]] = []
        /// Spellings taught for a whole closing phrase ("everbstop" for "Ehi Verb stop").
        private(set) var taughtEndings: [(words: [String], ending: VoiceCommands.Ending)] = []

        /// `names` are the words said after "Ehi", as many as wanted. Verb keeps every spelling
        /// the engine has been heard to write for it, "Verba" among them; any other name is
        /// matched as written, always after a greeting.
        public init(names given: [String] = ["Verb"], finishWords: [String] = VoiceCommands.standardFinishes, cancelWords: [String] = VoiceCommands.standardCancels, vocabulary: [VocabularyEntry] = []) {
            var names = Set<String>(), canonical = Set<String>(), short = Set<String>(), closingOnly = Set<String>(), exact = Set<String>()
            let chosen = given.compactMap { VoiceCommands.words($0).first?.folded }
            for name in chosen.isEmpty ? ["verb"] : chosen {
                if name == "verb" || name == "verba" {
                    names.formUnion(["verba", "werba", "berba", "veraba", "varaba", "verbah", "verber"])
                    canonical.insert("verba")
                    short.formUnion(["verb", "werb", "berb", "verbo"])
                    closingOnly.insert("verbi")
                    exact.formUnion(["verb", "verba"])
                } else {
                    short.insert(name)
                    exact.insert(name)
                }
            }
            self.names = names; canonicalNames = canonical; shortNames = short; closingOnlyNames = closingOnly; exactNames = exact
            var spellings: [[String]: String] = [:]
            func phrases(_ entries: [String]) -> [[String]] {
                var result: [[String]] = []
                for entry in entries {
                    let words = VoiceCommands.words(entry).map(\.folded)
                    guard !words.isEmpty, !result.contains(words) else { continue }
                    let spelled = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    result.append(words); spellings[words] = spelled
                    if words.count == 1 { for variant in VoiceCommands.heardAs[words[0]] ?? [] { result.append(variant); spellings[variant] = spelled } }
                }
                return result
            }
            finishes = phrases(finishWords)
            cancels = phrases(cancelWords)
            self.spellings = spellings
            corrections = vocabulary.filter { !$0.heardAs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            for entry in corrections {
                let spoken = VoiceCommands.words(entry.heardAs).map(\.folded)
                guard !spoken.isEmpty else { continue }
                if isWake(entry.word) { taughtWakes.append(spoken) } else if let ending = closing(entry.word) { taughtEndings.append((spoken, ending)) }
            }
            taughtWakes.sort { $0.count > $1.count }
            taughtEndings.sort { $0.words.count > $1.words.count }
        }

        /// Whether a dictionary entry teaches a spelling of the phrases rather than of a word.
        /// Such an entry helps Verb hear the command; it is not applied to the words you keep,
        /// where it would turn ordinary speech ("nomi e verbi") into the phrase.
        public func isCommand(_ entry: VocabularyEntry) -> Bool {
            !entry.heardAs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (isWake(entry.word) || closing(entry.word) != nil)
        }
        /// The dictionary without the entries that teach the phrases: what applies to the text.
        public func wording(_ vocabulary: [VocabularyEntry]) -> [VocabularyEntry] { vocabulary.filter { !isCommand($0) } }

        public init(name: String, finishWords: [String] = VoiceCommands.standardFinishes, cancelWords: [String] = VoiceCommands.standardCancels, vocabulary: [VocabularyEntry] = []) {
            self.init(names: [name], finishWords: finishWords, cancelWords: cancelWords, vocabulary: vocabulary)
        }

        public static let standard = Phrases()

        /// The text with the dictionary's corrections applied, as the matching sees it.
        public func corrected(_ text: String) -> String { corrections.isEmpty ? text : TextRules.corrected(text, vocabulary: corrections) }
        var allNames: Set<String> { names.union(shortNames) }
    }

    // MARK: Deciding

    /// While idle, a wake phrase starts a dictation: from the start of the utterance when
    /// words follow it, so they are kept, or from its end when it stood alone. A check made
    /// while the person is still talking trusts only a clear greeting, because the utterance
    /// may still turn into "A verb describes…", and waits while nothing but the phrase has been
    /// said. While recording, a command at the very end finishes or cancels.
    public static func decide(_ text: String, after event: VoiceActivity.Event, recording: Bool, using phrases: Phrases = .standard) -> Decision {
        let words = words(phrases.corrected(text))
        if recording {
            guard case .ended = event, let ending = phrases.endingMatch(words)?.ending else { return .none }
            return ending == .finish ? .finish : .cancel
        }
        // "Ehi Verb stop" said while nothing records is a command with nothing to do, not a wake.
        if phrases.endingMatch(words) != nil { return .none }
        switch event {
        case .started: return .none
        case .continuing(let segment):
            // Only the phrase so far: wait for the pause or the next words. Starting now could
            // cut into a word that has only just begun.
            guard let length = phrases.opening(words, strict: true), length < words.count else { return .none }
            return .wake(from: segment.start)
        case .ended(let segment):
            if let length = phrases.opening(words, strict: false) { return .wake(from: length == words.count ? segment.end : segment.start) }
            return phrases.closesWithWake(words) ? .wake(from: segment.end) : .none
        }
    }

    /// Reads the checks of one stream in order. It remembers a wake phrase heard while the
    /// utterance was still going, so the pause that ends it can start the dictation even when
    /// the last reading comes out garbled ("L verba" after "El verba").
    public struct Reader: Sendable {
        public var phrases: Phrases
        private var phraseHeardIn: Int?
        public init(phrases: Phrases = .standard) { self.phrases = phrases }
        public mutating func read(_ text: String, after event: VoiceActivity.Event, recording: Bool) -> Decision {
            let decision = VoiceCommands.decide(text, after: event, recording: recording, using: phrases)
            guard !recording else { phraseHeardIn = nil; return decision }
            switch event {
            case .started: return decision
            case .continuing(let segment):
                if decision == .none, phrases.isOnlyWake(phrases.corrected(text)) { phraseHeardIn = segment.start }
                return decision
            case .ended(let segment):
                defer { phraseHeardIn = nil }
                // A closing command said while nothing records ends the matter too.
                if decision != .none || phrases.endingMatch(VoiceCommands.words(phrases.corrected(text))) != nil { return decision }
                return phraseHeardIn == segment.start ? .wake(from: segment.end) : .none
            }
        }
    }

    /// What a failed try can teach the dictionary. For the wake phrase: the words the engine
    /// wrote for it ("e verbe"). For a closing phrase: those words with the command after them
    /// ("ever stop"), so the lesson closes a dictation and never starts one. At most three
    /// words before the command, lowercased, accents kept, because the dictionary matches them
    /// as written.
    public struct Lesson: Equatable, Sendable {
        public let heard: String
        /// The command the phrase ended with, as the settings write it; nil for the wake phrase.
        public let command: String?
        public init(heard: String, command: String?) { self.heard = heard; self.command = command }
    }
    public static func lesson(in text: String, closing: Bool, using phrases: Phrases = .standard) -> Lesson? {
        let words = words(text)
        var end = words.count, command: String?
        if closing {
            let folded = words.map(\.folded)
            guard let found = (phrases.finishes + phrases.cancels).sorted(by: { $0.count > $1.count }).first(where: { $0.count < folded.count && Array(folded.suffix($0.count)) == $0 }) else { return nil }
            end -= found.count
            command = phrases.spellings[found] ?? found.joined(separator: " ")
        }
        guard end > 0, end <= 3 else { return nil }
        return Lesson(heard: words.map { text[$0.range].lowercased() }.joined(separator: " "), command: command)
    }

    // MARK: Cleaning the transcript

    /// The text without the wake phrase it opens with, for dictations started by voice. The
    /// next word takes the capital the phrase had: "Ehi Verb, scrivi a Marco" becomes
    /// "Scrivi a Marco".
    public static func removingWake(from text: String, using phrases: Phrases = .standard) -> String {
        let words = words(text)
        guard let count = phrases.leading(words) else { return text }
        var rest = String(text[words[count - 1].range.upperBound...])
        rest = rest.replacingOccurrences(of: #"^[\s\p{P}]+"#, with: "", options: .regularExpression)
        if let first = rest.first, text.first?.isUppercase == true { rest = first.uppercased() + rest.dropFirst() }
        return rest
    }

    /// The text without the commands it ends with. When the command closed the last sentence,
    /// the sentence keeps its full stop: "Ci vediamo domani, ehi Verb stop." becomes
    /// "Ci vediamo domani."
    public static func removingEnding(from text: String, using phrases: Phrases = .standard) -> String {
        var result = text
        while let match = phrases.endingMatch(words(result)) {
            let cut = words(result)[match.start].range.lowerBound
            let removed = result[cut...]
            var head = String(result[..<cut]).replacingOccurrences(of: #"[\s,;:–—-]+$"#, with: "", options: .regularExpression)
            if let last = head.last, !".!?…:;".contains(last), removed.contains(where: { ".!?".contains($0) }) { head += "." }
            result = head
        }
        return result
    }

    // MARK: Matching

    static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        var index = text.startIndex, sentenceBreak = false
        while index < text.endIndex {
            guard text[index].isLetter || text[index].isNumber else {
                if ".!?…".contains(text[index]) { sentenceBreak = true }
                index = text.index(after: index); continue
            }
            var end = index
            while end < text.endIndex, text[end].isLetter || text[end].isNumber { end = text.index(after: end) }
            let folded = text[index..<end].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            result.append(Word(folded: folded, range: index..<end, opensSentence: sentenceBreak && !result.isEmpty))
            index = end; sentenceBreak = false
        }
        return result
    }

    /// Whether the words from `start` up to `end` belong to one sentence.
    static func sameSentence(_ words: [Word], _ start: Int, _ end: Int) -> Bool {
        start >= end || !words[(start + 1)...end].contains(where: \.opensSentence)
    }

    /// How many words a greeting takes at `index`: one ("ehi"), two ("e i") or none.
    static func greetingLength(_ folded: [String], at index: Int, weak: Bool) -> Int {
        guard index < folded.count else { return 0 }
        if let split = splitGreetings.first(where: { index + $0.count <= folded.count && Array(folded[index..<(index + $0.count)]) == $0 }) { return split.count }
        return (weak ? greetings : wakeGreetings).contains(folded[index]) ? 1 : 0
    }

}

extension VoiceCommands.Phrases {
    typealias Word = VoiceCommands.Word
    typealias Ending = VoiceCommands.Ending

    /// "heyverb", "everb", "ehiverba": a greeting and the name written as one word.
    func isJoinedWake(_ word: String, greetings: Set<String>) -> Bool {
        allNames.contains(where: { word.hasSuffix($0) && greetings.contains(String(word.dropLast($0.count))) })
    }

    /// How many words the wake phrase takes at the start of an utterance, if it is there.
    /// `strict` is for checks made mid-utterance, where more words may follow.
    func opening(_ words: [Word], strict: Bool) -> Int? {
        let folded = words.map(\.folded)
        guard let first = folded.first else { return nil }
        if isJoinedWake(first, greetings: VoiceCommands.wakeGreetings) { return 1 }
        let greeting = VoiceCommands.greetingLength(folded, at: 0, weak: false)
        if greeting > 0, folded.count > greeting, names.contains(folded[greeting]) || shortNames.contains(folded[greeting]), VoiceCommands.sameSentence(words, 0, greeting) { return greeting + 1 }
        guard !strict else { return nil }
        // Once the utterance is over: "Verba" after a weak greeting ("I Verba scrivi…"),
        // or a weak greeting and Verb that make up the whole utterance ("A verb.", "Everb.").
        if folded.count >= 2, VoiceCommands.weakGreetings.contains(first), canonicalNames.contains(folded[1]) { return 2 }
        if folded.count == 2, VoiceCommands.weakGreetings.contains(first), shortNames.contains(folded[1]) { return 2 }
        if folded.count == 1, names.contains(first) || isJoinedWake(first, greetings: VoiceCommands.weakGreetings) { return 1 }
        return nil
    }

    /// Whether an utterance ends with the wake phrase, as in "…allora, ehi Verb".
    func closesWithWake(_ words: [Word]) -> Bool {
        let folded = words.map(\.folded)
        guard let last = folded.last else { return false }
        if isJoinedWake(last, greetings: VoiceCommands.wakeGreetings) { return true }
        guard names.contains(last) || shortNames.contains(last), folded.count >= 2 else { return false }
        if VoiceCommands.wakeGreetings.contains(folded[folded.count - 2]) { return true }
        return VoiceCommands.splitGreetings.contains { folded.count > $0.count && Array(folded[(folded.count - 1 - $0.count)..<(folded.count - 1)]) == $0 }
    }

    /// The wake phrase at the start of a dictation that began by voice, in any of its forms.
    func leading(_ words: [Word]) -> Int? {
        let folded = words.map(\.folded)
        guard let first = folded.first else { return nil }
        if isJoinedWake(first, greetings: VoiceCommands.greetings) || names.contains(first) { return 1 }
        let greeting = VoiceCommands.greetingLength(folded, at: 0, weak: true)
        if greeting > 0, folded.count > greeting, names.contains(folded[greeting]) || shortNames.contains(folded[greeting]) { return greeting + 1 }
        return taughtWakes.first { folded.starts(with: $0) }?.count
    }

    /// Whether the text is the wake phrase and nothing else: "Ehi Verb", "Verba".
    func isWake(_ text: String) -> Bool {
        let words = VoiceCommands.words(text)
        return !words.isEmpty && opening(words, strict: false) == words.count
    }
    /// The command a text is, when it is a whole closing phrase: "Ehi Verb stop".
    func closing(_ text: String) -> Ending? {
        guard let match = endingMatch(VoiceCommands.words(text)), match.start == 0 else { return nil }
        return match.ending
    }

    /// A single word made of the name and a command, with at most two stray letters
    /// between them. No real word has that shape.
    func joinedCommand(_ word: String) -> Ending? {
        for name in allNames.sorted(by: { $0.count > $1.count }) where word.hasPrefix(name) && word.count > name.count {
            let rest = word.dropFirst(name.count)
            for (phrases, ending) in [(finishes, Ending.finish), (cancels, Ending.cancel)] {
                for phrase in phrases where phrase.count == 1 && rest.hasSuffix(phrase[0]) && rest.count - phrase[0].count <= 2 { return ending }
            }
        }
        return nil
    }

    /// The command at the end of the text and the index of its first word, greeting included.
    func endingMatch(_ words: [Word]) -> (start: Int, ending: Ending)? {
        func ends(_ end: Int, with phrase: [String]) -> Bool {
            end >= phrase.count && zip(words[(end - phrase.count)..<end], phrase).allSatisfy { $0.folded == $1 }
        }
        var end = words.count
        if let courtesy = VoiceCommands.courtesies.first(where: { ends(end, with: $0) }) { end -= courtesy.count }
        // The name and a one-word command run together: "Verbisend", "Verbastop".
        if end > 0, let ending = joinedCommand(words[end - 1].folded) {
            let greeted = end > 1 && VoiceCommands.greetings.contains(words[end - 2].folded) && VoiceCommands.sameSentence(words, end - 2, end - 1)
            return (greeted ? end - 2 : end - 1, ending)
        }
        for (phrases, ending) in [(finishes, Ending.finish), (cancels, Ending.cancel)] {
            for phrase in phrases.sorted(by: { $0.count > $1.count }) where ends(end, with: phrase) {
                let nameIndex = end - phrase.count - 1
                guard nameIndex >= 0 else { continue }
                let name = words[nameIndex].folded
                // The greeting before the name, if any: "e i" as two words, or one, in the same sentence.
                let folded = words.map(\.folded)
                let split = VoiceCommands.splitGreetings.first { nameIndex >= $0.count && Array(folded[(nameIndex - $0.count)..<nameIndex]) == $0 }
                var greeting = split?.count ?? (nameIndex > 0 && VoiceCommands.greetings.contains(folded[nameIndex - 1]) ? 1 : 0)
                if !VoiceCommands.sameSentence(words, nameIndex - greeting, nameIndex) { greeting = 0 }
                if names.contains(name) { return (nameIndex - greeting, ending) }
                // "Ehi", or "e i" opening a sentence, is a greeting before any form of the name; "i", or
                // "e i" inside a sentence, only before the name itself: "i nomi e i verbi, basta" is speech.
                let first = nameIndex - greeting
                let strong = split != nil ? first == 0 || words[first].opensSentence : greeting > 0 && VoiceCommands.wakeGreetings.contains(folded[first])
                // Verb needs its greeting, in the same sentence as the command: "a verb. Stop." is two sentences.
                if shortNames.union(closingOnlyNames).contains(name), greeting > 0, strong || exactNames.contains(name), VoiceCommands.sameSentence(words, first, end - 1) { return (first, ending) }
                if isJoinedWake(name, greetings: VoiceCommands.greetings) { return (nameIndex, ending) }
            }
        }
        // Spellings taught to the dictionary: a whole closing phrase, or the wake phrase before a command.
        if let taught = taughtEndings.first(where: { ends(end, with: $0.words) }) { return (end - taught.words.count, taught.ending) }
        for (phrases, ending) in [(finishes, Ending.finish), (cancels, Ending.cancel)] {
            for phrase in phrases.sorted(by: { $0.count > $1.count }) where ends(end, with: phrase) {
                if let wake = taughtWakes.first(where: { ends(end - phrase.count, with: $0) }) { return (end - phrase.count - wake.count, ending) }
            }
        }
        return nil
    }

    /// The utterance so far is the wake phrase and nothing else.
    func isOnlyWake(_ text: String) -> Bool {
        let words = VoiceCommands.words(text)
        return opening(words, strict: true).map { $0 == words.count } ?? false
    }
}
