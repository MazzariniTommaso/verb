import XCTest
@testable import VerbCore

/// Code said out loud: project names, case commands and file mentions.
final class CodeSpeechTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("verb-code-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/lib"), withIntermediateDirectories: true)
        try "// swift-tools-version:5.9".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        final class AppModel {
            var userId = 1
            let retryCount = 2
            var isOpen = false
            var user_name = ""
            func loadUserProfile() { print(userId, isOpen, AppModel.self) }
        }
        """.write(to: root.appendingPathComponent("Sources/App/AppModel.swift"), atomically: true, encoding: .utf8)
        try "export const maxRetries = 3; console.log(maxRetries + 1)".write(to: root.appendingPathComponent("src/index.ts"), atomically: true, encoding: .utf8)
        try "export const hiddenThing = 1; hiddenThing".write(to: root.appendingPathComponent("node_modules/lib/skip.ts"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTheProjectIsReadWithoutItsDependencies() {
        let index = CodeSpeech.index(root: root)
        XCTAssertEqual(Set(index.files), ["Package.swift", "Sources/App/AppModel.swift", "src/index.ts"])
        for name in ["AppModel", "userId", "retryCount", "loadUserProfile", "user_name", "maxRetries", "isOpen"] { XCTAssertNotNil(index.identifiers[name], name) }
        XCTAssertNil(index.identifiers["hiddenThing"], "node_modules is skipped")
        XCTAssertNil(index.identifiers["print"], "plain words are speech already")
        XCTAssertEqual(CodeSpeech.root(of: root.appendingPathComponent("Sources/App/AppModel.swift"))?.standardizedFileURL.path, root.standardizedFileURL.path)
    }

    func testProjectNamesAndFilesSaidAsWords() {
        let index = CodeSpeech.index(root: root)
        let found = CodeSpeech.replacements(in: "apri app model punto swift e cambia user id qui", index: index, mentionPaths: false)
        XCTAssertEqual(found.map(\.spoken), ["app model punto swift", "user id"])
        XCTAssertEqual(found.map(\.code), ["AppModel.swift", "userId"])
        XCTAssertEqual(CodeSpeech.replacements(in: "tag index dot ts", index: index, mentionPaths: true).map(\.code), ["@src/index.ts"])
        XCTAssertEqual(CodeSpeech.replacements(in: "tag index dot ts", index: index, mentionPaths: false).map(\.code), ["@index.ts"])
        XCTAssertEqual(CodeSpeech.replacements(in: "guarda @index.ts", index: index, mentionPaths: true).map(\.code), ["@src/index.ts"])
        XCTAssertEqual(CodeSpeech.replacements(in: "apri appmodel.swift", index: index, mentionPaths: false).map(\.code), ["AppModel.swift"])
        XCTAssertEqual(CodeSpeech.replacements(in: "the door is open now", index: index, mentionPaths: false).count, 0, "a phrase with a small linking word stays speech")
        XCTAssertEqual(CodeSpeech.replacements(in: "controlla appmodel", index: index, mentionPaths: false).map(\.code), ["AppModel"])
    }

    func testAProjectIsFoundFromAPathWithDots() {
        let expected = root.standardizedFileURL.path
        XCTAssertEqual(CodeSpeech.root(of: URL(fileURLWithPath: root.path + "/Sources/App/..", isDirectory: true))?.standardizedFileURL.path, expected)
        XCTAssertEqual(CodeSpeech.root(of: root.appendingPathComponent("Sources/App/../App/AppModel.swift"))?.standardizedFileURL.path, expected)
    }

    func testProseInEditorsStaysProse() throws {
        try "func setUp() { logIn(); setUp(); logIn() }".write(to: root.appendingPathComponent("Sources/App/Session.swift"), atomically: true, encoding: .utf8)
        let index = CodeSpeech.index(root: root)
        let ordinary: (String) -> Bool = { ["finish", "the", "setup", "before", "login", "grazie", "user", "id", "controlla", "cambia"].contains($0) }
        XCTAssertEqual(CodeSpeech.replacements(in: "Finish the setup before the login.", index: index, mentionPaths: false, isOrdinary: ordinary).count, 0, "one common word stays a word")
        XCTAssertEqual(CodeSpeech.replacements(in: "cambia user id qui", index: index, mentionPaths: false, isOrdinary: ordinary).map(\.code), ["userId"], "several words make the name")
        XCTAssertEqual(CodeSpeech.replacements(in: "controlla appmodel", index: index, mentionPaths: false, isOrdinary: ordinary).map(\.code), ["AppModel"])
        XCTAssertEqual(CodeSpeech.replacements(in: "Look at index dot ts", index: index, mentionPaths: false).map(\.code), ["index.ts"], "in an editor “at” is a word")
        XCTAssertEqual(CodeSpeech.replacements(in: "Look at index dot ts", index: index, mentionPaths: true).map(\.code), ["@src/index.ts"])
        XCTAssertEqual(CodeSpeech.replacements(in: "Handle the constant case first.", index: nil, mentionPaths: false).count, 0, "a case spoken about")
        XCTAssertEqual(CodeSpeech.replacements(in: "Metti tutto in snake case grazie", index: nil, mentionPaths: false, isOrdinary: ordinary).count, 0)
    }

    func testCaseCommandsWorkWithoutAProject() {
        XCTAssertEqual(CodeSpeech.replacements(in: "camel case max size, poi", index: nil, mentionPaths: false).map(\.code), ["maxSize"])
        XCTAssertEqual(CodeSpeech.replacements(in: "snake case retry count e basta", index: nil, mentionPaths: false).map(\.code), ["retry_count"])
        XCTAssertEqual(CodeSpeech.replacements(in: "pascal case user profile view", index: nil, mentionPaths: false).map(\.code), ["UserProfileView"])
        XCTAssertEqual(CodeSpeech.replacements(in: "constant case max retries", index: nil, mentionPaths: false).map(\.code), ["MAX_RETRIES"])
        XCTAssertEqual(CodeSpeech.replacements(in: "kebab case main menu bar", index: nil, mentionPaths: false).map(\.code), ["main-menu-bar"])
    }
}
