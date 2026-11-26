import Foundation

/// Spoken cardinals written as digits, so a transcript that says "quindici" and one that writes "15"
/// score alike: whether a model writes numbers as words or digits is style, not recognition.
/// English, Italian, Spanish, French, German and Portuguese, up to the billions; other languages
/// keep their words.
public enum SpokenNumbers {
    enum Part: Equatable {
        case zero, unit(Int), teen(Int), ten(Int), hundreds(Int), hundred, scale(Int), and, digits(Int)
        var isUnit: Bool { if case .unit = self { return true }; return false }
        var isTeen: Bool { if case .teen = self { return true }; return false }
        var isTen: Bool { if case .ten = self { return true }; return false }
        var isScale: Bool { if case .scale = self { return true }; return false }
        var isDigits: Bool { if case .digits = self { return true }; return false }
    }
    struct Lexicon {
        let words: [String: Part]
        /// Italian, German and Spanish join numbers into one word: "duemilacinquecento".
        let joins: Bool
        /// "nineteen eighty-seven" is a year, 1987.
        var years = false
        /// "nineteen hundred" and "neunzehnhundert": hundreds after a teen or a ten.
        var hundredsAfterTens = false
        /// German puts the unit first: "fünfundzwanzig".
        var unitFirst = false
        /// French counts by twenties: "quatre-vingt-dix", "soixante et onze".
        var twenties = false
        /// Words that mean one only before a multiplier, such as English "a hundred".
        var articles: Set<String> = []
    }

