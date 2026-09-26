import XCTest
@testable import VerbCore

/// Text that fits the field it goes into, words learned from corrections, names read from the
/// field, formatted snippets, and the richer totals.
final class FieldTests: XCTestCase {
    let ordinary: (String) -> Bool = { ["domani", "il", "ciao", "e", "poi", "ok", "the", "report", "va", "vado", "cloud", "merge", "code", "verb", "mario"].contains($0) }

    func testDictationFitsTheTextAroundTheCursor() {
        XCTAssertEqual(FieldFormatting.adjust("Ciao Marco.", before: "", after: "", isOrdinary: ordinary), "Ciao Marco.")
        XCTAssertEqual(FieldFormatting.adjust("Domani ci vediamo.", before: "Allora,", after: "", isOrdinary: ordinary), " domani ci vediamo.")
        XCTAssertEqual(FieldFormatting.adjust("Marco arriva domani.", before: "Ho sentito", after: "", isOrdinary: ordinary), " Marco arriva domani.", "a name keeps its capital")
        XCTAssertEqual(FieldFormatting.adjust("Il report.", before: "Ecco ", after: "per te", isOrdinary: ordinary), "il report ", "mid-sentence: small letter, no full stop, a space before what follows")
        XCTAssertEqual(FieldFormatting.adjust("ciao.", before: "Fine.", after: "", isOrdinary: ordinary), " Ciao.")
        XCTAssertEqual(FieldFormatting.adjust("API pronte.", before: "Le", after: "", isOrdinary: ordinary), " API pronte.", "acronyms stay")
        XCTAssertEqual(FieldFormatting.adjust("I think so.", before: "Well,", after: "", isOrdinary: ordinary), " I think so.")
        XCTAssertEqual(FieldFormatting.adjust("Ciao", before: "(", after: ")", isOrdinary: ordinary), "ciao")
        XCTAssertEqual(FieldFormatting.adjust("Ok.", before: "Detto \"Fatto.\"", after: "", isOrdinary: ordinary), " Ok.", "a closing quote after a full stop ends the sentence")
        XCTAssertEqual(FieldFormatting.adjust("E poi basta.", before: "Primo punto\n", after: "", isOrdinary: ordinary), "E poi basta.")
        XCTAssertEqual(FieldFormatting.adjust("Fatto.", before: "Tutto ", after: ", grazie", isOrdinary: ordinary), "Fatto", "no full stop before a comma")
    }

    func testDictationFitsAroundSpacesApostrophesAndDashes() {
        let ordinary: (String) -> Bool = { ["molto", "amico", "anno", "ottimo", "tempo"].contains($0) }
        XCTAssertEqual("Il film è" + FieldFormatting.adjust("Molto.", before: "Il film è", after: " bello", isOrdinary: ordinary) + " bello", "Il film è molto bello",
                       "a space before the next word is enough to go on with the sentence")
        XCTAssertEqual(FieldFormatting.adjust("Amico.", before: "Ciao l'", after: "", isOrdinary: ordinary), "amico.")
        XCTAssertEqual(FieldFormatting.adjust("anno", before: "all’inizio dell’", after: "", isOrdinary: ordinary), "anno")
        XCTAssertEqual(FieldFormatting.adjust("tempo", before: "un po'", after: "", isOrdinary: ordinary), " tempo", "“po’” is cut short, not elided")
        XCTAssertEqual(FieldFormatting.adjust("Ottimo.", before: "Il risultato –", after: "", isOrdinary: ordinary), " ottimo.", "a spaced dash goes on with the sentence")
        XCTAssertEqual(FieldFormatting.adjust("processing", before: "pre-", after: "", isOrdinary: ordinary), "processing", "a dash inside a word")
    }

