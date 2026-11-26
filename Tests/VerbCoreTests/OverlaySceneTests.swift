import CoreGraphics
import XCTest
@testable import VerbCore

final class OverlaySceneTests: XCTestCase {
    private func scene(_ change: (inout OverlayFacts) -> Void) -> OverlayScene {
        var facts = OverlayFacts(); change(&facts); return OverlayScene.of(facts)
    }

    func testAtRestOnlyThePointerShowsHowToStart() {
        XCTAssertTrue(scene { _ in }.isEmpty)
        XCTAssertEqual(scene { $0.hovering = true }, OverlayScene(lead: .mark, trail: .key))
    }

    func testRecordingKeepsWordsOffTheRowAndOpensForThem() {
        // Closed: the dot on the left, the time and Stop on the right, nothing else.
        XCTAssertEqual(scene { $0.activity = .recording }, OverlayScene(lead: .recording, trail: .stop))
        XCTAssertEqual(scene { $0.activity = .recording; $0.words = true }.body, .words(edit: false))
        XCTAssertEqual(scene { $0.activity = .recording; $0.mode = .edit; $0.words = true }, OverlayScene(lead: .editing, trail: .stop, body: .words(edit: true)))
        // The last seconds of a hands-free dictation count down on the right.
        XCTAssertEqual(scene { $0.activity = .recording; $0.silenceLeft = 3 }, OverlayScene(lead: .recording, trail: .countdown(3), body: .silence))
        XCTAssertEqual(scene { $0.activity = .recording; $0.armedCancel = true; $0.silenceLeft = 2 }.body, .message)
    }

    func testAQuestionOpensTheBoxAsYouSpeak() {
        XCTAssertEqual(scene { $0.activity = .recording; $0.mode = .ask }, OverlayScene(lead: .recording, trail: .stop, body: .answer))
        XCTAssertEqual(scene { $0.activity = .working; $0.mode = .ask; $0.answer = true }.body, .answer)
        XCTAssertEqual(scene { $0.answer = true }, OverlayScene(lead: .answer, trail: .close, body: .answer))
    }

    func testWorkingIsASymbolWithItsMeaningUnderThePointer() {
        XCTAssertEqual(scene { $0.activity = .working }, OverlayScene(lead: .working))
        XCTAssertEqual(scene { $0.activity = .working; $0.rewriting = true }.lead, .rewriting)
        XCTAssertEqual(scene { $0.activity = .working; $0.hovering = true }.body, .detail)
        XCTAssertEqual(scene { $0.activity = .working; $0.waitBusy = true }.body, .message)
    }

    func testANoFieldDictationWaitsInTheBox() {
        XCTAssertEqual(scene { $0.ending = .notPasted; $0.paste = true }, OverlayScene(lead: .paste, trail: .close, body: .paste))
        XCTAssertEqual(scene { $0.ending = .notPasted; $0.paste = true; $0.pasteCopied = true }.trail, .copied)
        // Closed with ×, the text stays as the last dictation.
        XCTAssertEqual(scene { $0.ending = .notPasted }, OverlayScene(lead: .copied))
    }

    func testEndingsAreSymbolsAndMessagesFade() {
        XCTAssertEqual(scene { $0.ending = .delivered }, OverlayScene(lead: .done(asSaid: false)))
        XCTAssertEqual(scene { $0.ending = .copied }, OverlayScene(lead: .copied))
        XCTAssertEqual(scene { $0.ending = .pasted }, OverlayScene(lead: .pasted))
        XCTAssertEqual(scene { $0.ending = .empty }, OverlayScene(lead: .noSpeech, body: .message))
        XCTAssertEqual(scene { $0.ending = .empty; $0.messageFresh = false }, OverlayScene(lead: .noSpeech))
        XCTAssertEqual(scene { $0.ending = .asSaid }.body, .message)
        // Something to choose stays open with its buttons.
        XCTAssertEqual(scene { $0.ending = .failed }, OverlayScene(lead: .failed, trail: .close, body: .choice))
        XCTAssertEqual(scene { $0.ending = .cancelled; $0.restorable = true }.body, .choice)
        XCTAssertEqual(scene { $0.ending = .cancelled }, OverlayScene(lead: .cancelled))
    }

    func testPromptsComeBeforeAnEnding() {
        XCTAssertEqual(scene { $0.prompt = .meetingOffer; $0.ending = .delivered }, OverlayScene(lead: .call, trail: .close, body: .choice))
        XCTAssertEqual(scene { $0.prompt = .suggestion }.lead, .dictionary)
    }

    func testAMeetingStaysBesideTheNotchAtRest() {
        XCTAssertEqual(scene { $0.meeting = .recording }, OverlayScene(lead: .meeting, trail: .time))
        XCTAssertEqual(scene { $0.meeting = .recording; $0.hovering = true }.body, .detail)
        XCTAssertEqual(scene { $0.meeting = .writing }, OverlayScene(lead: .writingNotes))
        // A dictation during the meeting takes its place.
        XCTAssertEqual(scene { $0.meeting = .recording; $0.activity = .recording }.lead, .recording)
    }
}

