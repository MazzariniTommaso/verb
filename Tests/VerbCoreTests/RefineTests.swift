import XCTest
@testable import VerbCore

/// The rules that run on every dictation with no model, and the test that decides when the
/// writing model is worth its wait.
final class RefineTests: XCTestCase {
    func testQuickRulesTakeOutHesitationsAndStumbles() {
        XCTAssertEqual(TextRules.quickClean("Ehm, allora il il report è pronto."), "Allora il report è pronto.")
        XCTAssertEqual(TextRules.quickClean("I think, uhm, the the meeting is at five ."), "I think, the meeting is at five.")
        XCTAssertEqual(TextRules.quickClean("Ci vediamo  domani ,  mmm, alle dieci."), "Ci vediamo domani, alle dieci.")
        XCTAssertEqual(TextRules.quickClean("Uhm"), "")
    }

    func testQuickRulesLeaveMeaningfulWordsAlone() {
        for text in ["No no, è molto molto bello.", "Eh sì, cioè, ci penso io.", "Hummus e umami.", "Termina alle 10, ermetico.", "Ci vediamo alle 10."] {
            XCTAssertEqual(TextRules.quickClean(text), text, text)
        }
        XCTAssertEqual(TextRules.quickClean("scrivi a Marco"), "scrivi a Marco", "a lowercase start stays lowercase")
    }

    func testFillersGoWithoutBreakingTheSentence() {
        XCTAssertEqual(TextRules.quickClean("Ok. Ehm, allora andiamo."), "Ok. Allora andiamo.", "the next word takes the capital of the filler that opened the sentence")
        XCTAssertEqual(TextRules.quickClean("I think so, um."), "I think so.")
        XCTAssertEqual(TextRules.quickClean("I think so, um"), "I think so")
        XCTAssertEqual(TextRules.quickClean("Va bene um. Poi andiamo."), "Va bene. Poi andiamo.")
        XCTAssertEqual(TextRules.quickClean("Ehm, uhm, allora sì."), "Allora sì.")
        XCTAssertEqual(TextRules.quickClean("Allora, ehm... andiamo."), "Allora, andiamo.", "an ellipsis before a small letter is part of the hesitation")
        XCTAssertEqual(TextRules.quickClean("Va bene um… Poi andiamo."), "Va bene. Poi andiamo.")
        XCTAssertEqual(TextRules.quickClean("Uh-huh, that works for me."), "Uh-huh, that works for me.", "a hyphen makes it a word")
        XCTAssertEqual(TextRules.quickClean("Um-hmm, sounds good."), "Um-hmm, sounds good.")
    }

    func testDoublingsOnPurposeAndDotWordsStay() {
        for text in ["I know that that is true.", "What it is is a problem.", "We use .NET and the .env file."] {
            XCTAssertEqual(TextRules.quickClean(text), text, text)
        }
    }

    func testLineCommandsOnlyWhenSaidAsCommands() {
        XCTAssertEqual(TextRules.commandPunctuation("Ciao Marco, a capo, ci vediamo domani."), "Ciao Marco,\nci vediamo domani.")
        XCTAssertEqual(TextRules.commandPunctuation("First point. New line. Second point."), "First point.\nSecond point.")
        XCTAssertEqual(TextRules.commandPunctuation("Per oggi è tutto, fine. Nuovo paragrafo. Poi parliamo del resto."), "Per oggi è tutto, fine.\n\nPoi parliamo del resto.")
        for prose in ["Marco è a capo del progetto.", "Add a new line at the end of the file.", "Aggiungi un nuovo paragrafo sul budget.", "We are launching a new line of shoes.",
                      "Chi è a capo dell’azienda?", "Sono a capo di tutto.", "Serve un nuovo paragrafo di testo.", "Il testo va a capo da solo."] {
            XCTAssertEqual(TextRules.commandPunctuation(prose), prose, prose)
        }
    }

    func testTheModelIsCalledForCorrectionsListsAndLongPassages() {
        XCTAssertTrue(TextRules.needsRefinement("Ci vediamo alle cinque, anzi alle sei."))
        XCTAssertTrue(TextRules.needsRefinement("Porto il vino, no scusa, porto la birra."))
        XCTAssertTrue(TextRules.needsRefinement("Cioè no, facciamo giovedì."))
        XCTAssertTrue(TextRules.needsRefinement("Let's meet at five, actually at six."))
        XCTAssertTrue(TextRules.needsRefinement("Scratch that, send it tomorrow."))
        XCTAssertTrue(TextRules.needsRefinement(Array(repeating: "parola", count: 81).joined(separator: " ")))
        XCTAssertFalse(TextRules.needsRefinement("Ci vediamo alle cinque davanti all'ufficio."))
        XCTAssertFalse(TextRules.needsRefinement("Send the report to Anna before lunch."))
        XCTAssertFalse(TextRules.needsRefinement("Stanzai i fondi per la manutenzione."), "a cue inside another word does not count")
        XCTAssertFalse(TextRules.needsRefinement(Array(repeating: "parola", count: 80).joined(separator: " ")))
    }
}
