import XCTest
@testable import VerbCore

final class InteractionTests: XCTestCase {
    func testSpaceFinishesHandsFreeOnceAndSwallowsRepeatAndRelease() {
        var stop = HandsFreeStop()
        let press = stop.handle(keyCode: 49, down: true, modified: false, repeated: false, active: true)
        XCTAssertTrue(press.consume); XCTAssertTrue(press.finish)
        let repeated = stop.handle(keyCode: 49, down: true, modified: false, repeated: true, active: false)
        XCTAssertTrue(repeated.consume); XCTAssertFalse(repeated.finish)
        let release = stop.handle(keyCode: 49, down: false, modified: false, repeated: false, active: false)
        XCTAssertTrue(release.consume); XCTAssertFalse(release.finish)
        XCTAssertFalse(stop.handle(keyCode: 49, down: true, modified: false, repeated: false, active: false).consume)
    }
    func testSpacePassesThroughOutsideHandsFreeAndPreservesModifiedShortcuts() {
        for (modified, repeated, active) in [(false, false, false), (true, false, true), (false, true, true)] {
            var stop = HandsFreeStop()
            XCTAssertFalse(stop.handle(keyCode: 49, down: true, modified: modified, repeated: repeated, active: active).consume)
        }
        var stop = HandsFreeStop()
        XCTAssertFalse(stop.handle(keyCode: 53, down: true, modified: false, repeated: false, active: true).consume)
        XCTAssertFalse(stop.handle(keyCode: 49, down: false, modified: false, repeated: false, active: true).finish)
    }
    func testKeysForHoldingAcceptFnAloneOrSeveralModifiers() {
        XCTAssertNil(KeyBinding.fn.problem(hold: true))
        XCTAssertNil(KeyBinding.controlOption.problem(hold: true))
        XCTAssertNil(KeyBinding(modifiers: [.control, .option, .command], label: "⌃ ⌥ ⌘").problem(hold: true))
        XCTAssertNil(KeyBinding(modifiers: [.control, .option], keyCode: 2, label: "⌃ ⌥ D").problem(hold: true))
        XCTAssertNil(KeyBinding(modifiers: [], keyCode: 96, label: "F5").problem(hold: true), "a function key alone is fine")
        XCTAssertEqual(KeyBinding(modifiers: [.option], label: "⌥").problem(hold: true), .singleModifier, "⌥ alone types @ and # on an Italian keyboard")
        XCTAssertEqual(KeyBinding(modifiers: [.command], label: "⌘").problem(hold: true), .singleModifier)
        XCTAssertEqual(KeyBinding(modifiers: [], keyCode: 2, label: "D").problem(hold: true), .needsModifier)
        XCTAssertEqual(KeyBinding(modifiers: [.shift], keyCode: 2, label: "⇧ D").problem(hold: true), .needsModifier)
        XCTAssertEqual(KeyBinding(modifiers: [], keyCode: 49, label: "Space").problem(hold: true), .needsModifier)
        XCTAssertEqual(KeyBinding(modifiers: [.function, .control], keyCode: 2, label: "fn ⌃ D").problem(hold: true), .functionWithKey)
    }

    func testKeysForPressingNeedAKeyAndStayClearOfMacOSAndTransforms() {
        XCTAssertNil(KeyBinding.shiftCommandC.problem(hold: false))
        XCTAssertNil(KeyBinding.controlCommandV.problem(hold: false))
        XCTAssertEqual(KeyBinding.controlOption.problem(hold: false), .needsKey, "copying happens once, so it needs a key")
        XCTAssertEqual(KeyBinding(modifiers: [.command], keyCode: 8, label: "⌘ C").problem(hold: false), .reserved)
        XCTAssertEqual(KeyBinding(modifiers: [.command], keyCode: 49, label: "⌘ Space").problem(hold: false), .reserved)
        XCTAssertEqual(KeyBinding(modifiers: [.control], keyCode: 49, label: "⌃ Space").problem(hold: false), .reserved)
        XCTAssertNil(KeyBinding.transformDigit(0).problem(hold: false), "⌃⌥1 is an ordinary combination now; transforms own it only by holding it")
    }

    func testKeysChosenForOneCommandAreTakenFromTheOneThatHadThem() {
        var keys = KeyBindings(), transforms = Transform.defaults
        let polish = transforms[0].id, concise = transforms[1].id
        // ⇧⌘C moves from copying to the first transform.
        KeyBindings.assign(.shiftCommandC, to: .transform(polish), keys: &keys, transforms: &transforms)
        XCTAssertNil(keys.copyLast)
        XCTAssertEqual(transforms[0].keys, .shiftCommandC)
        XCTAssertEqual(KeyBindings.owner(of: .shiftCommandC, keys: keys, transforms: transforms), .transform(polish))
        // ⌃⌥2 moves from the second transform to pasting.
        KeyBindings.assign(.transformDigit(1), to: .pasteLast, keys: &keys, transforms: &transforms)
        XCTAssertNil(transforms[1].keys)
        XCTAssertEqual(keys.pasteLast, .transformDigit(1))
        // The same keys written another way are the same keys.
        KeyBindings.assign(KeyBinding(modifiers: [.control, .option], keyCode: 19, label: "⌃ ⌥ @"), to: .transform(concise), keys: &keys, transforms: &transforms)
        XCTAssertNil(keys.pasteLast)
        // Taking keys away leaves the command without any, and nobody else changes.
        KeyBindings.assign(nil, to: .dictation, keys: &keys, transforms: &transforms)
        XCTAssertNil(keys.dictation)
        XCTAssertEqual(keys.voiceEdit, .controlOption)
        XCTAssertEqual(transforms[2].keys, .transformDigit(2))
    }

