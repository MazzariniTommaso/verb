import XCTest
@testable import VerbCore

/// What Verb keeps on disk: files it can't fully read, the audio kept for Retry, the transforms
/// it starts with and what it remembers of your corrections.
final class DataTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("verb-data-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testSettingsWithAValueThisBuildDoesntKnowKeepEverythingElse() throws {
        var saved = Settings(); saved.language = .it; saved.retention = .week; saved.overlayStyle = .dot
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        json["overlay"] = "wave"
        json["cleanupProvider"] = "somewhere-new"
        json.removeValue(forKey: "keepAudio")
        let url = folder.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = try JSONStore.load(Settings.self, from: url, fallback: Settings())
        XCTAssertEqual(loaded.language, .it); XCTAssertEqual(loaded.retention, .week)
        XCTAssertEqual(loaded.overlayStyle, Settings().overlayStyle)
        XCTAssertEqual(loaded.cleanupProvider, Settings().cleanupProvider)
        XCTAssertEqual(loaded.keepAudio, Settings().keepAudio)
        // The file as it was stays beside it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path))
    }

    func testALibraryEntryThatCantBeReadIsLeftOutAndTheRestKept() throws {
        var library = Library(); library.vocabulary = [VocabularyEntry(word: "Verb"), VocabularyEntry(word: "MLX")]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as! [String: Any]
        var words = json["vocabulary"] as! [[String: Any]]
        words[0]["id"] = "not a uuid"
        json["vocabulary"] = words
        let url = folder.appendingPathComponent("library.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = try JSONStore.load(Library.self, from: url, fallback: Library())
        XCTAssertEqual(loaded.vocabulary.map(\.word), ["MLX"])
        XCTAssertEqual(loaded.transforms.count, library.transforms.count)
    }

    func testAFileThatIsntJSONStillFailsAndIsLeftAlone() throws {
        let url = folder.appendingPathComponent("settings.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try JSONStore.load(Settings.self, from: url, fallback: Settings()))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
    }

    func testAFailedDictationKeepsItsRecordingWhenAudioIsntKept() throws {
        let paths = try DataPaths(root: folder)
        let store = try HistoryStore(paths: paths)
        let failed = DictationRecord(status: .failed, audioName: UUID().uuidString + ".wav"), done = DictationRecord(status: .completed, audioName: UUID().uuidString + ".wav")
        for record in [failed, done] { try Data([1, 2, 3]).write(to: paths.audio.appendingPathComponent(record.audioName!)); try store.save(record) }
        try store.prune(retention: .month, keepAudio: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.audio.appendingPathComponent(failed.audioName!).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.audio.appendingPathComponent(done.audioName!).path))
        // It still expires with the others.
        try store.prune(retention: .month, keepAudio: false, now: Date().addingTimeInterval(15 * 86400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.audio.appendingPathComponent(failed.audioName!).path))
    }

    func testRecordingsAndHistoryAreReadableByYouOnly() throws {
        let paths = try DataPaths(root: folder)
        _ = try HistoryStore(paths: paths)
        let recording = paths.audio.appendingPathComponent("take.wav")
        try Data([0]).write(to: recording)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: recording.path)
        _ = try DataPaths(root: folder)
        for url in [recording, folder.appendingPathComponent("history.sqlite")] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, url.lastPathComponent)
        }
    }

    func testVerbsOwnTransformsFollowTheLanguageAndEditedOnesStay() {
        XCTAssertEqual(Library(italian: true).transforms.map(\.name), ["Rifinisci", "Rendi conciso", "Traduci in italiano", "Traduci in inglese"])
        var library = Library(italian: false)
        library.transforms.append(Transform(name: "Polish", instruction: "Mine, rewritten."))
        library.transforms[1].instruction = "Shorter, my way."
        let keys = library.transforms.map(\.keys)
        library.localizeStandardTransforms(italian: true)
        XCTAssertEqual(library.transforms.map(\.name), ["Rifinisci", "Make concise", "Traduci in italiano", "Traduci in inglese", "Polish"])
        XCTAssertEqual(library.transforms.map(\.keys), keys)
        library.localizeStandardTransforms(italian: false)
        XCTAssertEqual(library.transforms[0].name, "Polish"); XCTAssertEqual(library.transforms[3].name, "Translate into English")
        // A library written before the names were paired: “Translate to English” and an Italian name with an English prompt.
        var mixed = Library(italian: false)
        mixed.transforms[2].name = "Traduci in italiano"; mixed.transforms[3].name = "Translate to English"
        mixed.localizeStandardTransforms(italian: true)
        XCTAssertEqual(mixed.transforms[2].instruction, Transform.defaults(italian: true)[2].instruction)
        XCTAssertEqual(mixed.transforms[3].name, "Traduci in inglese")
    }

    func testMissingTransformsAreFoundUnderEitherLanguage() {
        var library = Library(italian: true)
        XCTAssertTrue(Transform.missing(from: library.transforms, italian: true).isEmpty)
        XCTAssertTrue(Transform.missing(from: library.transforms, italian: false).isEmpty, "Italian names count in English too")
        library.transforms.remove(at: 1)
        XCTAssertEqual(Transform.missing(from: library.transforms, italian: true).map(\.name), ["Rendi conciso"])
        XCTAssertEqual(Transform.missing(from: library.transforms, italian: false).map(\.name), ["Make concise"])
    }

    func testATurnedDownSuggestionIsRememberedOnlyAsADigest() throws {
        let key = Library.ignoreKey(heard: "Tomaso", word: "Tommaso")
        XCTAssertFalse(key.contains("Tommaso")); XCTAssertEqual(key, Library.ignoreKey(heard: "tomaso", word: "Tommaso"))
        let json = #"{"ignored": ["tomaso→Tommaso"]}"#
        let library = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        XCTAssertEqual(library.ignored, [key])
    }

    func testSpaceCantHoldADictation() {
        XCTAssertEqual(KeyBinding(modifiers: [.option], keyCode: 49, label: "⌥ Space").problem(hold: true), .spaceIsHandsFree)
        XCTAssertNotEqual(KeyBinding(modifiers: [.option, .command], keyCode: 49, label: "⌥ ⌘ Space").problem(hold: false), .spaceIsHandsFree)
    }

    func testRecordsWithoutTheHandsFreeMarkStillDecode() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DictationRecord(handsFree: true))) as! [String: Any]
        json.removeValue(forKey: "handsFree")
        let record = try JSONDecoder().decode(DictationRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(record.handsFree)
    }
}
