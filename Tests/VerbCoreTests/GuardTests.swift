import XCTest
@testable import VerbCore

/// The check that keeps a writing model's clean-up from changing what was said.
final class GuardTests: XCTestCase {
    func testFaithfulCleanupsPass() {
        let pairs = [
            ("Ci vediamo martedì, anzi mercoledì, alle quindici.", "Ci vediamo mercoledì alle quindici."),
            ("Prenota per quattro persone, no, per cinque persone.", "Prenota per cinque persone."),
            ("Send it to Alex, no, to Jamie.", "Send it to Jamie."),
            ("il deployment è venerdì please review the pull request", "Il deployment è venerdì. Please review the pull request."),
            ("Sono ventitré persone e costa duemila euro.", "Sono 23 persone e costa 2.000 euro."),
            ("We need twenty three chairs and one hundred and five cups.", "We need 23 chairs and 105 cups."),
            ("Lo sconto è del venti per cento.", "Lo sconto è del 20%."),
            ("Le cose da fare sono tre: comprare il pane, chiamare Marco, pagare la bolletta.", "Le cose da fare sono tre:\n1. Comprare il pane\n2. Chiamare Marco\n3. Pagare la bolletta"),
            ("Definisco una classe astratta con sotto le sottoclassi.", "Definisco una classe astratta, con sotto le sottoclassi."),
            ("Manda [VERB_SNIPPET_ab12cd34_0] a Marco", "Manda [VERB_SNIPPET_ab12cd34_0] a Marco."),
            ("Puoi mandarmi il file entro stasera?", "Puoi mandarmi il file entro stasera?"),
        ]
        for (said, cleaned) in pairs { XCTAssertNil(CleanupGuard.check(said: said, cleaned: cleaned), "\(said) → \(cleaned)") }
    }

    func testChangedMeaningIsCaught() {
        XCTAssertEqual(CleanupGuard.check(said: "Il volo parte alle 7 e arriva alle 9.", cleaned: "Il volo parte alle 7 e arriva alle 10."), .number)
        XCTAssertEqual(CleanupGuard.check(said: "Servono 3 sedie e 2 tavoli.", cleaned: "Servono sedie e tavoli."), .number)
        XCTAssertEqual(CleanupGuard.check(said: "Read it before the meeting.", cleaned: "Read it without the meeting."), .negation)
        XCTAssertEqual(CleanupGuard.check(said: "Non inviare il report oggi.", cleaned: "Invia il report oggi."), .negation)
        XCTAssertEqual(CleanupGuard.check(said: "Puoi mandarmi il file entro stasera?", cleaned: "Mandami il file entro stasera."), .question)
        XCTAssertEqual(CleanupGuard.check(said: "Il report è pronto.", cleaned: "Il report è pronto?"), .question)
        XCTAssertEqual(CleanupGuard.check(said: "Ho parlato con Giulia del progetto Atlas.", cleaned: "Ho parlato con lei del progetto Atlas."), .name("Giulia"))
        XCTAssertEqual(CleanupGuard.check(said: "Ci vediamo martedì.", cleaned: "Ci vediamo mercoledì."), .name("mercoledi"))
        XCTAssertEqual(CleanupGuard.check(said: "apri verb e detta la mail", cleaned: "Apri e detta la mail.", vocabulary: ["Verb"]), .name("Verb"))
    }

    func testAnswersInsteadOfCleanupsAreCaught() {
        XCTAssertEqual(CleanupGuard.check(said: "Ora ti chiedo di fare un audit completo di Wispr Flow e di estrarre tutte le funzionalità.",
                                          cleaned: "Certo! Ecco un audit completo di Wispr Flow: la dettatura, i comandi, le note e il dizionario personale."), .answered)
        XCTAssertEqual(CleanupGuard.check(said: "Scrivi una poesia sul mare che parli delle onde e del vento di maestrale.",
                                          cleaned: "Onde lente accarezzano la riva, il maestrale canta tra gli scogli, e il sale resta sulle labbra come un ricordo lontano che torna."), .answered)
        XCTAssertEqual(CleanupGuard.check(said: "Qual è la capitale della Francia?", cleaned: "La capitale della Francia è Parigi."), .question)
        XCTAssertEqual(CleanupGuard.check(said: "Riassumi questo documento in tre punti e mandalo a tutto il team entro domani.",
                                          cleaned: "Ecco il riassunto."), .answered)
    }

