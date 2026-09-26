import XCTest
@testable import VerbCore

/// The transcripts below are what Parakeet v3 wrote for the macOS voices saying the phrases,
/// captured with `verb-check listen`. They are the spellings Verb meets in practice: first for
/// "Ehi Verb", then for "Ehi Verba", the name said with a vowel at the end.
final class VoiceTests: XCTestCase {
    private let segment = VoiceActivity.Segment(start: 100, end: 900)

    func testEhiVerbStartsADictationInEverySpellingHeard() {
        // Mid-utterance, with words after the phrase: record from the start, so they are kept.
        for text in ["Hey verb, send the report.", "Ei verb scrive a Marco", "E i verb scrivi a Marco che arriva.", "Hey Verb, send a report to Anna before leaving.",
                     "Ej verba scrivi.", "Hey Verba, send the", "E i verba scrivi a Marco"] {
            XCTAssertEqual(VoiceCommands.decide(text, after: .continuing(segment), recording: false), .wake(from: 100), text)
        }
        // After the pause, the phrase on its own: record from its end.
        for text in ["Hey verb.", "Ei verb.", "A verb.", "Everb", "Averb", "E verbo.", "E i verba.", "Eh verba.", "Hey Varaba.", "Verba.", "Ehiverb"] {
            XCTAssertEqual(VoiceCommands.decide(text, after: .ended(segment), recording: false), .wake(from: 900), text)
        }
        // Followed by words, once the utterance is over.
        XCTAssertEqual(VoiceCommands.decide("Hey verb, send the report to Anna before lunch.", after: .ended(segment), recording: false), .wake(from: 100))
        XCTAssertEqual(VoiceCommands.decide("I Verba scrivi a Marco che arrivo tra dieci minuti.", after: .ended(segment), recording: false), .wake(from: 100))
        // At the end of a longer utterance, after it.
        XCTAssertEqual(VoiceCommands.decide("Allora, vediamo cosa scrivere, ehi Verb.", after: .ended(segment), recording: false), .wake(from: 900))
    }

    func testThePhraseAloneMidUtteranceWaitsForThePause() {
        // Starting now could cut into a word that has only just begun.
        for text in ["Ei verb.", "Hey verb", "Ej verba.", "El verba"] {
            XCTAssertEqual(VoiceCommands.decide(text, after: .continuing(segment), recording: false), .none, text)
        }
        // The pause then starts it, even when its own reading comes out garbled.
        var reader = VoiceCommands.Reader()
        XCTAssertEqual(reader.read("El verba", after: .continuing(segment), recording: false), .none)
        XCTAssertEqual(reader.read("L verba", after: .ended(segment), recording: false), .wake(from: 900))
        // A different utterance gets no such help.
        XCTAssertEqual(reader.read("El verba", after: .continuing(segment), recording: false), .none)
        XCTAssertEqual(reader.read("L verba", after: .ended(VoiceActivity.Segment(start: 2000, end: 3000)), recording: false), .none)
        // "Ehi Verb stop" said while nothing records is not a wake.
        XCTAssertEqual(reader.read("Ei verb.", after: .continuing(segment), recording: false), .none)
        XCTAssertEqual(reader.read("Ei verb stop.", after: .ended(segment), recording: false), .none)
    }

