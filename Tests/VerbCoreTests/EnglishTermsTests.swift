import XCTest
@testable import VerbCore

/// English words the engine wrote the Italian way, put back, and nothing else.
final class EnglishTermsTests: XCTestCase {
    let italian: Set<String> = ["aspettiamo", "faccia", "script", "dichiara", "morto", "benissimo", "considerando", "relativo", "onboarding", "formattazione", "sottotask", "della", "modulo", "divisa"]
    let english: Set<String> = ["merge", "bundle", "watcher", "brain", "memory", "atlas", "fix", "trace"]
    func restore(_ text: String, lexicon: [String: Int] = [:], preferred: Set<String> = []) -> String {
        EnglishTerms.restore(text, lexicon: lexicon, preferred: preferred, known: { self.italian.contains($0) || self.english.contains($0) }, isEnglish: { self.english.contains($0) }).text
    }

    func testItalianSoundingMisspellingsComeBack() {
        XCTAssertEqual(restore("Aspettiamo che Elio faccia il mercio."), "Aspettiamo che Elio faccia il merge.")
        XCTAssertEqual(restore("lo script dichiara morto un bundolo che sta benissimo"), "lo script dichiara morto un bundle che sta benissimo")
        XCTAssertEqual(restore("Non considerando il Warcher", lexicon: ["watcher": 5]), "Non considerando il Watcher")
        XCTAssertEqual(restore("relativo all'onboarding di Macum", preferred: ["Mecum"]), "relativo all'onboarding di Mecum", "a dictionary spelling keeps its capitals")
    }

    func testMeaningfulWordsStay() {
        XCTAssertEqual(restore("Fixa la formattazione"), "Fixa la formattazione", "an English verb made Italian is meant that way")
        XCTAssertEqual(restore("divisa in sottotask"), "divisa in sottotask")
        XCTAssertEqual(restore("il modulo Atras della memory", lexicon: ["atlas": 12]), "il modulo Atras della memory", "two close answers: nothing changes")
        XCTAssertEqual(restore("Simone"), "Simone", "a name with no close English word stays")
    }

    func testNamesAndPlacesStay() {
        // Like the spell checker, the fake knows a name only with its capital: "Sara", never "sara".
        let names: Set<String> = ["Sara", "Irene", "Sergio", "Modena", "Emily", "Brian", "Pisa", "Diego"]
        let words: Set<String> = ["parlato", "stamattina", "domani", "vedo", "chiamato", "vediamo", "visto", "ieri", "fatto"]
        func restore(_ text: String) -> String {
            EnglishTerms.restore(text, lexicon: [:], known: { names.contains($0) || words.contains($0) || self.italian.contains($0) }, isEnglish: { self.english.contains($0) }).text
        }
        for text in ["Ho parlato con Sara stamattina.", "Domani vedo Irene e Sergio a Modena.", "Ho chiamato Emily e Brian.", "Ci vediamo a Pisa con Diego."] {
            XCTAssertEqual(restore(text), text, text)
        }
        XCTAssertEqual(restore("Ho parlato con sergio."), "Ho parlato con sergio.", "a name the engine wrote in lowercase")
        XCTAssertEqual(restore("Ho visto Tami ieri."), "Ho visto Tami ieri.", "a capital inside a sentence marks a name, though the checker doesn't know it")
        XCTAssertEqual(restore("Mercio fatto."), "Merge fatto.", "at the start of a sentence a capital proves nothing")
    }

    func testSoundKeys() {
        XCTAssertEqual(EnglishTerms.italianKey("mercio"), "merC")
        XCTAssertEqual(EnglishTerms.englishKey("merge"), "merJ")
        XCTAssertEqual(EnglishTerms.italianKey("bundolo"), "bundol")
        XCTAssertEqual(EnglishTerms.englishKey("bundle"), "bundl")
        XCTAssertEqual(EnglishTerms.distance(Array("merC"), Array("merJ")), 0.5)
    }
}
