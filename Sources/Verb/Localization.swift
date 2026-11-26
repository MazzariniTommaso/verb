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
        return self("Pasted into \(app)", "Incollata in \(app)")
    }
    /// A size in bytes, in this language's numbers, whatever the Mac's own: "2.5 GB", "2,5 GB".
    func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file).locale(locale)) }
    func relativeTime(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute().locale(locale))
        if Calendar.current.isDateInToday(date) { return self("Today, \(time)", "Oggi, \(time)") }
        if Calendar.current.isDateInYesterday(date) { return self("Yesterday, \(time)", "Ieri, \(time)") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale)) + ", " + time
    }
    /// A speech model's name as people know it, not its identifier.
    func engine(_ id: String) -> String { SpeechCatalog.models.first { $0.id == id }?.name.replacingOccurrences(of: " · MLX", with: "") ?? id }
    func spokenLanguage(_ code: String) -> String {
        guard !code.isEmpty, code != "auto" else { return self("automatic language", "lingua automatica") }
        return locale.localizedString(forLanguageCode: code) ?? code.uppercased()
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
    /// Keys as written in this language, held together so a line never breaks between ⌃ and ⌥.
    func keys(_ label: String) -> String { (isItalian ? Self.italianKeys(label) : label).replacingOccurrences(of: " ", with: "\u{00A0}") }
    /// A key label with its key names as Italian Macs print them.
    static func italianKeys(_ label: String) -> String {
        italianKeyNames.reduce(label) { text, pair in text.replacingOccurrences(of: #"\b"# + pair.0 + #"\b"#, with: pair.1, options: .regularExpression) }
    }
    /// The key names as Italian Macs print them, the two-word ones first.
    private static let italianKeyNames = [("Page Up", "Pagina su"), ("Page Down", "Pagina giù"), ("Space", "Spazio"), ("Return", "Invio"), ("Delete", "Elimina"), ("Home", "Inizio"), ("End", "Fine"), ("Key", "Tasto")]
    /// Keys inside a sentence, held together so a line never breaks between ⌃ and ⌥.
    func inlineKeys(_ label: String) -> String { keys(label).replacingOccurrences(of: " ", with: "\u{00A0}") }
    /// A binding's keys as written in this language, or "no keys" when it has none.
    func keys(_ binding: KeyBinding?) -> String { binding.map { keys($0.label) } ?? self("no keys", "nessun tasto") }
    /// The keys as words, for VoiceOver and Voice Control: "Control Option 1", "Controllo Opzione 1".
    func spokenKeys(_ binding: KeyBinding?) -> String {
        guard let binding else { return self("no keys", "nessun tasto") }
        var words: [String] = []
        if binding.modifiers.contains(.function) { words.append("fn") }
        if binding.modifiers.contains(.control) { words.append(self("Control", "Controllo")) }
        if binding.modifiers.contains(.option) { words.append(self("Option", "Opzione")) }
        if binding.modifiers.contains(.shift) { words.append(self("Shift", "Maiuscole")) }
        if binding.modifiers.contains(.command) { words.append(self("Command", "Comando")) }
        if binding.keyCode != nil, let key = binding.parts.last {
            let arrows = ["←": self("Left Arrow", "Freccia sinistra"), "→": self("Right Arrow", "Freccia destra"), "↑": self("Up Arrow", "Freccia su"), "↓": self("Down Arrow", "Freccia giù"), "⌦": self("Forward Delete", "Cancella avanti")]
            words.append(arrows[key] ?? keys(key))
        }
        return words.joined(separator: " ")
    }
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
    func title(_ t: Lang) -> String { self == .onDevice ? t("On this Mac", "Su questo Mac") : t("External server", "Server esterno") }
    func detail(_ t: Lang) -> String {
        self == .onDevice ? t("Offline, on the Mac’s own chip. Audio never leaves the Mac.", "Offline, sul chip del Mac. L’audio non esce dal Mac.") : t("Sends the audio to a server you choose.", "Invia l’audio a un server che scegli tu.")
    }
}
extension CleanupProvider {
    func title(_ t: Lang) -> String {
        switch self {
        case .local: return t("On this Mac", "Su questo Mac")
        case .harness: return t("My subscriptions", "I miei abbonamenti")
        case .endpoint: return t("External server", "Server esterno")
        case .off: return t("No AI cleanup", "Nessuna rifinitura AI")
        }
    }
    func detail(_ t: Lang) -> String {
        switch self {
        case .local: return t("A private Ollama model, offline.", "Un modello Ollama privato, offline.")
        case .harness: return t("Claude Code, Codex, Cursor, Gemini or Copilot.", "Claude Code, Codex, Cursor, Gemini o Copilot.")
        case .endpoint: return t("Any server that works like OpenAI’s.", "Qualsiasi server compatibile con OpenAI.")
        case .off: return t("Keep the words exactly as heard.", "Le parole restano come sono state sentite.")
        }
    }
}
extension OverlayStyle {
    func title(_ t: Lang) -> String {
        switch self {
        case .classic: return t("Classic", "Classica")
        case .pill: return t("Pill", "Pillola")
        case .ink: return t("Voice", "Voce")
        case .dot: return t("Dot", "Punto")
        case .bar: return t("Bar", "Barra")
        case .notch: return t("Notch", "Notch")
        }
    }
    func detail(_ t: Lang) -> String {
        switch self {
        case .classic: return t("The red dot, your voice, the time, the key to finish and Stop.", "Il punto rosso, la voce, il tempo, il tasto per finire e Ferma.")
        case .pill: return t("The red dot and your voice. Stop appears when you point at it.", "Il punto rosso e la voce. Ferma compare quando ci passi sopra.")
        case .ink: return t("Your voice alone, as four dots that stretch as you speak.", "Solo la voce, quattro punti che si allungano mentre parli.")
        case .dot: return t("One circle with your voice inside it. The smallest.", "Un cerchio con la voce dentro. Il più piccolo.")
        case .bar: return t("The red dot, the time and your voice, on one slim line.", "Il punto rosso, il tempo e la voce, su una riga sottile.")
        case .notch: return t("A black island at the notch: symbols beside it, your words below it.", "Un’isola nera al notch: simboli accanto, le parole sotto.")
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
    /// The language's own name in the interface language, with a capital as in a menu: "Tedesco", "German".
    func title(_ t: Lang) -> String {
        guard self != .auto else { return t("Detect automatically", "Rileva automaticamente") }
        let name = t.locale.localizedString(forLanguageCode: rawValue) ?? rawValue
        return name.prefix(1).uppercased(with: t.locale) + name.dropFirst()
    }
}
extension WritingStyle {
    func title(_ t: Lang) -> String {
        switch self { case .natural: return t("Natural", "Naturale"); case .casual: return t("Casual", "Informale"); case .formal: return t("Formal", "Formale"); case .verbatim: return t("Verbatim", "Alla lettera"); case .custom: return t("Custom", "Personalizzato"); case .lowercase: return t("Lowercase", "Minuscolo") }
    }
    func detail(_ t: Lang) -> String {
        switch self {
        case .natural: return t("Your words, with fillers and clear self-corrections cleaned up.", "Le tue parole, senza intercalari e con le autocorrezioni risolte.")
        case .casual: return t("Conversational messages, with lighter punctuation.", "Messaggi colloquiali, con una punteggiatura più leggera.")
        case .formal: return t("Careful grammar and complete sentences. Your meaning stays yours.", "Grammatica curata e frasi complete. Il senso resta il tuo.")
        case .verbatim: return t("The speech engine’s wording, with no AI rewriting.", "Le parole del riconoscimento, senza riscrittura AI.")
        case .custom: return t("How you describe it, in your own words.", "Come lo descrivi tu, con parole tue.")
        case .lowercase: return t("Small letters and light punctuation, as in a chat with friends.", "Minuscole e punteggiatura leggera, come in chat con gli amici.")
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
extension AppCategory {
    func title(_ t: Lang) -> String {
        switch self {
        case .email: return t("Email", "Email")
        case .work: return t("Work chats", "Chat di lavoro")
        case .personal: return t("Personal chats", "Chat personali")
        case .other: return t("Everything else", "Tutto il resto")
        }
    }
    func detail(_ t: Lang) -> String {
        switch self {
        case .email: return t("Mail, Outlook, Gmail and other mail apps.", "Mail, Outlook, Gmail e le altre app di posta.")
        case .work: return t("Slack, Teams, LinkedIn, Jira.", "Slack, Teams, LinkedIn, Jira.")
        case .personal: return t("Messages, WhatsApp, Telegram, Signal.", "Messaggi, WhatsApp, Telegram, Signal.")
        case .other: return t("Every other app and site.", "Ogni altra app e sito.")
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
            case .ask: return t("Thinking", "Ci penso")
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
        case .recording: return activeMode == .command ? t("Say your edit", "Di’ la modifica") : activeMode == .ask ? t("Ask or say what to write", "Chiedi o di’ cosa scrivere") : t("Go ahead", "Parla pure")
        case .transcribing: return t("Writing it down", "Trascrivo") + progressSuffix(t)
        case .polishing: return t("Tidying up", "Rifinisco") + progressSuffix(t)
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
    /// How the last dictation ended, in a sentence for VoiceOver.
    func announcement(_ t: Lang) -> String {
        switch outcome {
        case .delivered:
            if asSaid { return t("Pasted as said: the writing model didn’t answer", "Incollata com’era: il modello di scrittura non ha risposto") }
            return t.outcome(status) + ", " + t.count(latestText.split(whereSeparator: \.isWhitespace).count, "word", "words", "parola", "parole")
        case .copyOnly: return t("Not pasted: ", "Non incollata: ") + t.message(status)
        case .failed: return t("The dictation didn’t work. ", "La dettatura non è riuscita. ") + (notice.map { t.message($0) } ?? "")
        case .cancelled: return t("Cancelled", "Annullata")
        case .empty: return t("No speech heard", "Nessuna voce sentita")
        case .copied: return t("Copied", "Copiata")
        case .hint, .learned: return t.message(status)
        case .none: return ""
        }
    }
    /// Without Accessibility neither Space nor Escape reaches Verb: the buttons to finish and
    /// cancel stay in sight instead of waiting for the pointer.
    var keysCantFinish: Bool { runsServices && !accessibilityGranted }
    /// fn is a dictation key, and the Mac may also act on 🌐 (fn) by itself: emoji, another input
    /// source or macOS dictation. Keyboard settings keep the choice; nothing is the only one that
    /// leaves fn to Verb, and a Mac that never chose may still act.
    var globeKeyConflict: Bool {
        let fn = [settings.keyOptions.dictation, settings.keyOptions.voiceEdit].contains { $0?.isModifierOnly == true && $0?.modifiers.contains(.function) == true }
        return fn && (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int) != 0
    }
    /// What quitting now would stop, said before Verb quits; nil when nothing is under way.
    func quitWouldInterrupt(_ t: Lang) -> (title: String, detail: String, keep: String)? {
        if case .recording = meeting {
            return (t("A meeting is being recorded", "C’è una riunione in registrazione"),
                    t("Quit now and the recording stops here. Its notes are written at the next launch.", "Se esci ora la registrazione si ferma qui. Le note vengono scritte al prossimo avvio."),
                    t("Keep recording", "Continua a registrare"))
        }
        if busy {
            return (t("A dictation is under way", "C’è una dettatura in corso"),
                    t("Quit now and it stops. What you said stays in History, to retry.", "Se esci ora si ferma. Quello che hai detto resta nella Cronologia, da riprovare."),
                    t("Keep dictating", "Continua a dettare"))
        }
        if downloadingSpeech || downloadingWriter {
            return (t("A model is downloading", "C’è un modello in download"),
                    t("Quit now and the download stops.", "Se esci ora il download si ferma."),
                    t("Keep downloading", "Continua il download"))
        }
        return nil
    }
    /// How far a download has come and how long it still needs: "1.2 of 2.5 GB · about 4 min left".
    func downloadDetail(_ t: Lang) -> String {
        var parts: [String] = []
        if downloadingSpeech, let size = try? SpeechCatalog.model(settings.localModel).downloadBytes {
            let done = Int64(Double(size) * min(1, downloadProgress / 0.92))
            parts.append(t("\(t.size(done)) of \(t.size(size))", "\(t.size(done)) di \(t.size(size))"))
        }
        let end = downloadingSpeech ? 0.92 : 1
        if let baseline = downloadBaseline, downloadProgress > baseline.progress, downloadProgress < end {
            let rate = (downloadProgress - baseline.progress) / Date().timeIntervalSince(baseline.date)
            let minutes = Int(((end - downloadProgress) / rate / 60).rounded(.up))
            if rate > 0, minutes < 600 { parts.append(minutes <= 1 ? t("about a minute left", "circa un minuto") : t("about \(minutes) min left", "circa \(minutes) min")) }
        }
        return parts.joined(separator: " · ")
    }
    /// The menu's first line: what Verb is doing, or what keeps it from working. A problem with
    /// the keys or the setup comes before Ready, so the menu never says Ready when dictating can't work.
    func menuStatus(_ t: Lang) -> (title: String, hint: String, problem: Bool) {
        if busy { return (phaseTitle(t), startHint(t), false) }
        if case .recording(let started) = meeting {
            return (t("Recording a meeting", "Riunione in registrazione") + " · " + clock(Date().timeIntervalSince(started)), t("Stop it here to write the notes", "Terminala da qui per scrivere le note"), false)
        }
        let setup = t("Setup not finished", "Configurazione da finire")
        if runsServices, !accessibilityGranted { return (t("Keys off", "Tasti disattivati"), t("Allow Accessibility to use Verb’s keys", "Consenti l’Accessibilità per usare i tasti di Verb"), true) }
        if let app = keysBlockedBy {
            let name = app.isEmpty ? t("Another app", "Un’altra app") : app
            return (t("Keys blocked", "Tasti bloccati"), t("\(name) has secure input on", "\(name) ha l’input sicuro attivo"), true)
        }
        if !microphoneGranted { return (setup, t("Allow the microphone to dictate", "Consenti il microfono per dettare"), true) }
        if settings.speechProvider != .endpoint, !speechInstalled { return (setup, t("Download the speech model in Models", "Scarica il modello vocale in Modelli"), true) }
        return (voiceListening ? t("Listening", "In ascolto") : t("Ready", "Pronto"), startHint(t), false)
    }
    /// How far long work has come, as a percentage after the words; nothing for short work.
    private func progressSuffix(_ t: Lang) -> String {
        guard let workProgress else { return "" }
        return " · " + workProgress.formatted(.percent.precision(.fractionLength(0)).locale(t.locale))
    }
    /// The recording is in its last minute: it ends by itself at the limit.
    var lastMinute: Bool {
        let limit = startedByVoice ? min(longestDictation, AppModel.longestVoiceDictation) : longestDictation
        return phase == .recording && elapsed >= limit - 60
    }
    /// Minutes and seconds, or hours too, as a running clock shows them.
    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds)), hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
    func startHint(_ t: Lang) -> String {
        guard voiceListening else { return shortcutHint(t) }
        let name = settings.voiceOptions.spokenName
        guard let binding = settings.keyOptions.dictation else { return t("Say “Hey \(name)”", "Di’ “Ehi \(name)”") }
        let keys = t.keys(binding.label)
        return t("Hold \(keys) or say “Hey \(name)”", "Tieni premuto \(keys) o di’ “Ehi \(name)”")
    }
}