    func testOrdinarySpeechNeverWakesVerb() {
        let heard = ["A verb describes an action.", "The verb stop is irregular in some languages.", "Il verbo è la parte più importante della frase.", "E. Verbale approvato.",
                     "E verbalmente ha detto di sì.", "E vera, vieni qui.", "Hey Vera, send me the file.", "Ei, ver.", "A verb, send the report to Anna before lunch.",
                     "Run is a verb.", "Ehi Marco, vieni a vedere questo.", "I verbi irregolari sono difficili.", "E i verbi irregolari sono difficili.", "L'erba del vicino è sempre più verde.",
                     "Verba volant, skripta manent.", "E verbalizziamo tutto alla fine.", "Ho parlato con la Serbia ieri.", "O, verbale approvato.", "Oh, verbal.", "E basta così.",
                     "Hey guys, the meeting is at 3.", "Hey, verbal agreements are not enough.", "I saw herb garden.", "Hey Barbara, send me a file.",
                     "Allora, vediamo un attimo cosa scrivere, e riverba.", "Verba stop.", "Ej verba, stop.", "Hey verb stop.", ""]
        for text in heard {
            for event in [VoiceActivity.Event.continuing(segment), .ended(segment)] {
                XCTAssertEqual(VoiceCommands.decide(text, after: event, recording: false), .none, text)
            }
        }
    }

    func testCommandsAtTheEndFinishOrCancelARecording() {
        let finishes = ["Che arrivo tra 10 minuti. E i verb stop.", "report to Anna before lunch. Hey verb send.", "Be there in ten minutes. Averb stop.", "Que arrivo tra 10 minuti. Ei verbo stop.",
                        "Subito e che porto i documenti. E i verbi in via.", "E che porto in documenti. E verb in via.", "Anna before lunch. Averb sends.", "Documenti firmati e i verb interrompi la trascrizione.",
                        "Ci vediamo alle tre. Ehi Verb invia.", "Ci vediamo alle tre. Ehi Verb, interrompi la trascrizione.", "A verb stop.",
                        "Marco che arrivo tra 10 minuti. Verba stop.", "The report to Anna before lunch. Verbisend.", "or to Anna before lunch Verbassend.", "Everba stop.", "Varaba stop.",
                        "Verba invia, grazie.", "10 minuti e che porto i documenti. Verba in via.", "E verba stop."]
        for text in finishes { XCTAssertEqual(VoiceCommands.decide(text, after: .ended(segment), recording: true), .finish, text) }
        for text in ["Questo non serve a niente. E i verba nulla.", "Ehi Verb annulla.", "Questo non serve a niente. Verba a nulla.", "Verba annulla."] {
            XCTAssertEqual(VoiceCommands.decide(text, after: .ended(segment), recording: true), .cancel, text)
        }
        // Not commands: Verb with no greeting, a greeting across a sentence break, look-alikes, a command mid-text.
        for text in ["The verb stop is irregular.", "Or to add a before lunch. Verb send.", "Run is a verb. Stop.", "Uso il verbo stop.", "E il verb in via.",
                     "Arrivo tra 10 minuti. Ehi, vero, stop?", "Will it ever stop?", "Verba stop, poi ci pensiamo.", "Ehi Verb scrivi a Marco"] {
            XCTAssertEqual(VoiceCommands.decide(text, after: .ended(segment), recording: true), .none, text)
        }
        // Only a pause ends an utterance, so only a pause is checked.
        XCTAssertEqual(VoiceCommands.decide("Ehi Verb stop.", after: .continuing(segment), recording: true), .none)
    }

    func testOrdinaryEndingsAreNotCommands() {
        // "i" and "e i" inside a sentence are words, and "verbi" the plural: a weak greeting counts only before the name itself.
        for text in ["Ho finito di ripassare i verbi, basta.", "Ripassa i nomi e i verbi, basta.", "Non ricordo i verbi, nulla.", "Studia i verbi, stop.", "Ho detto e verbo stop."] {
            XCTAssertEqual(VoiceCommands.decide(text, after: .ended(segment), recording: true), .none, text)
            XCTAssertEqual(VoiceCommands.removingEnding(from: text), text, text)
        }
        XCTAssertEqual(VoiceCommands.decide("Ho ripassato tutto. Ehi verbi, basta.", after: .ended(segment), recording: true), .finish, "a strong greeting takes every form of the name")
        XCTAssertEqual(VoiceCommands.decide("Ho ripassato tutto, e verb stop.", after: .ended(segment), recording: true), .finish)
        XCTAssertEqual(VoiceCommands.decide("Scrivi a Marco, ok Jarvis fatto.", after: .ended(segment), recording: true, using: VoiceCommands.Phrases(name: "Jarvis", finishWords: ["fatto"])), .finish)
    }

