import SwiftUI
import VerbCore
import VerbEngine

/// The interface language. Views read it from the environment and call it with both
/// strings, so the English and the Italian text always sit side by side at the call site.
struct Lang: Equatable {
    var language: InterfaceLanguage
    var isItalian: Bool { language == .italian }
    func callAsFunction(_ english: String, _ italian: String) -> String { isItalian ? italian : english }
    /// Dates and numbers follow the language, so one screen never mixes "1,4 s" with "2.51 GB".
    /// English uses British conventions: day before month, decimal point.
    var locale: Locale { Locale(identifier: isItalian ? "it_IT" : "en_GB") }
    /// The engine and the core library write their messages in English. Known ones are
    /// translated here at display time, so stored history reads correctly in either language,
    /// and typewriter apostrophes become typographic ones.
    func message(_ english: String) -> String { (isItalian ? Italian.translate(english) : english).replacingOccurrences(of: "'", with: "’") }
    /// How a dictation ended, as a person would say it. Delivery is recorded as "Paste sent to <App>":
    /// Verb sends ⌘V only after checking the field is still the one you dictated into.
    func outcome(_ status: String) -> String {
        let prefix = "Paste sent to "
        guard status.hasPrefix(prefix) else { return message(status) }
        let app = String(status.dropFirst(prefix.count))
        return self("Pasted into \(app)", "Incollato in \(app)")
    }
    func relativeTime(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute().locale(locale))
        if Calendar.current.isDateInToday(date) { return self("Today, \(time)", "Oggi, \(time)") }
        if Calendar.current.isDateInYesterday(date) { return self("Yesterday, \(time)", "Ieri, \(time)") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale)) + ", " + time
    }
    /// A speech model's name as people know it, not its identifier.
    func engine(_ id: String) -> String { SpeechCatalog.models.first { $0.id == id }?.name.replacingOccurrences(of: " · MLX", with: "") ?? id }
    func spokenLanguage(_ code: String) -> String {
        switch code { case "it": return self("Italian", "italiano"); case "en": return self("English", "inglese"); case "", "auto": return self("automatic language", "lingua automatica"); default: return code.uppercased() }
    }
    /// A recording's length in words people use, so it never reads like a clock time.
    func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        return total % 60 == 0 ? "\(total / 60) min" : "\(total / 60) min \(total % 60) s"
    }
    /// A date with its time, without the stiff "at" that the system format adds.
    func dateAndTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale)) + ", " + date.formatted(.dateTime.hour().minute().locale(locale))
    }
    /// Shortcut labels are stored with English key names; Italian shows them the Italian way.
    func keys(_ label: String) -> String {
        guard isItalian else { return label }
        return Self.italianKeys.reduce(label) { text, pair in text.replacingOccurrences(of: #"\b"# + pair.0 + #"\b"#, with: pair.1, options: .regularExpression) }
    }
    /// The key names as Italian Macs print them, the two-word ones first.
    private static let italianKeys = [("Page Up", "Pagina su"), ("Page Down", "Pagina giù"), ("Space", "Spazio"), ("Return", "Invio"), ("Delete", "Elimina"), ("Home", "Inizio"), ("End", "Fine")]
    /// Keys inside a sentence, held together so a line never breaks between ⌃ and ⌥.
    func inlineKeys(_ label: String) -> String { keys(label).replacingOccurrences(of: " ", with: "\u{00A0}") }
    /// A binding's keys as written in this language, or "no keys" when it has none.
    func keys(_ binding: KeyBinding?) -> String { binding.map { keys($0.label) } ?? self("no keys", "nessun tasto") }
    func count(_ value: Int, _ englishOne: String, _ englishMany: String, _ italianOne: String, _ italianMany: String) -> String {
        let number = value.formatted(.number.locale(locale))
        return "\(number) " + (value == 1 ? self(englishOne, italianOne) : self(englishMany, italianMany))
    }
}

private struct LangKey: EnvironmentKey { static let defaultValue = Lang(language: .english) }
extension EnvironmentValues {
    var lang: Lang {
        get { self[LangKey.self] }
        set { self[LangKey.self] = newValue }
    }
}

extension InterfaceLanguage {
    /// Each language is always named in its own words.
    var nativeName: String { self == .english ? "English" : "Italiano" }
}
extension Appearance {
    func title(_ t: Lang) -> String {
        switch self { case .automatic: return t("Automatic", "Automatico"); case .light: return t("Light", "Chiaro"); case .dark: return t("Dark", "Scuro") }
    }
    var symbol: String {
        switch self { case .automatic: return "circle.lefthalf.filled"; case .light: return "sun.max"; case .dark: return "moon" }
    }
}
extension SpeechProvider {
    func title(_ t: Lang) -> String { self == .onDevice ? t("On this Mac", "Su questo Mac") : t("Hosted or custom server", "Server ospitato o personale") }
    func detail(_ t: Lang) -> String {
        self == .onDevice ? t("Offline with MLX. Audio never leaves the Mac.", "Offline con MLX. L’audio non esce dal Mac.") : t("Send audio to an endpoint you choose.", "Invia l’audio a un endpoint che scegli tu.")
    }
}
extension CleanupProvider {
    func title(_ t: Lang) -> String {
        switch self {
        case .local: return t("On this Mac", "Su questo Mac")
        case .harness: return t("My subscriptions", "I miei abbonamenti")
        case .endpoint: return t("Hosted or custom server", "Server ospitato o personale")
        case .off: return t("No AI cleanup", "Nessuna rifinitura AI")
        }
    }
    func detail(_ t: Lang) -> String {
        switch self {
        case .local: return t("A private Ollama model, offline.", "Un modello Ollama privato, offline.")
        case .harness: return t("Claude Code, Codex, Cursor, Gemini or Copilot.", "Claude Code, Codex, Cursor, Gemini o Copilot.")
        case .endpoint: return t("Any chat completions server.", "Qualsiasi server chat completions.")
        case .off: return t("Keep the words exactly as heard.", "Le parole restano come sono state sentite.")
        }
    }
}
extension OverlayStyle {
    func title(_ t: Lang) -> String {
        switch self {
        case .classic: return t("Classic", "Classica")
        case .pill: return t("Pill", "Pillola")
        case .ink: return t("Ink", "Inchiostro")
        case .dot: return t("Dot", "Punto")
        case .bar: return t("Bar", "Barra")
        }
    }
    func detail(_ t: Lang) -> String {
        switch self {
        case .classic: return t("What is happening, how to finish, the ink stroke and a stop button.", "Cosa succede, come finire, l’onda e il tasto stop.")
        case .pill: return t("The red dot and the ink stroke. The stop button appears when you point at it.", "Il punto rosso e l’onda. Lo stop compare quando ci passi sopra.")
        case .ink: return t("The ink stroke alone, with a red nib where the new ink appears.", "Solo l’onda, con un pennino rosso dove nasce l’inchiostro.")
        case .dot: return t("One dot that breathes with your voice. The smallest.", "Un punto che respira con la tua voce. Il più piccolo.")
        case .bar: return t("The time and the ink stroke, on one slim line.", "Il tempo e l’onda, su una riga sottile.")
        }
    }
}
extension CleanupPolicy {
    func title(_ t: Lang) -> String {
        switch self { case .always: return t("Always", "Sempre"); case .whenNeeded: return t("When needed", "Solo se serve"); case .never: return t("Never", "Mai") }
    }
    func detail(_ t: Lang) -> String {
        switch self {
        case .always: return t("Every dictation goes through the writing model. The most polished, and the slowest.",
                               "Ogni dettatura passa dal modello di scrittura. La più curata, e la più lenta.")
        case .whenNeeded: return t("The text goes in at once. The model steps in only when you correct yourself (“actually”, “I mean”), dictate a list or speak for more than about 80 words.",
                                   "Il testo entra subito. Il modello interviene solo quando ti correggi (“anzi”, “no scusa”), detti un elenco o parli per più di circa 80 parole.")
        case .never: return t("Only the recognized words, your dictionary and the quick rules. Transforms and voice edits still use the model.",
                              "Solo le parole riconosciute, il tuo dizionario e le regole rapide. Trasformazioni e modifiche a voce usano comunque il modello.")
        }
    }
}
extension DictationLanguage {
    func title(_ t: Lang) -> String {
        switch self { case .auto: return t("Detect automatically", "Rileva automaticamente"); case .it: return "Italiano"; case .en: return "English" }
    }
}
extension WritingStyle {
    func title(_ t: Lang) -> String {
        switch self { case .natural: return t("Natural", "Naturale"); case .casual: return t("Casual", "Informale"); case .formal: return t("Formal", "Formale"); case .verbatim: return t("Verbatim", "Alla lettera") }
    }
    func detail(_ t: Lang) -> String {
        switch self {
        case .natural: return t("Your words, with fillers and clear self-corrections cleaned up.", "Le tue parole, senza intercalari e con le autocorrezioni risolte.")
        case .casual: return t("Conversational messages, with lighter punctuation.", "Messaggi colloquiali, con una punteggiatura più leggera.")
        case .formal: return t("Careful grammar and complete sentences. Your meaning stays yours.", "Grammatica curata e frasi complete. Il senso resta il tuo.")
        case .verbatim: return t("The speech engine’s wording, with no AI rewriting.", "Le parole del riconoscimento, senza riscrittura AI.")
        }
    }
}
extension Retention {
    func title(_ t: Lang) -> String {
        switch self {
        case .none: return t("Don’t keep history", "Non conservare")
        case .day: return t("24 hours", "24 ore")
        case .week: return t("7 days", "7 giorni")
        case .month: return t("30 days", "30 giorni")
        case .forever: return t("Until I delete it", "Finché non la elimino")
        }
    }
}
extension Page {
    func title(_ t: Lang) -> String {
        switch self {
        case .home: return "Home"
        case .history: return t("History", "Cronologia")
        case .notes: return t("Notes", "Note")
        case .dictionary: return t("Dictionary", "Dizionario")
        case .snippets: return t("Snippets", "Frasi pronte")
        case .transforms: return t("Transforms", "Trasformazioni")
        case .models: return t("Models", "Modelli")
        case .settings: return t("Settings", "Impostazioni")
        }
    }
}

extension AppModel {
    var lang: Lang { Lang(language: settings.interfaceOptions.language) }
    /// What the overlay, the menu and VoiceOver say for the current phase.
    func phaseTitle(_ t: Lang) -> String {
        // A voice edit or a transform says what it does for as long as it runs.
        if let rewrite, modelAtWork {
            switch rewrite {
            case .voiceEdit: return t("Applying your edit", "Applico la modifica")
            case .transform(let name): return name
            }
        }
        switch phase {
        case .idle:
            switch outcome {
            case .cancelled: return t("Cancelled", "Annullata")
            case .copied: return t("Copied to clipboard", "Copiata negli appunti")
            default: return t.outcome(status)
            }
        case .authorizing: return t("Getting the microphone ready", "Preparo il microfono")
        case .recording: return activeMode == .command ? t("Say your edit", "Di’ la modifica") : t("Go ahead", "Parla pure")
        case .transcribing: return t("Writing it down", "Trascrivo")
        case .polishing: return t("Tidying up", "Metto in bella")
        case .inserting: return t("Placing the text", "Inserisco il testo")
        case .cancelling: return t("Cancelling", "Annullo")
        }
    }
    func location(_ t: Lang) -> String {
        if settings.cleanupProvider == .harness { return t("Text via ", "Testo via ") + settings.harnessOptions.provider.title }
        return settings.speechProvider == .onDevice && settings.cleanupProvider != .endpoint ? t("On this Mac", "Su questo Mac") : t("Your chosen provider", "Il fornitore scelto")
    }
    func shortcutHint(_ t: Lang) -> String {
        guard let binding = settings.keyOptions.dictation else { return t("Choose dictation keys in Settings", "Scegli i tasti per dettare nelle Impostazioni") }
        let keys = t.keys(binding.label)
        return t("Hold \(keys) to dictate", "Tieni premuto \(keys) per dettare")
    }
    /// How to start, in one line: the keys, and the phrase when Verb is listening for it.
    func startHint(_ t: Lang) -> String {
        guard voiceListening else { return shortcutHint(t) }
        let name = settings.voiceOptions.spokenName
        guard let binding = settings.keyOptions.dictation else { return t("Say “Hey \(name)”", "Di’ “Ehi \(name)”") }
        let keys = t.keys(binding.label)
        return t("Hold \(keys) or say “Hey \(name)”", "Tieni premuto \(keys) o di’ “Ehi \(name)”")
    }
}