    public static func digits(_ words: [String], language: String) -> [String] {
        guard let lexicon = lexicons[SpeechScoring.base(language)] else { return words }
        var reader = Reader(lexicon: lexicon)
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : nil
            reader.read(word, next: next)
        }
        reader.flush()
        return reader.output
    }

    /// Reads tokens left to right, building one number at a time.
    struct Reader {
        let lexicon: Lexicon
        var output: [String] = []
        private var total = 0, group = 0, last: Part?, smallestScale = Int.max, multiplied = false, active = false
        /// "and" seen inside the number, which German needs before a ten: "fünf-und-zwanzig".
        private var joined = false
        /// A connecting word read but not yet known to belong to the number.
        private var connector: String?
        /// A two-digit number just written, which a second one can turn into a year.
        private var yearStart: (index: Int, value: Int)?
        init(lexicon: Lexicon) { self.lexicon = lexicon }

        mutating func read(_ word: String, next: String?) {
            if lexicon.words[word] == .and, active, connector == nil { connector = word; return }
            var found = parts(of: word)
            if found == nil, lexicon.articles.contains(word), let following = next.flatMap({ parts(of: $0)?.first }), following == .hundred || following.isScale { found = [.unit(1)] }
            guard let found else { flush(); output.append(word); return }
            // A word that is one number on its own, such as "duemilacinquecento", must read as one.
            if found.count > 1, !Reader.reads(found, lexicon: lexicon) { flush(); output.append(word); return }
            for part in found {
                if active, accepts(part) { apply(part) } else { end(continued: active); begin(part) }
            }
            connector = nil
        }

        mutating func flush() { end(continued: false) }

        private func parts(of word: String) -> [Part]? {
            if let value = Int(word), word.count <= 3 { return [.digits(value)] }
            if let part = lexicon.words[word] { return part == .and ? nil : [part] }
            return lexicon.joins ? Reader.split(word, lexicon: lexicon) : nil
        }

        /// The longest pieces first, so "dreizehn" stays thirteen instead of three and ten.
        static func split(_ word: String, lexicon: Lexicon) -> [Part]? {
            if word.isEmpty { return [] }
            for length in stride(from: word.count, through: 2, by: -1) {
                guard let part = lexicon.words[String(word.prefix(length))], let rest = split(String(word.dropFirst(length)), lexicon: lexicon) else { continue }
                return [part] + rest
            }
            return nil
        }

        static func reads(_ parts: [Part], lexicon: Lexicon) -> Bool {
            guard parts.first != .and else { return false }
            var reader = Reader(lexicon: lexicon)
            reader.begin(parts[0])
            for part in parts.dropFirst() {
                guard reader.accepts(part) else { return false }
                reader.apply(part)
            }
            return true
        }

        private func accepts(_ part: Part) -> Bool {
            switch part {
            case .and: return !joined
            case .zero, .digits: return false
            case .unit:
                // French seventeen to nineteen: "dix-sept", "soixante-dix-sept", "quatre-vingt-dix-neuf".
                if lexicon.twenties, last == .teen(10), [10, 70, 90].contains(group % 100) { return true }
                return group % 10 == 0 && !lastIsSmall
            case .teen:
                if lexicon.twenties, last?.isTen == true, [60, 80].contains(group % 100) { return true }
                return group % 100 == 0 && !lastIsSmall && last?.isTen != true
            case .ten(let value):
                if lexicon.twenties, value == 20, last == .unit(4), group % 100 == 4 { return true }
                if lexicon.unitFirst, joined || connector != nil, last?.isUnit == true, group % 100 < 10 { return true }
                return group % 100 == 0 && !lastIsSmall && last?.isTen != true
            case .hundreds: return group == 0 && (last?.isScale ?? true)
            case .hundred: return last != .hundred && (group < 10 || (lexicon.hundredsAfterTens && group < 100))
            case .scale(let value): return value < smallestScale
            }
        }

        private mutating func apply(_ part: Part) {
            switch part {
            case .and: joined = true; return
            case .zero: break
            case .digits(let value), .unit(let value), .teen(let value), .hundreds(let value): group += value
            case .ten(let value): group += lexicon.twenties && value == 20 && last == .unit(4) && group % 100 == 4 ? 76 : value
            case .hundred: group = max(group, 1) * 100; multiplied = true
            case .scale(let value): total += max(group, 1) * value; group = 0; smallestScale = value; multiplied = true
            }
            last = part; joined = false
        }

        private mutating func begin(_ part: Part) {
            if part == .zero { output.append("0"); return }
            active = true; total = 0; group = 0; last = nil; smallestScale = Int.max; multiplied = false; joined = false
            switch part {
            case .scale(let value): total = value; smallestScale = value; multiplied = true; last = part
            case .hundred: group = 100; multiplied = true; last = part
            default: apply(part)
            }
        }

        /// Writes the number. `continued` means another number follows at once, which may make a year.
        private mutating func end(continued: Bool) {
            if active {
                let value = total + group
                if lexicon.years, let start = yearStart, !multiplied, (1...99).contains(value) {
                    output[start.index] = String(start.value) + String(format: "%02d", value)
                    yearStart = nil
                } else {
                    output.append(String(value))
                    yearStart = continued && connector == nil && lexicon.years && !multiplied && (10...99).contains(value) ? (output.count - 1, value) : nil
                }
                active = false
            }
            if let connector { output.append(connector); self.connector = nil }
            if !continued { yearStart = nil }
        }

        private var lastIsSmall: Bool { last?.isUnit == true || last?.isTeen == true || last?.isDigits == true }
    }

    private static func lexicon(_ groups: [(Part, [String])]) -> [String: Part] {
        var words: [String: Part] = [:]
        for (part, names) in groups { for name in names { words[name] = part } }
        return words
    }

    static let lexicons: [String: Lexicon] = [
        "en": Lexicon(words: lexicon([
            (.zero, ["zero"]), (.unit(1), ["one"]), (.unit(2), ["two"]), (.unit(3), ["three"]), (.unit(4), ["four"]), (.unit(5), ["five"]),
            (.unit(6), ["six"]), (.unit(7), ["seven"]), (.unit(8), ["eight"]), (.unit(9), ["nine"]), (.teen(10), ["ten"]), (.teen(11), ["eleven"]),
            (.teen(12), ["twelve"]), (.teen(13), ["thirteen"]), (.teen(14), ["fourteen"]), (.teen(15), ["fifteen"]), (.teen(16), ["sixteen"]),
            (.teen(17), ["seventeen"]), (.teen(18), ["eighteen"]), (.teen(19), ["nineteen"]), (.ten(20), ["twenty"]), (.ten(30), ["thirty"]),
            (.ten(40), ["forty"]), (.ten(50), ["fifty"]), (.ten(60), ["sixty"]), (.ten(70), ["seventy"]), (.ten(80), ["eighty"]), (.ten(90), ["ninety"]),
            (.hundred, ["hundred"]), (.scale(1000), ["thousand"]), (.scale(1_000_000), ["million", "millions"]), (.scale(1_000_000_000), ["billion", "billions"]),
            (.and, ["and"])]), joins: false, years: true, hundredsAfterTens: true, articles: ["a"]),
        "it": Lexicon(words: lexicon([
            (.zero, ["zero"]), (.unit(1), ["uno", "un", "una"]), (.unit(2), ["due"]), (.unit(3), ["tre", "tré"]), (.unit(4), ["quattro"]),
            (.unit(5), ["cinque"]), (.unit(6), ["sei"]), (.unit(7), ["sette"]), (.unit(8), ["otto"]), (.unit(9), ["nove"]),
            (.teen(10), ["dieci"]), (.teen(11), ["undici"]), (.teen(12), ["dodici"]), (.teen(13), ["tredici"]), (.teen(14), ["quattordici"]),
            (.teen(15), ["quindici"]), (.teen(16), ["sedici"]), (.teen(17), ["diciassette"]), (.teen(18), ["diciotto"]), (.teen(19), ["diciannove"]),
            (.ten(20), ["venti", "vent"]), (.ten(30), ["trenta", "trent"]), (.ten(40), ["quaranta", "quarant"]), (.ten(50), ["cinquanta", "cinquant"]),
            (.ten(60), ["sessanta", "sessant"]), (.ten(70), ["settanta", "settant"]), (.ten(80), ["ottanta", "ottant"]), (.ten(90), ["novanta", "novant"]),
            (.hundred, ["cento", "cent"]), (.scale(1000), ["mille", "mila"]), (.scale(1_000_000), ["milione", "milioni"]), (.scale(1_000_000_000), ["miliardo", "miliardi"]),
            (.and, ["e"])]), joins: true),
        "es": Lexicon(words: lexicon([
            (.zero, ["cero"]), (.unit(1), ["uno", "un", "una", "ún"]), (.unit(2), ["dos", "dós"]), (.unit(3), ["tres", "trés"]), (.unit(4), ["cuatro"]),
            (.unit(5), ["cinco"]), (.unit(6), ["seis", "séis"]), (.unit(7), ["siete"]), (.unit(8), ["ocho"]), (.unit(9), ["nueve"]),
            (.teen(10), ["diez"]), (.teen(11), ["once"]), (.teen(12), ["doce"]), (.teen(13), ["trece"]), (.teen(14), ["catorce"]), (.teen(15), ["quince"]),
            (.teen(16), ["dieciséis", "dieciseis"]), (.teen(17), ["diecisiete"]), (.teen(18), ["dieciocho"]), (.teen(19), ["diecinueve"]),
            (.ten(20), ["veinte", "veinti"]), (.ten(30), ["treinta"]), (.ten(40), ["cuarenta"]), (.ten(50), ["cincuenta"]), (.ten(60), ["sesenta"]),
            (.ten(70), ["setenta"]), (.ten(80), ["ochenta"]), (.ten(90), ["noventa"]),
            (.hundreds(100), ["cien", "ciento"]), (.hundreds(200), ["doscientos", "doscientas"]), (.hundreds(300), ["trescientos", "trescientas"]),
            (.hundreds(400), ["cuatrocientos", "cuatrocientas"]), (.hundreds(500), ["quinientos", "quinientas"]), (.hundreds(600), ["seiscientos", "seiscientas"]),
            (.hundreds(700), ["setecientos", "setecientas"]), (.hundreds(800), ["ochocientos", "ochocientas"]), (.hundreds(900), ["novecientos", "novecientas"]),
            (.scale(1000), ["mil"]), (.scale(1_000_000), ["millón", "millon", "millones"]), (.and, ["y"])]), joins: true),
        "pt": Lexicon(words: lexicon([
            (.zero, ["zero"]), (.unit(1), ["um", "uma"]), (.unit(2), ["dois", "duas"]), (.unit(3), ["três", "tres"]), (.unit(4), ["quatro"]),
            (.unit(5), ["cinco"]), (.unit(6), ["seis"]), (.unit(7), ["sete"]), (.unit(8), ["oito"]), (.unit(9), ["nove"]),
            (.teen(10), ["dez"]), (.teen(11), ["onze"]), (.teen(12), ["doze"]), (.teen(13), ["treze"]), (.teen(14), ["catorze", "quatorze"]), (.teen(15), ["quinze"]),
            (.teen(16), ["dezesseis", "dezasseis"]), (.teen(17), ["dezessete", "dezassete"]), (.teen(18), ["dezoito"]), (.teen(19), ["dezenove", "dezanove"]),
            (.ten(20), ["vinte"]), (.ten(30), ["trinta"]), (.ten(40), ["quarenta"]), (.ten(50), ["cinquenta", "cincoenta"]), (.ten(60), ["sessenta"]),
            (.ten(70), ["setenta"]), (.ten(80), ["oitenta"]), (.ten(90), ["noventa"]),
            (.hundreds(100), ["cem", "cento"]), (.hundreds(200), ["duzentos", "duzentas"]), (.hundreds(300), ["trezentos", "trezentas"]),
            (.hundreds(400), ["quatrocentos", "quatrocentas"]), (.hundreds(500), ["quinhentos", "quinhentas"]), (.hundreds(600), ["seiscentos", "seiscentas"]),
            (.hundreds(700), ["setecentos", "setecentas"]), (.hundreds(800), ["oitocentos", "oitocentas"]), (.hundreds(900), ["novecentos", "novecentas"]),
            (.scale(1000), ["mil"]), (.scale(1_000_000), ["milhão", "milhao", "milhões", "milhoes"]), (.and, ["e"])]), joins: false),
        "fr": Lexicon(words: lexicon([
            (.zero, ["zéro", "zero"]), (.unit(1), ["un", "une"]), (.unit(2), ["deux"]), (.unit(3), ["trois"]), (.unit(4), ["quatre"]), (.unit(5), ["cinq"]),
            (.unit(6), ["six"]), (.unit(7), ["sept"]), (.unit(8), ["huit"]), (.unit(9), ["neuf"]), (.teen(10), ["dix"]), (.teen(11), ["onze"]),
            (.teen(12), ["douze"]), (.teen(13), ["treize"]), (.teen(14), ["quatorze"]), (.teen(15), ["quinze"]), (.teen(16), ["seize"]),
            (.ten(20), ["vingt", "vingts"]), (.ten(30), ["trente"]), (.ten(40), ["quarante"]), (.ten(50), ["cinquante"]), (.ten(60), ["soixante"]),
            (.hundred, ["cent", "cents"]), (.scale(1000), ["mille", "mil"]), (.scale(1_000_000), ["million", "millions"]), (.scale(1_000_000_000), ["milliard", "milliards"]),
            (.and, ["et"])]), joins: false, twenties: true),
        "de": Lexicon(words: lexicon([
            (.zero, ["null"]), (.unit(1), ["eins", "ein", "eine", "einen", "einem", "einer"]), (.unit(2), ["zwei"]), (.unit(3), ["drei"]), (.unit(4), ["vier"]),
            (.unit(5), ["fünf"]), (.unit(6), ["sechs"]), (.unit(7), ["sieben"]), (.unit(8), ["acht"]), (.unit(9), ["neun"]),
            (.teen(10), ["zehn"]), (.teen(11), ["elf"]), (.teen(12), ["zwölf"]), (.teen(13), ["dreizehn"]), (.teen(14), ["vierzehn"]), (.teen(15), ["fünfzehn"]),
            (.teen(16), ["sechzehn"]), (.teen(17), ["siebzehn"]), (.teen(18), ["achtzehn"]), (.teen(19), ["neunzehn"]),
            (.ten(20), ["zwanzig"]), (.ten(30), ["dreißig", "dreissig"]), (.ten(40), ["vierzig"]), (.ten(50), ["fünfzig"]), (.ten(60), ["sechzig"]),
            (.ten(70), ["siebzig"]), (.ten(80), ["achtzig"]), (.ten(90), ["neunzig"]),
            (.hundred, ["hundert"]), (.scale(1000), ["tausend"]), (.scale(1_000_000), ["million", "millionen"]), (.scale(1_000_000_000), ["milliarde", "milliarden"]),
            (.and, ["und"])]), joins: true, hundredsAfterTens: true, unitFirst: true)
    ]
}