    func testTheCommandsNeverReachTheText() {
        XCTAssertEqual(VoiceCommands.removingWake(from: "Hey verb, send the report to Anna before lunch."), "Send the report to Anna before lunch.")
        XCTAssertEqual(VoiceCommands.removingWake(from: "E i verb scrivi a Marco che arrivo subito."), "Scrivi a Marco che arrivo subito.")
        XCTAssertEqual(VoiceCommands.removingWake(from: "Averb, send the report."), "Send the report.")
        XCTAssertEqual(VoiceCommands.removingWake(from: "Ei verb scrive a Marco"), "Scrive a Marco")
        XCTAssertEqual(VoiceCommands.removingWake(from: "E i verba. Questo non serve a niente"), "Questo non serve a niente")
        XCTAssertEqual(VoiceCommands.removingWake(from: "Evi verba, domani porto i documenti firmati."), "Domani porto i documenti firmati.")
        XCTAssertEqual(VoiceCommands.removingWake(from: "Verba, scrivi a Marco."), "Scrivi a Marco.")
        XCTAssertEqual(VoiceCommands.removingWake(from: "Verb è pronto."), "Verb è pronto.", "Verb alone is a word, not the phrase")
        XCTAssertEqual(VoiceCommands.removingWake(from: "Ci vediamo domani."), "Ci vediamo domani.")

        XCTAssertEqual(VoiceCommands.removingEnding(from: "Scrivi a Marco che arrivo subito e che porto i documenti. E i verb invia."), "Scrivi a Marco che arrivo subito e che porto i documenti.")
        XCTAssertEqual(VoiceCommands.removingEnding(from: "Tell Marco I will be there in 10 minutes. Hey verb stop."), "Tell Marco I will be there in 10 minutes.")
        XCTAssertEqual(VoiceCommands.removingEnding(from: "Send the report to Anna before lunch. Averb, send."), "Send the report to Anna before lunch.")
        XCTAssertEqual(VoiceCommands.removingEnding(from: "Domani porto i documenti firmati, ehi Verb interrompi la trascrizione"), "Domani porto i documenti firmati")
        XCTAssertEqual(VoiceCommands.removingEnding(from: "Scrivi a Marco che arrivo tra 10 minuti, verba stop."), "Scrivi a Marco che arrivo tra 10 minuti.")
        XCTAssertEqual(VoiceCommands.removingEnding(from: "Ciao. Verba stop. Verba stop."), "Ciao.")
        XCTAssertEqual(VoiceCommands.removingEnding(from: "Ehi Verb stop."), "")
        XCTAssertEqual(VoiceCommands.removingEnding(from: "Will it ever stop?"), "Will it ever stop?")
        XCTAssertEqual(VoiceCommands.removingEnding(from: "Uso il verbo stop."), "Uso il verbo stop.")
        let spoken = VoiceCommands.removingEnding(from: VoiceCommands.removingWake(from: "E i verb scrivi a Marco che arrivo tra 10 minuti, ehi verb stop."))
        XCTAssertEqual(spoken, "Scrivi a Marco che arrivo tra 10 minuti.")
    }

    // MARK: Your own phrases

