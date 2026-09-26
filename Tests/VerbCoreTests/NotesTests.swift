import XCTest
@testable import VerbCore

/// Notes as Markdown files, and the notes of a meeting.
final class NotesTests: XCTestCase {
    func testNotesAreMarkdownFilesInAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("verb-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var parts = DateComponents(); parts.year = 2026; parts.month = 9; parts.day = 26; parts.hour = 10; parts.minute = 30
        let date = Calendar.current.date(from: parts)!
        let first = try NotesStore.create(in: folder, text: "# Idee per il lancio\n\nAprire con il caso di Torino.", now: date)
        let second = try NotesStore.create(in: folder, text: "", now: date)
        XCTAssertEqual(first.lastPathComponent, "2026-09-26 10.30.md")
        XCTAssertEqual(second.lastPathComponent, "2026-09-26 10.30 2.md", "two notes in the same minute don't overwrite each other")
        let notes = NotesStore.list(in: folder)
        XCTAssertEqual(notes.count, 2)
        let note = notes.first { $0.url.lastPathComponent == first.lastPathComponent }!
        XCTAssertEqual(note.title, "Idee per il lancio")
        XCTAssertEqual(note.preview, "Aprire con il caso di Torino.")
        XCTAssertFalse(note.isMeeting)
        XCTAssertNil(notes.first { $0.url.lastPathComponent == second.lastPathComponent }!.title)
    }

    func testAMeetingReadsInTimeOrderWithoutTheEcho() {
        let you = [Utterance(speaker: .you, start: 0, end: 4, text: "Ciao a tutti, partiamo dal budget."),
                   Utterance(speaker: .you, start: 10.2, end: 13, text: "the budget is fine for now"),
                   Utterance(speaker: .you, start: 20, end: 22, text: "Perfetto, allora chiudo io."),
                   Utterance(speaker: .you, start: 22.8, end: 24, text: "Mando la mail domani.")]
        let others = [Utterance(speaker: .others, start: 5, end: 9, text: "Il budget va rivisto entro venerdì."),
                      Utterance(speaker: .others, start: 10, end: 13, text: "The budget is fine for now, I think.")]
        let merged = MeetingNotes.merge(you: you, others: others)
        XCTAssertEqual(merged.map(\.speaker), [.you, .others, .you], "the microphone's echo of the others goes, close lines join")
        XCTAssertEqual(merged[1].text, "Il budget va rivisto entro venerdì. The budget is fine for now, I think.")
        XCTAssertEqual(merged.last?.text, "Perfetto, allora chiudo io. Mando la mail domani.")
        let transcript = MeetingNotes.transcript(merged, you: "Tu", others: "Altri")
        XCTAssertTrue(transcript.hasPrefix("**Tu** (00:00): Ciao a tutti"))
        let document = MeetingNotes.document(title: "Riunione del 26 settembre", date: Date(), minutes: 1, summary: "**In breve**\n- Budget da rivedere", transcript: transcript, headings: ("Note", "Trascrizione"))
        let note = Note(url: URL(fileURLWithPath: "/tmp/x.md"), text: document, modified: Date())
        XCTAssertTrue(note.isMeeting)
        XCTAssertEqual(note.title, "Riunione del 26 settembre")
        XCTAssertEqual(MeetingNotes.parts(transcript, words: 12).count, 3, "one part per line here, each over twelve words")
    }

    func testMeetingNotesKeepTheirLocalTimeAndReadWithoutDashes() {
        let rome = TimeZone(identifier: "Europe/Rome")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = rome
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 10, minute: 30))!
        let document = MeetingNotes.document(title: "Riunione", date: date, minutes: 5, summary: nil, transcript: "", headings: ("Note", "Trascrizione"), timeZone: rome)
        XCTAssertTrue(document.contains("\ndate: 2026-09-26T10:30:00+02:00\n"), "local time with its offset, not UTC without one")
        XCTAssertTrue(document.hasSuffix("## Trascrizione\n"), "an empty transcript stays empty: the caller words it")
        XCTAssertFalse(document.contains("—"))
        let late = [Utterance(speaker: .others, start: 3725, end: 3730, text: "Ci sentiamo.")]
        XCTAssertEqual(MeetingNotes.transcript(late, you: "Tu", others: "Altri"), "**Altri** (1:02:05): Ci sentiamo.")
    }

    func testPreviewsKeepListItemsApart() {
        let note = Note(url: URL(fileURLWithPath: "/tmp/x.md"), text: "# Lancio di ottobre\n\nAprire con il caso di Torino, poi i numeri del trimestre.\n\n- chiedere a Giulia le slide\n- provare la demo venerdì", modified: Date())
        XCTAssertEqual(note.preview, "Aprire con il caso di Torino, poi i numeri del trimestre. chiedere a Giulia le slide · provare la demo venerdì")
        let prose = Note(url: URL(fileURLWithPath: "/tmp/y.md"), text: "# Idee\nUna riga che va a capo\nsenza punto.", modified: Date())
        XCTAssertEqual(prose.preview, "Una riga che va a capo senza punto.", "lines of a paragraph join as they are")
    }
}