    func testCommandsLeftWithoutKeysStayThatWay() throws {
        var keys = KeyBindings(); keys.copyLast = nil
        let decoded = try JSONDecoder().decode(KeyBindings.self, from: JSONEncoder().encode(keys))
        XCTAssertNil(decoded.copyLast, "no keys on purpose is remembered")
        XCTAssertEqual(decoded.pasteLast, .controlCommandV)
        let partial = try JSONDecoder().decode(KeyBindings.self, from: Data(#"{"dictation":{"label":"F5","modifiers":0,"keyCode":96}}"#.utf8))
        XCTAssertEqual(partial.dictation?.label, "F5")
        XCTAssertEqual(partial.voiceEdit, .controlOption, "an entry that isn't there gets its standard keys")
    }

    func testTransformsWithoutKeysGetTheDigitsByPosition() throws {
        let saved = Data(#"{"vocabulary":[],"snippets":[],"transforms":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"A","instruction":"a"},{"id":"7F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"B","instruction":"b"}]}"#.utf8)
        let library = try JSONDecoder().decode(Library.self, from: saved)
        XCTAssertEqual(library.transforms.map(\.keys), [.transformDigit(0), .transformDigit(1)])
        XCTAssertEqual(library.keysVersion, 1)
        // Once saved, a transform left without keys stays without.
        var chosen = library; chosen.transforms[1].keys = nil
        XCTAssertNil(try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(chosen)).transforms[1].keys)
        XCTAssertEqual(chosen.freeTransformKeys(keys: KeyBindings()), .transformDigit(1))
    }

    func testWordsPerMinuteCountOnlyDictations() {
        let dictation = DictationRecord(duration: 30, rawText: "", text: Array(repeating: "parola", count: 75).joined(separator: " "), appName: "Mail", mode: .dictation, status: .completed)
        let edit = DictationRecord(duration: 10, rawText: "", text: "breve", appName: "Mail", mode: .command, status: .completed)
        let imported = DictationRecord(duration: 60, rawText: "", text: "una registrazione", appName: "Audio import", mode: .dictation, status: .completed)
        let failed = DictationRecord(duration: 20, rawText: "", text: "", appName: "Mail", mode: .dictation, status: .failed)
        let stats = DictationStats(history: [dictation, edit, imported, failed])
        XCTAssertEqual(stats.dictations, 1)
        XCTAssertEqual(stats.words, 75)
        XCTAssertEqual(stats.wordsPerMinute ?? 0, 150, accuracy: 0.001)
        XCTAssertNil(DictationStats(words: 5, seconds: 10, dictations: 1).wordsPerMinute, "too little to say")
    }

    func testSettingsWithoutKeysGetTheStandardOnesAndIgnoreUnknownFields() throws {
        // No "keys" group, and fields Verb doesn't know: the keys are the standard ones.
        let saved = Data("""
        {"version":1,"speechProvider":"onDevice","localModel":"parakeet-v3","language":"it","cleanupProvider":"off","cleanupModel":"qwen3:4b","speechEndpoint":"","speechModel":"","cleanupEndpoint":"","hostedCleanupModel":"","allowRemoteProcessing":false,"style":"natural","appStyles":{},"retention":30,"keepAudio":true,"autoInsert":true,"soundFeedback":true,"microphoneID":"","unknownField":{"keyCode":49},"anotherUnknownField":true,"onboardingComplete":true}
        """.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: saved)
        XCTAssertEqual(settings.keyOptions, KeyBindings())
        XCTAssertEqual(settings.keyOptions.dictation, .fn)
        XCTAssertEqual(settings.keyOptions.voiceEdit, .controlOption)
        XCTAssertEqual(settings.keyOptions.copyLast?.label, "⇧ ⌘ C")
        XCTAssertEqual(settings.language, .it)
        var chosen = settings; chosen.keyOptions.dictation = KeyBinding(modifiers: [], keyCode: 96, label: "F5")
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(chosen)).keyOptions.dictation?.label, "F5")
    }

    func testSpeechChunksCoverAllSamplesAndChooseQuietBoundary() {
        let rate = 1000
        var samples = [Float](repeating: 0.25, count: rate * 73)
        samples.replaceSubrange(25000..<26000, with: repeatElement(Float(0), count: 1000))
        let chunks = SpeechChunking.ranges(samples: samples, sampleRate: rate)
        XCTAssertEqual(chunks.first?.lowerBound, 0); XCTAssertEqual(chunks.last?.upperBound, samples.count)
        XCTAssertTrue((25000..<26000).contains(chunks[0].upperBound))
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= rate * 28 })
        for pair in zip(chunks, chunks.dropFirst()) { XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound) }
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.count }, samples.count)
        XCTAssertTrue(SpeechChunking.ranges(samples: [], sampleRate: rate).isEmpty)
    }
    func testMLXModelManifestIsPinnedAndRejectsArbitraryPaths() throws {
        XCTAssertEqual(Settings().localModel, SpeechCatalog.defaultID)
        XCTAssertThrowsError(try SpeechCatalog.model("../../private"))
        for model in SpeechCatalog.models {
            XCTAssertEqual(model.revision.count, 40)
            XCTAssertTrue(model.files.contains { $0.name == "config.json" })
            XCTAssertTrue(model.files.filter { $0.name.hasSuffix(".safetensors") }.allSatisfy { $0.sha256?.count == 64 && $0.bytes > 0 })
        }
    }
}