    func testAnotherNameAndOtherWordsReplaceTheStandardOnes() {
        let phrases = VoiceCommands.Phrases(name: "Jarvis", finishWords: ["chiudi", "fatto"], cancelWords: ["lascia perdere"])
        XCTAssertEqual(VoiceCommands.decide("Ehi Jarvis, scrivi a Marco.", after: .ended(segment), recording: false, using: phrases), .wake(from: 100))
        XCTAssertEqual(VoiceCommands.decide("Hey Jarvis.", after: .ended(segment), recording: false, using: phrases), .wake(from: 900))
        XCTAssertEqual(VoiceCommands.decide("Jarvis, scrivi a Marco.", after: .ended(segment), recording: false, using: phrases), .none, "a chosen name always needs the greeting")
        XCTAssertEqual(VoiceCommands.decide("Ehi Verb, scrivi a Marco.", after: .ended(segment), recording: false, using: phrases), .none, "the standard name gives way")
        XCTAssertEqual(VoiceCommands.decide("Scrivi a Marco. Ehi Jarvis chiudi.", after: .ended(segment), recording: true, using: phrases), .finish)
        XCTAssertEqual(VoiceCommands.decide("Scrivi a Marco, ehi Jarvis fatto", after: .ended(segment), recording: true, using: phrases), .finish)
        XCTAssertEqual(VoiceCommands.decide("Ehi Jarvis lascia perdere.", after: .ended(segment), recording: true, using: phrases), .cancel)
        XCTAssertEqual(VoiceCommands.decide("Scrivi a Marco. Ehi Jarvis stop.", after: .ended(segment), recording: true, using: phrases), .none, "stop is no longer one of the words")
        XCTAssertEqual(VoiceCommands.removingEnding(from: "Scrivi a Marco, ehi Jarvis chiudi.", using: phrases), "Scrivi a Marco.")
        XCTAssertEqual(VoiceCommands.removingWake(from: "Ehi Jarvis, scrivi a Marco.", using: phrases), "Scrivi a Marco.")
    }

    func testSeveralNamesAllWork() {
        let phrases = VoiceCommands.Phrases(names: ["Verb", "Jarvis", "Computer"])
        for text in ["Ehi Verb, scrivi a Marco.", "Ehi Jarvis, scrivi a Marco.", "Hey computer, write to Marco.", "Ehi Verba, scrivi a Marco."] {
            XCTAssertEqual(VoiceCommands.decide(text, after: .ended(segment), recording: false, using: phrases), .wake(from: 100), text)
        }
        XCTAssertEqual(VoiceCommands.decide("Scrivi a Marco. Ehi Jarvis stop.", after: .ended(segment), recording: true, using: phrases), .finish)
        XCTAssertEqual(VoiceCommands.decide("Scrivi a Marco. Ehi Verb invia.", after: .ended(segment), recording: true, using: phrases), .finish)
        XCTAssertEqual(VoiceCommands.decide("Ehi computer annulla", after: .ended(segment), recording: true, using: phrases), .cancel)
        XCTAssertEqual(VoiceCommands.decide("Il computer è acceso.", after: .ended(segment), recording: false, using: phrases), .none, "a name needs its greeting")
        XCTAssertEqual(VoiceCommands.removingWake(from: "Ehi Jarvis, scrivi a Marco.", using: phrases), "Scrivi a Marco.")
    }

