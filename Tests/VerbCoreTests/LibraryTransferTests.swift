import XCTest
@testable import VerbCore

/// Snippets that fill themselves in, and moving the library in and out as CSV or JSON.
final class LibraryTransferTests: XCTestCase {
    func testSnippetVariablesFillInTheirLanguage() {
        var parts = DateComponents(); parts.year = 2026; parts.month = 9; parts.day = 26; parts.hour = 14; parts.minute = 5
        let date = Calendar(identifier: .gregorian).date(from: parts)!
        let filled = SnippetVariables.fill("Oggi {data}, alle {ora}, {giorno}. Today {date} at {time}, {weekday}. Copied: {appunti}", now: date, clipboard: { "ciao" })
        XCTAssertEqual(filled, "Oggi 26 settembre 2026, alle 14:05, sabato. Today September 26, 2026 at 2:05 PM, Saturday. Copied: ciao")
        XCTAssertEqual(SnippetVariables.fill("Nessuna variabile {qui}", now: date), "Nessuna variabile {qui}", "unknown names stay as written")
    }

    func testTheCursorStopsWhereTheSnippetSays() {
        let filled = SnippetVariables.fill("Gentile {cursore},\ngrazie. {cursor}")
        XCTAssertEqual(filled, "Gentile \u{E000},\ngrazie. ", "only the first cursor counts")
        let placed = SnippetVariables.placeCursor(in: filled)
        XCTAssertEqual(placed.text, "Gentile ,\ngrazie. ")
        XCTAssertEqual(placed.back, 10)
        XCTAssertEqual(SnippetVariables.placeCursor(in: "no mark").back, 0)
    }

    func testCSVRoundTripWithCommasQuotesAndLineBreaks() throws {
        let snippets = [Snippet(trigger: "la mia firma", expansion: "Tommaso, \"Verb\"\nMilano"), Snippet(trigger: "indirizzo", expansion: "Via Roma 1; Milano")]
        let csv = LibraryTransfer.csv(snippets: snippets)
        let back = try LibraryTransfer.snippets(from: Data(csv.utf8), isCSV: true)
        XCTAssertEqual(back.map(\.trigger), ["la mia firma", "indirizzo"])
        XCTAssertEqual(back.map(\.expansion), snippets.map(\.expansion))
    }

    func testItalianExcelSemicolonsAndHeaders() throws {
        let csv = "parola;sentito come\r\nTommaso;Tomaso\r\nVerb;\r\n"
        let words = try LibraryTransfer.vocabulary(from: Data(csv.utf8), isCSV: true)
        XCTAssertEqual(words.map(\.word), ["Tommaso", "Verb"])
        XCTAssertEqual(words.map(\.heardAs), ["Tomaso", ""])
    }

    func testImportOnlyAddsWhatIsNew() throws {
        var existing = [VocabularyEntry(word: "Verb"), VocabularyEntry(word: "Claude", heardAs: "cloud")]
        let incoming = [VocabularyEntry(word: "verb"), VocabularyEntry(word: "Claudio", heardAs: "Cloud"), VocabularyEntry(word: "Atlas"), VocabularyEntry(word: "la mia firma")]
        let outcome = LibraryTransfer.merge(incoming, into: &existing, snippets: [Snippet(trigger: "la mia firma", expansion: "…")])
        XCTAssertEqual(outcome, LibraryTransfer.Outcome(added: 1, skipped: 3), "a repeat, a mishearing already mapped and a snippet phrase are left out")
        XCTAssertEqual(existing.map(\.word), ["Verb", "Claude", "Atlas"])
        var snippets = [Snippet(trigger: "firma", expansion: "A")]
        XCTAssertEqual(LibraryTransfer.merge([Snippet(trigger: "Firma", expansion: "B"), Snippet(trigger: "saluti", expansion: "Cari saluti")], into: &snippets, vocabulary: existing), LibraryTransfer.Outcome(added: 1, skipped: 1))
    }

    func testJSONKeepsFormattedSnippets() throws {
        let data = try LibraryTransfer.json(snippets: [Snippet(trigger: "firma", expansion: "**Tommaso**\nVerb", formatted: true), Snippet(trigger: "saluti", expansion: "Cari saluti")])
        let back = try LibraryTransfer.snippets(from: data, isCSV: false)
        XCTAssertEqual(back.map(\.isFormatted), [true, false])
        var existing: [Snippet] = []
        XCTAssertEqual(LibraryTransfer.merge(back, into: &existing, vocabulary: []), LibraryTransfer.Outcome(added: 2, skipped: 0))
        XCTAssertEqual(existing.map(\.isFormatted), [true, false], "the import keeps it too")
        XCTAssertNil(try LibraryTransfer.snippets(from: Data(#"[{"trigger": "ciao", "expansion": "Ciao!"}]"#.utf8), isCSV: false).first?.formatted, "a file without it imports as before")
    }

    func testVerbJSONAndPlainLists() throws {
        let data = try LibraryTransfer.json(vocabulary: [VocabularyEntry(word: "Atlas", heardAs: "atlas client")])
        XCTAssertEqual(try LibraryTransfer.vocabulary(from: data, isCSV: false).first?.heardAs, "atlas client")
        let plain = Data(#"[{"word": "Mecum"}]"#.utf8)
        XCTAssertEqual(try LibraryTransfer.vocabulary(from: plain, isCSV: false).map(\.word), ["Mecum"])
        XCTAssertThrowsError(try LibraryTransfer.snippets(from: Data("{}".utf8), isCSV: false))
    }
}
