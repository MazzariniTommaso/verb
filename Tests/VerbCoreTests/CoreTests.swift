import XCTest
@testable import VerbCore

final class CoreTests: XCTestCase {
    func testDataFolderIsVerbAndNothingIsCreatedBeforeUse() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        XCTAssertEqual(DataPaths.defaultRoot(in: support).lastPathComponent, "Verb")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: support.path), [])
    }
    func testSettingsWithoutInterfaceKeepEverythingAndGainItsDefaults() throws {
        var saved = Settings(); saved.style = .formal
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(saved))
        XCTAssertNil(decoded.interface)
        XCTAssertEqual(decoded.style, .formal)
        XCTAssertEqual(decoded.interfaceOptions.language, .english)
        XCTAssertEqual(decoded.interfaceOptions.appearance, .automatic)
        var chosen = Settings(); chosen.interfaceOptions.language = .italian; chosen.interfaceOptions.appearance = .dark
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(chosen)).interfaceOptions, chosen.interfaceOptions)
        let partial = try JSONDecoder().decode(InterfacePreferences.self, from: Data("{\"language\":\"it\"}".utf8))
        XCTAssertEqual(partial.language, .italian)
        XCTAssertEqual(partial.appearance, .automatic)
    }
    func testSnippetsAreProtectedFromAIRewriting() throws {
        let protected = TextRules.protect("Ciao, la mia firma", snippets: [Snippet(trigger: "la mia firma", expansion: "Tommaso\nNuovo paragrafo Studio")])
        XCTAssertFalse(protected.text.contains("Tommaso"))
        XCTAssertEqual(try protected.restore(protected.text), "Ciao, Tommaso\nNuovo paragrafo Studio")
        XCTAssertThrowsError(try protected.restore("Ciao, rewritten signature"))
    }
    func testLongestSnippetDoesNotCascadeOrMatchInsideWords() {
        let snippets = [Snippet(trigger: "my signature", expansion: "Tommaso"), Snippet(trigger: "signature", expansion: "my signature"), Snippet(trigger: "cat", expansion: "dog")]
        XCTAssertEqual(TextRules.expand("My signature, with a cat in a cathedral", snippets: snippets), "Tommaso, with a dog in a cathedral")
        XCTAssertEqual(TextRules.expand("signature", snippets: snippets), "my signature")
    }
    func testExactSnippetKeepsSavedFormatting() {
        XCTAssertEqual(TextRules.expand("LA MIA FIRMA!", snippets: [Snippet(trigger: "la mia firma", expansion: "Tommaso\nDesign & Engineering")]), "Tommaso\nDesign & Engineering")
    }
    func testUnicodeCorrectionsAndLiteralReplacement() {
        let words = [VocabularyEntry(word: "Mazzarini Forte", heardAs: "mazzarini forte"), VocabularyEntry(word: "$5\\hour", heardAs: "rate")]
        XCTAssertEqual(TextRules.corrected("È Mazzarini Forte. rate", vocabulary: words), "È Mazzarini Forte. $5\\hour")
    }
    func testEndpointPrivacyAndCredentialBoundaries() throws {
        XCTAssertNoThrow(try EndpointPolicy.validate("http://127.0.0.1:8080/v1/audio/transcriptions", allowRemote: false))
        for bad in ["https://api.example.com/v1", "http://127.0.0.1.evil.test/v1", "file:///tmp/foo", "https://user:secret@localhost/"] { XCTAssertThrowsError(try EndpointPolicy.validate(bad, allowRemote: false)) }
        XCTAssertThrowsError(try EndpointPolicy.validate("http://example.com", allowRemote: true))
        XCTAssertNoThrow(try EndpointPolicy.validate("https://example.com/v1", allowRemote: true))
        XCTAssertThrowsError(try EndpointPolicy.localModel("qwen:cloud"))
    }
    func testLibraryRejectsAmbiguousTriggers() {
        XCTAssertThrowsError(try TextRules.validate(trigger: "My signature!", existing: ["my signature"]))
        XCTAssertThrowsError(try TextRules.validate(trigger: "...", existing: []))
    }
    func testHistorySurvivesRestartAndRecoversInterruptedWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try DataPaths(root: root)
        let record = DictationRecord(text: "Ciao 👋", status: .processing)
        do { let store = try HistoryStore(paths: paths); try store.save(record) }
        let reopened = try HistoryStore(paths: paths)
        try reopened.recoverInterrupted()
        XCTAssertEqual(try reopened.all().first?.text, "Ciao 👋")
        XCTAssertEqual(try reopened.all().first?.status, .failed)
    }
    func testRetentionDeletesAudioAlongWithText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try DataPaths(root: root), store = try HistoryStore(paths: paths)
        let audio = paths.audio.appendingPathComponent("test.wav")
        try Data([1,2,3]).write(to: audio)
        try store.save(DictationRecord(createdAt: Date().addingTimeInterval(-90000), audioName: "test.wav"))
        try store.prune(retention: .day, keepAudio: true)
        XCTAssertTrue(try store.all().isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertNil(paths.audioURL("../settings.json"))
    }
    func testCrashCleanupRemovesOnlyUnreferencedAppRecordings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try DataPaths(root: root), store = try HistoryStore(paths: paths)
        let saved = UUID().uuidString + ".wav", orphan = UUID().uuidString + ".wav"
        for name in [saved, orphan, "readme.txt"] { try Data([1]).write(to: paths.audio.appendingPathComponent(name)) }
        try store.save(DictationRecord(audioName: saved)); try store.removeOrphanedAudio()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.audio.appendingPathComponent(saved).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.audio.appendingPathComponent(orphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.audio.appendingPathComponent("readme.txt").path))
    }
    func testSettingsRoundTripAndCorruptionIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONStore.save(Settings(), to: url)
        XCTAssertEqual(try JSONStore.load(Settings.self, from: url, fallback: Settings()), Settings())
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try JSONStore.load(Settings.self, from: url, fallback: Settings()))
        XCTAssertEqual(try String(contentsOf: url), "broken")
    }
    func testMalformedModelOutputFallsBackInsteadOfDiscardingSpeech() {
        XCTAssertThrowsError(try TextRules.validateCleanup(original: "ciao", result: ""))
        XCTAssertThrowsError(try TextRules.validateCleanup(original: "ciao", result: "<think>reasoning</think>"))
    }
}