    func testVoiceSettingsKeepSeveralNamesAndFallBackToVerb() throws {
        let missing = try JSONDecoder().decode(VoicePreferences.self, from: Data("{\"wakeWord\":true}".utf8))
        XCTAssertEqual(missing.names, ["Verb"])
        XCTAssertTrue(missing.wakeWord)
        var several = VoicePreferences(); several.names = ["Jarvis", "Verb"]
        let decoded = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(several))
        XCTAssertEqual(decoded.names, ["Jarvis", "Verb"])
        XCTAssertEqual(decoded.spokenNames, ["Jarvis", "Verb"])
        var empty = VoicePreferences(); empty.names = ["", "  "]
        XCTAssertEqual(empty.spokenNames, ["Verb"], "with no name left, Verb answers")
    }

    func testATaughtSpellingFindsThePhraseAndLeavesOrdinaryWordsAlone() {
        let lesson = VocabularyEntry(word: "Ehi Verb", heardAs: "e verbe")
        let phrases = VoiceCommands.Phrases(vocabulary: [lesson, VocabularyEntry(word: "Kubernetes", heardAs: "cuber netis")])
        XCTAssertEqual(VoiceCommands.decide("E verbe, scrivi a Marco.", after: .ended(segment), recording: false), .none, "unknown before it is taught")
        XCTAssertEqual(VoiceCommands.decide("E verbe, scrivi a Marco.", after: .ended(segment), recording: false, using: phrases), .wake(from: 100))
        XCTAssertEqual(VoiceCommands.decide("Scrivi a Marco. E verbe stop.", after: .ended(segment), recording: true, using: phrases), .finish)
        XCTAssertEqual(VoiceCommands.decide("E verbe annulla", after: .ended(segment), recording: true, using: phrases), .cancel)
        // Found at the edges without applying the lesson to the words in between.
        XCTAssertEqual(VoiceCommands.removingWake(from: "E verbe, scrivi a Marco.", using: phrases), "Scrivi a Marco.")
        XCTAssertEqual(VoiceCommands.removingEnding(from: "Ripassa nomi e verbe. E verbe stop.", using: phrases), "Ripassa nomi e verbe.")
        XCTAssertTrue(phrases.isCommand(lesson))
        XCTAssertTrue(phrases.isCommand(VocabularyEntry(word: "Ehi Verb stop", heardAs: "everbstop")))
        XCTAssertFalse(phrases.isCommand(VocabularyEntry(word: "Kubernetes", heardAs: "cuber netis")))
        XCTAssertFalse(phrases.isCommand(VocabularyEntry(word: "Ehi Verb", heardAs: "")), "a spelling hint with nothing heard teaches nothing")
        XCTAssertEqual(phrases.wording([lesson, VocabularyEntry(word: "Kubernetes", heardAs: "cuber netis")]).map(\.word), ["Kubernetes"])
        // A whole closing phrase taught as one spelling.
        let joined = VoiceCommands.Phrases(vocabulary: [VocabularyEntry(word: "Ehi Verb stop", heardAs: "everest op")])
        XCTAssertEqual(VoiceCommands.removingEnding(from: "Ci vediamo domani. Everest op.", using: joined), "Ci vediamo domani.")
    }

    func testAFailedTryTeachesThePhraseAsTheEngineWroteIt() {
        typealias Lesson = VoiceCommands.Lesson
        XCTAssertEqual(VoiceCommands.lesson(in: "E verbe.", closing: false), Lesson(heard: "e verbe", command: nil))
        XCTAssertEqual(VoiceCommands.lesson(in: "Èverb!", closing: false), Lesson(heard: "èverb", command: nil), "accents stay, because the dictionary matches them as written")
        // A closing lesson keeps its command, so it can only ever close a dictation.
        XCTAssertEqual(VoiceCommands.lesson(in: "Ever stop.", closing: true), Lesson(heard: "ever stop", command: "stop"))
        XCTAssertEqual(VoiceCommands.lesson(in: "E ver be interrompi la trascrizione", closing: true), Lesson(heard: "e ver be interrompi la trascrizione", command: "interrompi la trascrizione"))
        XCTAssertEqual(VoiceCommands.lesson(in: "Everm in via.", closing: true), Lesson(heard: "everm in via", command: "invia"), "a command the engine splits is written as in the settings")
        XCTAssertNil(VoiceCommands.lesson(in: "Everest.", closing: true), "no command at the end")
        XCTAssertNil(VoiceCommands.lesson(in: "Stop.", closing: true), "nothing stands for the name")
        XCTAssertNil(VoiceCommands.lesson(in: "Allora vediamo cosa scrivere oggi.", closing: false), "too long to be the phrase")
        XCTAssertNil(VoiceCommands.lesson(in: "", closing: false))

        // Taught as "Ehi Verb stop", the closing lesson finishes a dictation and starts none.
        let taught = VoiceCommands.Phrases(vocabulary: [VocabularyEntry(word: "Ehi Verb stop", heardAs: "ever stop")])
        XCTAssertEqual(VoiceCommands.decide("Scrivi a Marco che arrivo tra 10 minuti. Ever stop.", after: .ended(segment), recording: true, using: taught), .finish)
        XCTAssertEqual(VoiceCommands.removingEnding(from: "Scrivi a Marco che arrivo tra 10 minuti. Ever stop.", using: taught), "Scrivi a Marco che arrivo tra 10 minuti.")
        XCTAssertEqual(VoiceCommands.decide("Ever scrivi a Marco che arrivo subito.", after: .ended(segment), recording: false, using: taught), .none)
    }

    // MARK: Voice activity

    /// A tone as loud as speech close to the microphone (-23 dBFS), over faint room noise.
    private func signal(_ parts: [(seconds: Double, loud: Bool)], amplitude: Float = 0.1) -> [Float] {
        var seed: UInt32 = 7
        var result: [Float] = []
        for part in parts {
            for index in 0..<Int(part.seconds * 16000) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.001
                result.append(noise + (part.loud ? amplitude * sin(Float(index) * 2 * .pi * 220 / 16000) : 0))
            }
        }
        return result
    }
    private func events(_ samples: [Float], _ activity: inout VoiceActivity) -> [VoiceActivity.Event] {
        stride(from: 0, to: samples.count, by: 683).flatMap { activity.process(Array(samples[$0..<min($0 + 683, samples.count)])) }
    }

    func testAnUtteranceWithAShortPauseIsOneSegmentWithCheckpoints() {
        var activity = VoiceActivity()
        let heard = events(signal([(2, false), (0.6, true), (0.3, false), (0.6, true), (2, false)]), &activity)
        guard case .started(let start) = heard.first, case .ended(let segment) = heard.last else { return XCTFail("\(heard)") }
        XCTAssertEqual(Double(start) / 16000, 2 - 0.25, accuracy: 0.05, "The lead-in keeps the first syllable")
        XCTAssertEqual(Double(segment.end) / 16000, 3.5 + 0.25, accuracy: 0.05, "A quarter second keeps a soft final consonant")
        XCTAssertEqual(heard.filter { if case .started = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(heard.filter { if case .continuing = $0 { return true }; return false }.count, 2, "Checkpoints at 1.0 and 1.8 s")
    }

    func testClicksAndSilenceAreNotSpeech() {
        var activity = VoiceActivity()
        XCTAssertTrue(events(signal([(2, false), (0.04, true), (2, false)]), &activity).isEmpty)
        XCTAssertFalse(activity.speaking)
    }

    func testTheNoiseFloorFollowsTheRoom() {
        // A fan switched on next to the Mac, at -40 dBFS.
        var activity = VoiceActivity()
        let heard = events(signal([(1, false), (12, true)], amplitude: 0.014), &activity)
        guard let ended = heard.firstIndex(where: { if case .ended = $0 { return true }; return false }) else { return XCTFail("A steady sound should stop counting as speech") }
        XCTAssertTrue(heard[(ended + 1)...].isEmpty, "Once the floor has risen, the same sound starts nothing")
    }

    func testRestartForgetsTheUtteranceButKeepsCounting() {
        var activity = VoiceActivity()
        _ = events(signal([(1, false), (0.5, true)]), &activity)
        XCTAssertTrue(activity.speaking)
        let position = activity.position
        activity.restart()
        XCTAssertFalse(activity.speaking)
        XCTAssertTrue(events(signal([(2, false)]), &activity).isEmpty)
        XCTAssertGreaterThan(activity.position, position)
    }

    func testVeryLongSpeechIsCutIntoBoundedPieces() {
        // Speech with the short gaps of real talk, so the floor stays low for half a minute.
        var parts: [(seconds: Double, loud: Bool)] = [(1, false)]
        for _ in 0..<45 { parts += [(0.6, true), (0.1, false)] }
        var activity = VoiceActivity()
        let segments = events(signal(parts), &activity).compactMap { event -> VoiceActivity.Segment? in if case .ended(let segment) = event { return segment }; return nil }
        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(segments.allSatisfy { $0.end - $0.start <= 16000 * 30 + 320 }, "At most 30 seconds, give or take one 20 ms frame")
    }

    func testTheRingReturnsTheRecentPastByPosition() {
        var ring = SampleRing(capacity: 10)
        ring.append((0..<25).map(Float.init))
        XCTAssertEqual(ring.start, 15); XCTAssertEqual(ring.end, 25)
        XCTAssertEqual(ring.samples(from: 12, to: 20), [15, 16, 17, 18, 19])
        XCTAssertEqual(ring.samples(from: 18, to: 99), [18, 19, 20, 21, 22, 23, 24])
        XCTAssertEqual(ring.samples(from: 20, to: 20), [])
        ring.append([25, 26, 27])
        XCTAssertEqual(ring.samples(from: 0, to: 99), (18..<28).map(Float.init))
    }

    // MARK: Settings, records, insertion

    func testSettingsWithoutVoiceGainItsDefaultsAndKeepPartialChoices() throws {
        var saved = Settings(); saved.style = .casual
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(saved))
        XCTAssertNil(decoded.voice)
        XCTAssertFalse(decoded.voiceOptions.wakeWord, "Listening is never on unless chosen")
        XCTAssertTrue(decoded.voiceOptions.stopCommands)
        let partial = try JSONDecoder().decode(VoicePreferences.self, from: Data("{\"wakeWord\":true}".utf8))
        XCTAssertTrue(partial.wakeWord); XCTAssertTrue(partial.stopCommands)
        var chosen = Settings(); chosen.voiceOptions.wakeWord = true; chosen.voiceOptions.stopCommands = false
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(chosen)).voiceOptions, chosen.voiceOptions)
    }

    func testRecordsWithoutTheFieldAreNotStartedByVoice() throws {
        let data = try JSONEncoder().encode(DictationRecord(text: "Ciao"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("startedByVoice"))
        XCTAssertNil(try JSONDecoder().decode(DictationRecord.self, from: data).startedByVoice)
        let voiced = try JSONDecoder().decode(DictationRecord.self, from: JSONEncoder().encode(DictationRecord(text: "Ciao", startedByVoice: true)))
        XCTAssertEqual(voiced.startedByVoice, true)
    }

    func testTextGoesToTheClipboardWhenNothingCanTakeIt() {
        XCTAssertEqual(InsertionPolicy.verdict(hasElement: false, role: nil, hasTextRange: false, bundleID: "com.apple.finder", isVerb: false), .none)
        XCTAssertEqual(InsertionPolicy.verdict(hasElement: true, role: "AXList", hasTextRange: false, bundleID: "com.apple.finder", isVerb: false), .none, "The desktop")
        XCTAssertEqual(InsertionPolicy.verdict(hasElement: true, role: "AXTextField", hasTextRange: true, bundleID: "com.apple.finder", isVerb: false), .textField, "Renaming a file")
        XCTAssertEqual(InsertionPolicy.verdict(hasElement: true, role: "AXTextArea", hasTextRange: true, bundleID: "com.apple.mail", isVerb: true), .none, "Verb’s own window")
        XCTAssertEqual(InsertionPolicy.verdict(hasElement: true, role: "AXTextArea", hasTextRange: false, bundleID: "com.apple.TextEdit", isVerb: false), .textField)
        XCTAssertEqual(InsertionPolicy.verdict(hasElement: true, role: "AXGroup", hasTextRange: true, bundleID: "com.google.Chrome", isVerb: false), .textField, "An editable web area")
        XCTAssertEqual(InsertionPolicy.verdict(hasElement: true, role: "AXWebArea", hasTextRange: false, bundleID: "notion.id", isVerb: false), .unknown)
    }
}
