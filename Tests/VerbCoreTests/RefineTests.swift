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

    func testAcronymsAreNeverHesitations() {
        for text in ["We went to the ER yesterday.", "An ERM framework for risk.", "Le HMM sono modelli statistici.", "UM is a university in Montana.", "Ask UH about it."] {
            XCTAssertEqual(TextRules.quickClean(text), text, text)
        }
        XCTAssertEqual(TextRules.quickClean("Um, the ER is open."), "The ER is open.")
    }

    func testItalianHasOneMoreHesitation() {
        XCTAssertEqual(TextRules.quickClean("Em allora Em volevo dire che è pronto.", language: "it"), "Allora volevo dire che è pronto.")
        XCTAssertEqual(TextRules.quickClean("Em, ci vediamo domani.", language: "it-IT"), "Ci vediamo domani.")
        XCTAssertEqual(TextRules.quickClean("Let em go, it is an em dash.", language: "en"), "Let em go, it is an em dash.", "English has the word")
        XCTAssertEqual(TextRules.quickClean("Em allora andiamo."), "Em allora andiamo.", "with the language unknown, nothing new is removed")
    }

    func testLineCommandsInsideASentenceStayWords() {
        for prose in ["Please add new line items to the order.", "Chi c’è a capo?", "Chi c'è a capo?", "Lo hanno messo a capo.", "L’hanno nominata a capo.", "Lei sta a capo da anni.",
                      "Camminava a capo chino.", "Nel nuovo paragrafo c’è tutto.", "We need new line managers."] {
            XCTAssertEqual(TextRules.commandPunctuation(prose), prose, prose)
        }
        XCTAssertEqual(TextRules.commandPunctuation("Ciao Marco a capo ci vediamo domani."), "Ciao Marco\nci vediamo domani.", "“a capo” needs no pause")
        XCTAssertEqual(TextRules.commandPunctuation("First line new line. Second line new paragraph third."), "First line\nSecond line\n\nthird.", "“new line” needs one")
        XCTAssertEqual(TextRules.commandPunctuation("A capo. Ci vediamo."), "\nCi vediamo.")
    }

    func testABreakTakesTheCommaBeforeItExceptAfterAGreeting() {
        XCTAssertEqual(TextRules.commandPunctuation("Seconda riga, nuovo paragrafo, terzo paragrafo."), "Seconda riga\n\nterzo paragrafo.")
        XCTAssertEqual(TextRules.commandPunctuation("First line, new line, second line."), "First line\nsecond line.")
        XCTAssertEqual(TextRules.commandPunctuation("Ciao Marco, a capo, ci vediamo domani."), "Ciao Marco,\nci vediamo domani.")
        XCTAssertEqual(TextRules.commandPunctuation("Dear Anna, new paragraph, thanks for the notes."), "Dear Anna,\n\nthanks for the notes.")
        XCTAssertEqual(TextRules.commandPunctuation("Ecco la lista: a capo, latte."), "Ecco la lista:\nlatte.", "a colon stays")
    }

    func testPunctuationSaidAsAWord() {
        func it(_ text: String) -> String { TextRules.commandPunctuation(text, language: "it") }
        func en(_ text: String) -> String { TextRules.commandPunctuation(text, language: "en") }
        XCTAssertEqual(it("Ciao Marco Virgola ci vediamo domani alle 3."), "Ciao Marco, ci vediamo domani alle 3.")
        XCTAssertEqual(it("Sei libero domani pomeriggio. Punto interrogativo."), "Sei libero domani pomeriggio?")
        XCTAssertEqual(it("Sei libero domani pomeriggio punto interrogativo"), "Sei libero domani pomeriggio?")
        XCTAssertEqual(it("Ciao Marco, ci vediamo domani alle tre punto."), "Ciao Marco, ci vediamo domani alle tre.")
        XCTAssertEqual(it("Arrivo tardi punto e virgola scusa"), "Arrivo tardi; scusa")
        XCTAssertEqual(it("Che bello punto esclamativo"), "Che bello!")
        XCTAssertEqual(it("Ciao Marco punto e a capo ci vediamo domani"), "Ciao Marco.\nCi vediamo domani")
        XCTAssertEqual(it("Ciao Marco. Punto. Ci vediamo."), "Ciao Marco. Ci vediamo.")
        XCTAssertEqual(it("Il totale è 3 virgola 5 euro."), "Il totale è 3,5 euro.")
        XCTAssertEqual(en("Hi Sarah, comma let's meet tomorrow at 3 period."), "Hi Sarah, let's meet tomorrow at 3.")
        XCTAssertEqual(en("Are you free tomorrow afternoon question mark?"), "Are you free tomorrow afternoon?")
        XCTAssertEqual(en("Are you free tomorrow afternoon? Question mark."), "Are you free tomorrow afternoon?")
        XCTAssertEqual(en("Hi Sarah, comma lets meet tomorrow at three. Period."), "Hi Sarah, lets meet tomorrow at three.")
        XCTAssertEqual(en("That is great exclamation mark"), "That is great!")
    }

    func testMarkNamesStayWordsWhereTheyMeanTheMark() {
        for text in ["Il punto è questo.", "A che punto siamo?", "Ci vediamo alle tre in punto.", "Manca una virgola.", "Facciamo il punto.", "Dal mio punto di vista va bene.",
                     "Il punto vendita apre alle nove.", "Punto e basta.", "Abbiamo segnato un punto.", "Ai sensi del comma 3 dell’articolo 5."] {
            XCTAssertEqual(TextRules.commandPunctuation(text, language: "it"), text, text)
        }
        for text in ["Add a comma here.", "The Oxford comma is optional.", "It was a long period.", "During that period we grew.", "The trial period ends today.",
                     "The car came to a full stop.", "A period of change."] {
            XCTAssertEqual(TextRules.commandPunctuation(text, language: "en"), text, text)
        }
        XCTAssertEqual(TextRules.commandPunctuation("Ci vediamo punto Poi", language: nil), "Ci vediamo punto Poi", "with the language unknown, “punto” stays")
        XCTAssertEqual(TextRules.commandPunctuation("Sei libero punto interrogativo", language: nil), "Sei libero?")
    }

    func testAddressesSaidAsWords() {
        XCTAssertEqual(TextRules.commandPunctuation("Scrivimi a tommaso chiocciola esempio punto it", language: "it"), "Scrivimi a tommaso@esempio.it")
        XCTAssertEqual(TextRules.commandPunctuation("La mail è Mario punto Rossi chiocciola gmail punto com.", language: "it"), "La mail è mario.rossi@gmail.com.")
        XCTAssertEqual(TextRules.commandPunctuation("Vai su google punto it per cercarlo.", language: "it"), "Vai su google.it per cercarlo.")
        XCTAssertEqual(TextRules.commandPunctuation("Send the report to john dot smith at example dot com", language: "en"), "Send the report to john.smith@example.com")
        XCTAssertEqual(TextRules.commandPunctuation("Write to anna at example dot org today.", language: "en"), "Write to anna@example.org today.")
        XCTAssertEqual(TextRules.commandPunctuation("Take a look at google dot com", language: "en"), "Take a look at google.com", "a plain word before “at” is no mailbox")
        for text in ["Ho visto una chiocciola in giardino.", "Il punto it è chiaro.", "We met at the office."] {
            XCTAssertEqual(TextRules.commandPunctuation(text, language: TextRules.baseLanguage(text.contains("We") ? "en" : "it")), text, text)
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

/// Numbers written the way people write them, and long dictations cut where sentences end.
final class NumbersAndPartsTests: XCTestCase {
    func testFiguresWherePeopleWriteFigures() {
        func it(_ text: String) -> String { SpokenNumbers.inText(text, language: "it") }
        func en(_ text: String) -> String { SpokenNumbers.inText(text, language: "en") }
        XCTAssertEqual(it("Il budget è di duemila cinquecento euro e non dobbiamo superarlo."), "Il budget è di 2500 euro e non dobbiamo superarlo.")
        XCTAssertEqual(it("La riunione è spostata al ventitré ottobre alle nove e mezza."), "La riunione è spostata al 23 ottobre alle 9 e mezza.")
        XCTAssertEqual(it("Ci vediamo domani alle tre."), "Ci vediamo domani alle 3.")
        XCTAssertEqual(it("È aumentato del dieci per cento nel duemilaventicinque."), "È aumentato del 10 per cento nel 2025.")
        XCTAssertEqual(it("Costa cento euro."), "Costa 100 euro.")
        XCTAssertEqual(en("Let's meet tomorrow at three."), "Let's meet tomorrow at 3.")
        XCTAssertEqual(en("It costs a hundred dollars, twenty-five percent less."), "It costs 100 dollars, 25 percent less.")
        XCTAssertEqual(en("See you at three o'clock on October twelve."), "See you at 3 o'clock on October twelve.", "a month before the number is not a date pattern we change")
    }

    func testWordsStayWhereWordsAreTheNorm() {
        for text in ["Ho provato tre volte.", "Abbiamo una riunione alle tre sorelle.", "Mille grazie a tutti.", "Ne parliamo in due.", "Un milione di persone.", "Le tre."] {
            XCTAssertEqual(SpokenNumbers.inText(text, language: "it"), text, text)
        }
        for text in ["I tried three times.", "At one point we stopped.", "One of them is late."] {
            XCTAssertEqual(SpokenNumbers.inText(text, language: "en"), text, text)
        }
        XCTAssertEqual(SpokenNumbers.inText("alle tre", language: nil), "alle tre", "with the language unknown, nothing changes")
    }

    func testLongDictationsAreCutWhereSentencesEnd() {
        let sentence = "Questa è una frase di dieci parole che finisce qui."
        let text = Array(repeating: sentence, count: 130).joined(separator: " ")
        let parts = TextRules.parts(of: text)
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.text.hasSuffix(".") && $0.text.split(separator: " ").count <= 600 })
        XCTAssertEqual(parts.map(\.joiner), ["", " ", " "])
        XCTAssertEqual(parts.map(\.text).joined(separator: " "), text)
    }

    func testParagraphsAreKeptBetweenParts() {
        let paragraph = Array(repeating: "Una frase breve di sei parole.", count: 70).joined(separator: " ")
        let text = paragraph + "\n\n" + paragraph
        let parts = TextRules.parts(of: text)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1].joiner, "\n\n")
        XCTAssertEqual(parts.map { $0.joiner + $0.text }.joined(), text)
        XCTAssertEqual(TextRules.parts(of: "Breve.").count, 1)
    }

    func testARunOnSentenceIsCutBetweenWords() {
        let text = Array(repeating: "parola", count: 1500).joined(separator: " ")
        let parts = TextRules.parts(of: text)
        XCTAssertEqual(parts.map { $0.text.split(separator: " ").count }, [600, 600, 300])
        XCTAssertEqual(TextRules.parts(of: "3.5 è un numero. Fine.").count, 1)
        XCTAssertEqual(TextRules.sentences(of: "Costa 3.5 euro. Fine.").map(\.body), ["Costa 3.5 euro.", "Fine."])
    }
    func testAnAppWithAStyleOfItsOwnIsRefinedEveryTimeUnlessNever() {
        XCTAssertTrue(CleanupPolicy.always.usesModel(wordsCallForIt: false, appStyle: nil))
        XCTAssertFalse(CleanupPolicy.whenNeeded.usesModel(wordsCallForIt: false, appStyle: nil), "a short clean dictation goes straight in")
        XCTAssertTrue(CleanupPolicy.whenNeeded.usesModel(wordsCallForIt: true, appStyle: nil))
        for style in [WritingStyle.casual, .formal, .custom] { XCTAssertTrue(CleanupPolicy.whenNeeded.usesModel(wordsCallForIt: false, appStyle: style), "\(style) shows in a short dictation too") }
        XCTAssertFalse(CleanupPolicy.whenNeeded.usesModel(wordsCallForIt: false, appStyle: .natural))
        XCTAssertFalse(CleanupPolicy.whenNeeded.usesModel(wordsCallForIt: false, appStyle: .verbatim))
        for style in WritingStyle.allCases { XCTAssertFalse(CleanupPolicy.never.usesModel(wordsCallForIt: true, appStyle: style), "Never means never") }
    }
    func testACustomStyleUsesWhatWasWrittenForTheApp() {
        var settings = Settings()
        settings.appStyles["com.tinyspeck.slackmacgap"] = .custom
        XCTAssertEqual(settings.style(for: "com.tinyspeck.slackmacgap"), .natural, "Custom with nothing written is the default")
        XCTAssertNil(settings.stylePrompt(for: "com.tinyspeck.slackmacgap"))
        settings.stylePrompts["com.tinyspeck.slackmacgap"] = "  Short and friendly, no full stop at the end.  "
        XCTAssertEqual(settings.style(for: "com.tinyspeck.slackmacgap"), .custom)
        XCTAssertEqual(settings.stylePrompt(for: "com.tinyspeck.slackmacgap"), "Short and friendly, no full stop at the end.")
        settings.appStyles["com.tinyspeck.slackmacgap"] = .formal
        XCTAssertNil(settings.stylePrompt(for: "com.tinyspeck.slackmacgap"), "words kept for Custom wait while another style is chosen")
        let prompt = TextRules.cleanupPrompt(style: .custom, vocabulary: [], custom: "Short and friendly.")
        XCTAssertTrue(prompt.contains("Short and friendly.")); XCTAssertTrue(prompt.contains("every rule above still applies"))
        XCTAssertFalse(WritingStyle.standard.contains(.custom))
    }
}