    func testFieldTermsNeverReplaceKnownNamesOrOtherNumbers() {
        // Asked with its own casing, the checker knows "Paolo" and "Giulio", not "paolo" or "giulio".
        let known: (String) -> Bool = { ["Paolo", "Giulio", "Paola", "Giulia", "sentito", "ieri", "poi", "server", "parlato"].contains($0) }
        XCTAssertEqual(FieldTerms.correct("Ho sentito Paolo ieri, poi Giulio.", terms: ["Paola", "Giulia"], isOrdinary: known), "Ho sentito Paolo ieri, poi Giulio.")
        XCTAssertEqual(FieldTerms.correct("Il server usa IPv4 e GPT4.", terms: ["IPv6", "GPT5"], isOrdinary: known), "Il server usa IPv4 e GPT4.", "other digits are another thing")
        XCTAssertEqual(FieldTerms.correct("Il server usa gpt5.", terms: ["GPT5"], isOrdinary: known), "Il server usa GPT5.", "the same digits: only the letters change")
        XCTAssertEqual(FieldTerms.correct("Ho parlato con Tomaso ieri", terms: ["Tommaso"], isOrdinary: known), "Ho parlato con Tommaso ieri", "a misspelling that is no word")
    }

    func testRetypedWordsBecomeSuggestions() {
        XCTAssertEqual(CorrectionLearner.changes(inserted: "Ho parlato con Tomaso di cloud code.", current: "Ho parlato con Tommaso di Claude Code."),
                       [.init(heard: "Tomaso", written: "Tommaso"), .init(heard: "cloud code", written: "Claude Code")])
        XCTAssertEqual(CorrectionLearner.changes(inserted: "Aspettiamo che Elio faccia il mercio.", current: "Aspettiamo che Elio faccia il merge. E poi il resto"),
                       [.init(heard: "mercio", written: "merge")])
        XCTAssertEqual(CorrectionLearner.changes(inserted: "Ci vediamo domani.", current: "Ci vediamo domani alle tre."), [], "added words are not corrections")
        XCTAssertEqual(CorrectionLearner.changes(inserted: "testo di prova qui", current: "tutt'altro scritto completamente diverso"), [], "a rewritten passage is not a correction")
        XCTAssertEqual(CorrectionLearner.suggestion(for: .init(heard: "Tomaso", written: "Tommaso"), isOrdinary: ordinary), .replace(heard: "Tomaso", word: "Tommaso"))
        XCTAssertEqual(CorrectionLearner.suggestion(for: .init(heard: "cloud", written: "Claude"), isOrdinary: ordinary), .spelling("Claude"), "a common word is never replaced everywhere")
        XCTAssertEqual(CorrectionLearner.suggestion(for: .init(heard: "va", written: "vado"), isOrdinary: ordinary), nil, "grammar between common words")
        XCTAssertEqual(CorrectionLearner.suggestion(for: .init(heard: "mercio", written: "merge"), isOrdinary: ordinary), .replace(heard: "mercio", word: "merge"))
        XCTAssertEqual(CorrectionLearner.suggestion(for: .init(heard: "verb", written: "Verb"), isOrdinary: ordinary), .spelling("Verb"))
        XCTAssertEqual(CorrectionLearner.suggestion(for: .init(heard: "iphone", written: "iPhone"), isOrdinary: ordinary), .replace(heard: "iphone", word: "iPhone"))
        // A name that is also a word, and a phrase of common words.
        let everyWord: (String) -> Bool = { _ in true }
        XCTAssertEqual(CorrectionLearner.suggestion(for: .init(heard: "Cloud", written: "Claude"), isOrdinary: everyWord), nil, "two common words, and nothing says Claude is a name")
        XCTAssertEqual(CorrectionLearner.suggestion(for: .init(heard: "Cloud", written: "Claude"), isOrdinary: everyWord, isName: { $0 == "Claude" }), .spelling("Claude"))
        XCTAssertEqual(CorrectionLearner.suggestion(for: .init(heard: "Cloud Code", written: "Claude Code"), isOrdinary: everyWord), .replace(heard: "Cloud Code", word: "Claude Code"), "a phrase is replaced wherever it comes")
    }