extension SpokenNumbers {
    /// Numbers a speech engine wrote as words where people write figures, written as digits:
    /// dates ("ventitré ottobre"), amounts ("duemila cinquecento euro", "ten percent"), times
    /// after "alle" or "at" ("alle nove e mezza"), and years after "nel" or "in". Elsewhere the
    /// words stay, as people write them: "tre volte", "una riunione", "mille grazie". Italian
    /// and English; one engine writing "alle 3" and another "alle tre" then agree.
    public static func inText(_ text: String, language: String?) -> String {
        guard let base = TextRules.baseLanguage(language), let context = contexts[base], let lexicon = lexicons[base] else { return text }
        let ns = text as NSString
        let tokens = wordPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { (range: $0.range, word: ns.substring(with: $0.range).lowercased()) }
        func joined(_ a: Int, _ b: Int) -> Bool {
            let gap = ns.substring(with: NSRange(location: NSMaxRange(tokens[a].range), length: tokens[b].range.location - NSMaxRange(tokens[a].range)))
            return gap == " " || gap == "-" || gap == "\t"
        }
        func isNumber(_ word: String) -> Bool {
            if let part = lexicon.words[word] { return part != .and }
            return lexicon.joins && word.count > 4 && Reader.split(word, lexicon: lexicon).map { Reader.reads($0, lexicon: lexicon) } == true
        }
        var replacements: [(NSRange, String)] = []
        var index = 0
        while index < tokens.count {
            guard isNumber(tokens[index].word) else { index += 1; continue }
            var start = index, end = index + 1
            while end < tokens.count, joined(end - 1, end) {
                if isNumber(tokens[end].word) { end += 1; continue }
                if lexicon.words[tokens[end].word] == .and, end + 1 < tokens.count, joined(end, end + 1), isNumber(tokens[end + 1].word) { end += 2; continue }
                break
            }
            // "a hundred": the article is the one.
            if start > 0, joined(start - 1, start), lexicon.articles.contains(tokens[start - 1].word),
               let first = lexicon.words[tokens[start].word], first == .hundred || first.isScale { start -= 1 }
            defer { index = end }
            let written = digits(tokens[start..<end].map(\.word), language: base)
            guard written.count == 1, let figure = written.first, let value = Int(figure), value < 1_000_000 else { continue }
            let previous = start > 0 && joined(start - 1, start) ? tokens[start - 1].word : nil
            let next = end < tokens.count && joined(end - 1, end) ? tokens[end].word : nil
            let afterNext = end + 1 < tokens.count && next != nil && joined(end, end + 1) ? tokens[end + 1].word : nil
            guard context.allows(value: value, previous: previous, next: next, afterNext: afterNext) else { continue }
            replacements.append((NSRange(location: tokens[start].range.location, length: NSMaxRange(tokens[end - 1].range) - tokens[start].range.location), figure))
        }
        let result = NSMutableString(string: text)
        for (range, figure) in replacements.reversed() { result.replaceCharacters(in: range, with: figure) }
        return result as String
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}]+)?"#)

    /// The words around a number that make a figure the norm.
    struct Context {
        let months: Set<String>, amounts: Set<String>, percent: (String, String?)
        let timeBefore: Set<String>, timeAfter: Set<String>, timeAfterPairs: Set<String>, yearBefore: Set<String>
        func allows(value: Int, previous: String?, next: String?, afterNext: String?) -> Bool {
            if let next, months.contains(next), (1...31).contains(value) { return true }
            if let next, amounts.contains(next) { return true }
            if let next, next == percent.0, percent.1 == nil || afterNext == percent.1 { return true }
            if let previous, timeBefore.contains(previous), value <= 24 {
                guard let next else { return true }
                if timeAfter.contains(next) { return true }
                if let afterNext, timeAfterPairs.contains(next + " " + afterNext) { return true }
            }
            if let previous, yearBefore.contains(previous), (1000...2100).contains(value) { return true }
            return false
        }
    }
    static let contexts: [String: Context] = [
        "it": Context(months: ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"],
                      amounts: ["euro", "dollari", "dollaro", "sterline", "sterlina", "franchi", "yen", "centesimi", "percento"],
                      percent: ("per", "cento"),
                      timeBefore: ["alle", "dalle", "ore", "verso"], timeAfter: ["meno", "precise", "in"],
                      timeAfterPairs: ["e mezza", "e mezzo", "e un", "e venti", "e dieci", "e cinque", "e quindici", "e trenta", "e quaranta", "e quarantacinque", "di mattina",
                                       "di sera", "di notte", "di pomeriggio", "del pomeriggio", "del mattino"],
                      yearBefore: ["nel", "dal", "del", "anno", "entro"]),
        "en": Context(months: ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"],
                      amounts: ["dollars", "dollar", "euros", "euro", "pounds", "cents", "percent", "bucks"],
                      percent: ("per", "cent"),
                      timeBefore: ["at", "by", "until", "around"], timeAfter: ["o’clock", "o'clock", "am", "pm", "sharp", "tonight", "tomorrow", "today"],
                      timeAfterPairs: ["in the", "this morning", "this afternoon", "this evening"],
                      yearBefore: ["in", "since", "year", "by"]),
    ]
}