final class VoiceDotsTests: XCTestCase {
    func testDotsRestSmallAndGrowWithTheVoice() {
        let silent = VoiceDots.heights(level: 0, time: 1)
        XCTAssertEqual(silent.count, VoiceDots.count)
        XCTAssertTrue(silent.allSatisfy { $0 == 5 })
        for time in stride(from: 0.0, to: 3, by: 0.37) {
            let soft = VoiceDots.heights(level: 0.3, time: time), loud = VoiceDots.heights(level: 0.9, time: time)
            for index in 0..<VoiceDots.count {
                XCTAssertLessThanOrEqual(soft[index], loud[index])
                XCTAssertLessThanOrEqual(loud[index], 18)
                XCTAssertGreaterThanOrEqual(soft[index], 5)
            }
        }
        // Levels out of range are held to it.
        XCTAssertEqual(VoiceDots.heights(level: -1, time: 0), VoiceDots.heights(level: 0, time: 0))
        XCTAssertTrue(VoiceDots.heights(level: 5, time: 0).allSatisfy { $0 <= 18 })
    }
}

final class MenuRoomTests: XCTestCase {
    func testTheRoomIsBetweenTheLastMenuAndTheNotch() {
        // Safari's menus end at 645 pt; the 14-inch MacBook's notch starts at 663.5.
        XCTAssertEqual(MenuRoom.free(menuEnds: [40, 110, 300, 645], notchLeft: 663.5), 10.5)
        // Menus moved past the notch don't count; with none, the whole side is free but the margin.
        XCTAssertEqual(MenuRoom.free(menuEnds: [120, 900], notchLeft: 663.5), 535.5)
        XCTAssertEqual(MenuRoom.free(menuEnds: [], notchLeft: 663.5), 655.5)
        XCTAssertEqual(MenuRoom.free(menuEnds: [663], notchLeft: 663.5), 0)
    }

    func testTheLeftSymbolMovesRightWhenItDoesNotFit() {
        XCTAssertTrue(MenuRoom.leftFits(40, free: 213))
        XCTAssertFalse(MenuRoom.leftFits(40, free: 18))
        XCTAssertTrue(MenuRoom.leftFits(40, free: nil))
    }

    func testThePointerIsNearTheTopOfAScreenWithoutANotch() {
        let screen = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        XCTAssertTrue(IslandGeometry.near(pointer: CGPoint(x: 960, y: 2062), screen: screen, radius: 110))
        XCTAssertTrue(IslandGeometry.near(pointer: CGPoint(x: 1030, y: 2000), screen: screen, radius: 110))
        XCTAssertFalse(IslandGeometry.near(pointer: CGPoint(x: 1100, y: 2062), screen: screen, radius: 110))
        XCTAssertFalse(IslandGeometry.near(pointer: CGPoint(x: 960, y: 1900), screen: screen, radius: 110))
    }
}

final class AskKeysTests: XCTestCase {
    func testTheAskKeysComeWithSettingsSavedBeforeThem() throws {
        // Saved before the ask keys existed: the entry is missing, and the other keys are kept.
        var saved = KeyBindings(); saved.voiceEdit = nil
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        object["ask"] = nil
        let keys = try JSONDecoder().decode(KeyBindings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(keys.ask, .optionCommand)
        XCTAssertNil(keys.voiceEdit)
        // Left without keys on purpose, it stays so.
        var none = KeyBindings(); none.ask = nil
        XCTAssertNil(try JSONDecoder().decode(KeyBindings.self, from: JSONEncoder().encode(none)).ask)
        XCTAssertTrue(KeyTarget.ask.hold)
    }

    func testGivingTheAskKeysToAnotherActionTakesThemAway() {
        var keys = KeyBindings(), transforms: [Transform] = []
        KeyBindings.assign(.optionCommand, to: .dictation, keys: &keys, transforms: &transforms)
        XCTAssertEqual(keys.dictation, .optionCommand)
        XCTAssertNil(keys.ask)
        XCTAssertEqual(KeyBindings.owner(of: .optionCommand, keys: keys, transforms: []), .dictation)
    }

    func testAFollowUpCarriesTheLastQuestions() throws {
        let turns = (1...6).map { Assistant.Turn(question: "q\($0)", answer: String(repeating: "a", count: 1000)) }
        let message = Assistant.userMessage(request: "E il Sole?", near: nil, screen: nil, earlier: turns)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let earlier = try XCTUnwrap(payload["earlier"] as? [[String: String]])
        XCTAssertEqual(earlier.map { $0["question"] }, ["q3", "q4", "q5", "q6"])
        XCTAssertEqual(earlier.first?["answer"]?.count, 800)
        XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Assistant.userMessage(request: "x", near: nil, screen: nil).utf8)) as? [String: Any])["earlier"])
        XCTAssertTrue(Assistant.systemPrompt(personal: nil, place: nil, style: nil, hasContext: false, conversation: true).contains("earlier"))
    }
}