    func testACorrectionExcusesOnlyWhatItTakesBack() {
        XCTAssertEqual(CleanupGuard.check(said: "Ci vediamo alle 5, anzi alle 6. Il contratto non è pronto, costa 300 euro.", cleaned: "Ci vediamo alle 6. Il contratto è pronto."), .number)
        XCTAssertEqual(CleanupGuard.check(said: "Ci vediamo alle 5, anzi alle 6. Il contratto non è pronto.", cleaned: "Ci vediamo alle 6. Il contratto è pronto."), .negation)
        XCTAssertEqual(CleanupGuard.check(said: "Actually, I don't think we should ship on Friday with 3 open bugs.", cleaned: "I think we should ship on Friday with open bugs."), .number,
                       "an opening “Actually,” corrects nothing that follows")
        XCTAssertEqual(CleanupGuard.check(said: "Ci vediamo martedì, anzi mercoledì, con Giulia.", cleaned: "Ci vediamo mercoledì."), .name("Giulia"), "what follows the cue is the final choice")
        XCTAssertNil(CleanupGuard.check(said: "Ci vediamo alle 5, anzi alle 6. Il contratto non è pronto.", cleaned: "Ci vediamo alle 6. Il contratto non è pronto."))
        XCTAssertNil(CleanupGuard.check(said: "Il volo è alle 7. Anzi, alle 8.", cleaned: "Il volo è alle 8."), "a cue that opens a sentence corrects the one before")
        XCTAssertEqual(CleanupGuard.check(said: "The report costs 300 euros. Actually, I think we should wait.", cleaned: "The report costs euros. I think we should wait."), .number,
                       "an opening “Actually,” doesn't take back the sentence before either")
        XCTAssertNil(CleanupGuard.check(said: "ci vediamo alle cinque anzi alle sei", cleaned: "Ci vediamo alle sei."), "without punctuation, one sentence")
        XCTAssertNil(CleanupGuard.check(said: "Porto il vino, no scusa, porto la birra.", cleaned: "Porto la birra."), "what a correction takes back doesn't make the clean-up too short")
        XCTAssertNil(CleanupGuard.check(said: "Mandalo a Marco. Anzi no, mandalo a Giulia.", cleaned: "Mandalo a Giulia."))
    }

    func testNumbersGluedToLettersAndSaidAsWords() {
        XCTAssertEqual(CleanupGuard.check(said: "The meeting is at 10am.", cleaned: "The meeting is at 11am."), .number)
        XCTAssertEqual(CleanupGuard.check(said: "Take the 3rd exit.", cleaned: "Take the 4th exit."), .number)
        XCTAssertEqual(CleanupGuard.check(said: "Prendi 100mg di ibuprofene.", cleaned: "Prendi 400mg di ibuprofene."), .number)
        XCTAssertNil(CleanupGuard.check(said: "Take the third exit.", cleaned: "Take the 3rd exit."), "an ordinal may go into digits")
        XCTAssertNil(CleanupGuard.check(said: "Tra sei mesi cambiamo casa.", cleaned: "Tra 6 mesi cambiamo casa."), "“sei” may be six")
        XCTAssertNil(CleanupGuard.check(said: "Tre cose: uno, comprare il pane, due, chiamare Marco, tre, pagare la bolletta.",
                                        cleaned: "Tre cose:\n1. Comprare il pane\n2. Chiamare Marco\n3. Pagare la bolletta"), "a spoken list's numbers live on as its markers")
        XCTAssertEqual(CleanupGuard.numbers(in: "Siamo in 20. 3 sono assenti").values, [3, 20], "numbers never join across a full stop")
    }

    func testHugeNumbersDontOverflow() {
        let hundreds = Array(repeating: "cento", count: 20).joined(separator: " ")
        XCTAssertNil(CleanupGuard.check(said: "Sono \(hundreds) euro.", cleaned: "Sono \(hundreds) euro."))
        XCTAssertFalse(CleanupGuard.numbers(in: Array(repeating: "hundred", count: 20).joined(separator: " ")).isEmpty)
        XCTAssertFalse(CleanupGuard.numbers(in: Array(repeating: "100", count: 20).joined(separator: " ")).isEmpty)
        XCTAssertEqual(CleanupGuard.numbers(in: "999999999999999 billion").values.count, 2, "a number too big to hold starts again")
        XCTAssertNil(CleanupGuard.italianNumber(String(repeating: "cento", count: 20)))
    }