    func testNamesComeFromTheField() {
        let terms = FieldTerms.extract(from: "Ciao Giulia, ho visto il progetto Atlas e la classe DictationRecord in AppModel.swift, con user_id e GPT5. Giulia dice ok.", isOrdinary: ordinary)
        for term in ["Giulia", "Atlas", "DictationRecord", "AppModel", "user_id", "GPT5"] { XCTAssertTrue(terms.contains(term), term) }
        XCTAssertFalse(terms.contains("Ciao"), "a word opening a sentence is not a name")
        XCTAssertEqual(terms.first, "Giulia", "the most frequent comes first")
        XCTAssertEqual(FieldTerms.correct("Ho parlato con Tomaso ieri", terms: ["Tommaso"], isOrdinary: ordinary), "Ho parlato con Tommaso ieri")
        XCTAssertEqual(FieldTerms.correct("Mario arriva", terms: ["Maria"], isOrdinary: ordinary), "Mario arriva", "a common word or name stays")
        XCTAssertEqual(FieldTerms.correct("la classe DictationRecod", terms: ["DictationRecord", "DictationStats"], isOrdinary: ordinary), "la classe DictationRecord")
    }

    func testMarkdownSnippetsBecomeHTMLAndPlainText() {
        let snippet = "Ciao **Anna**,\necco il *piano*:\n- primo punto\n- vedi [il sito](https://verb.app)\n\n`codice` finale"
        XCTAssertTrue(RichText.hasFormatting(snippet))
        XCTAssertFalse(RichText.hasFormatting("Ci vediamo alle 3, a presto."))
        XCTAssertEqual(RichText.html(fromMarkdown: snippet),
                       "<p>Ciao <strong>Anna</strong>,<br>ecco il <em>piano</em>:</p><ul><li>primo punto</li><li>vedi <a href=\"https://verb.app\">il sito</a></li></ul><p><code>codice</code> finale</p>")
        XCTAssertEqual(RichText.plain(fromMarkdown: snippet), "Ciao Anna,\necco il piano:\n• primo punto\n• vedi il sito (https://verb.app)\n\ncodice finale")
        XCTAssertEqual(RichText.html(fromMarkdown: "1. uno\n2. due & <tre>"), "<ol><li>uno</li><li>due &amp; &lt;tre&gt;</li></ol>")
    }

    func testRicherTotals() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: d, hour: 10))! }
        var stats = DictationStats()
        for (d, words) in [(20, 10), (21, 20), (22, 5), (24, 7), (25, 8), (26, 9)] {
            stats.add(DictationRecord(createdAt: day(d), duration: 10, text: Array(repeating: "parola", count: words).joined(separator: " "), appName: d == 26 ? "Claude" : "Mail", status: .completed, voiced: 6, fixes: 1))
        }
        XCTAssertEqual(stats.dictations, 6)
        XCTAssertEqual(stats.fixes, 6)
        XCTAssertEqual(stats.leavesOutPauses, true)
        XCTAssertEqual(stats.wordsPerMinute!, 59.0 / (36.0 / 60), accuracy: 0.001, "pauses are left out")
        let streak = stats.streak(today: day(26), calendar: calendar)
        XCTAssertEqual(streak.current, 3); XCTAssertEqual(streak.longest, 3)
        XCTAssertEqual(stats.streak(today: day(27), calendar: calendar).current, 3, "before today's first dictation the run still counts")
        XCTAssertEqual(stats.streak(today: day(29), calendar: calendar).current, 0)
        XCTAssertEqual(stats.words(inMonthOf: day(1), calendar: calendar), 59)
        XCTAssertEqual(stats.topApps(1).first?.name, "Mail")
        // Totals saved with only some fields still read.
        let partial = try! JSONDecoder().decode(DictationStats.self, from: Data(#"{"words": 100, "seconds": 60, "dictations": 3}"#.utf8))
        XCTAssertEqual(partial.words, 100); XCTAssertEqual(partial.days, [:]); XCTAssertEqual(partial.wordsPerMinute, 100)
    }
}