    func testLostNegationsAreCaught() {
        XCTAssertEqual(CleanupGuard.check(said: "We have no budget for this.", cleaned: "We have budget for this."), .negation)
        XCTAssertEqual(CleanupGuard.check(said: "Nemmeno Marco ha finito il report.", cleaned: "Anche Marco ha finito il report."), .negation)
        XCTAssertEqual(CleanupGuard.check(said: "Neanche io lo so.", cleaned: "Io lo so."), .negation)
        XCTAssertEqual(CleanupGuard.check(said: "Neither option works for us.", cleaned: "Either option works for us."), .negation)
        XCTAssertNil(CleanupGuard.check(said: "No grazie, sto bene.", cleaned: "No, grazie, sto bene."), "a comma after “no” changes nothing")
    }

    func testNamesAtTheStartAndWordsThatAreNoNames() {
        XCTAssertEqual(CleanupGuard.check(said: "Giulia ha chiamato stamattina.", cleaned: "Marco ha chiamato stamattina.", names: ["Giulia"]), .name("Giulia"))
        XCTAssertNil(CleanupGuard.check(said: "Yes, I'm ready and I've got the file.", cleaned: "Yes, I am ready and I have got the file."))
        XCTAssertNil(CleanupGuard.check(said: "Va bene, OK, lo mando.", cleaned: "Va bene, okay, lo mando."))
    }

    func testDroppedOpenersAndShortAnswers() {
        XCTAssertNil(CleanupGuard.check(said: "So, here's the plan for tomorrow.", cleaned: "Here's the plan for tomorrow."))
        XCTAssertNil(CleanupGuard.check(said: "Allora, ecco il piano per domani.", cleaned: "Ecco il piano per domani."))
        XCTAssertNil(CleanupGuard.check(said: "Well, sure, I can do that.", cleaned: "Sure, I can do that."))
        XCTAssertNil(CleanupGuard.check(said: "Quindi, certo che vengo alla cena.", cleaned: "Certo che vengo alla cena."))
        XCTAssertEqual(CleanupGuard.check(said: "Write a haiku about cats.", cleaned: "Soft paws on the sill,\na quiet hunter dreaming\nof birds in the sun."), .answered)
        XCTAssertNil(CleanupGuard.check(said: "ok grazie ci vediamo domani", cleaned: "Ok, grazie, ci vediamo domani."))
    }

    func testAQuestionMarkNeedsTheShapeOfAQuestion() {
        XCTAssertEqual(CleanupGuard.check(said: "The report is ready.", cleaned: "The report is ready?"), .question)
        XCTAssertEqual(CleanupGuard.check(said: "Dimmi quando arrivi.", cleaned: "Dimmi quando arrivi?"), .question)
        XCTAssertNil(CleanupGuard.check(said: "Is the report ready.", cleaned: "Is the report ready?"))
        XCTAssertNil(CleanupGuard.check(said: "Il report è pronto, vero.", cleaned: "Il report è pronto, vero?"))
        XCTAssertNil(CleanupGuard.check(said: "Marco, puoi mandarmi il file.", cleaned: "Marco, puoi mandarmi il file?"))
        XCTAssertNil(CleanupGuard.check(said: "It's ready, isn't it.", cleaned: "It's ready, isn't it?"))
        XCTAssertNil(CleanupGuard.check(said: "Ci vediamo domani, no.", cleaned: "Ci vediamo domani, no?"))
    }

    func testNumbersInWordsAndDigits() {
        XCTAssertEqual(CleanupGuard.numbers(in: "duemilaventisei").values, [2026])
        XCTAssertEqual(CleanupGuard.numbers(in: "centottanta e trentuno").values, [31, 180])
        XCTAssertEqual(CleanupGuard.numbers(in: "tre, quattro").values, [3, 4])
        XCTAssertEqual(CleanupGuard.numbers(in: "twenty three").values, [23])
        XCTAssertEqual(CleanupGuard.numbers(in: "due milioni").values, [2_000_000])
        XCTAssertEqual(CleanupGuard.numbers(in: "alle 15:30, sono 1.500 euro").values, [15, 30, 1500])
        XCTAssertEqual(CleanupGuard.numbers(in: "una classe, sei pronto?").values, [], "articles and verbs are not numbers")
        XCTAssertEqual(CleanupGuard.numbers(in: "il treno di novembre e la centrale").values, [], "words made of number parts are not numbers")
    }
}
