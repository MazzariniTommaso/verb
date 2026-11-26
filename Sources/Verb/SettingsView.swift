import SwiftUI
import UniformTypeIdentifiers
import VerbCore

/// The pages of Settings, one at a time.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, dictation, audio, keyboard, voice, styles, meetings, privacy, advanced
    var id: String { rawValue }
    func title(_ t: Lang) -> String {
        switch self {
        case .general: return t("General", "Generale")
        case .dictation: return t("Dictation", "Dettatura")
        case .audio: return t("Audio", "Audio")
        case .keyboard: return t("Keyboard", "Tastiera")
        case .voice: return t("Voice", "Voce")
        case .styles: return t("Styles", "Stili")
        case .meetings: return t("Meetings", "Riunioni")
        case .privacy: return t("Privacy", "Privacy")
        case .advanced: return t("Advanced", "Avanzate")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "text.cursor"
        case .audio: return "mic"
        case .keyboard: return "keyboard"
        case .voice: return "waveform"
        case .styles: return "textformat"
        case .meetings: return "person.2.wave.2"
        case .privacy: return "lock"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var clearConfirmation = false
    @State private var editingKeys: KeyEditing?
    @State private var testingMicrophones = false
    @State private var libraryNote: TransferNote?
    @State private var removingApp: String?
    @State private var showMissingApps = false
    var body: some View {
        // A form's column: a label stays within reach of its control however wide the window.
        PageScroll(cap: Sizing.columnForm) {
            PageHeader(rubric: nil, title: t("Settings", "Impostazioni"), detail: nil) { EmptyView() }
            SettingsTabs(selection: $model.settingsTab)
            // While a dictation runs only privacy can change, so remote processing can be turned off mid-way.
            Card { page(model.settingsTab) }
                .disabled(model.busy && model.settingsTab != .privacy)
                .id(model.settingsTab)
        }
        .confirmationDialog(t("Delete all dictation history and saved audio?", "Eliminare tutta la cronologia e l’audio salvato?"), isPresented: $clearConfirmation) {
            Button(t("Delete all history", "Elimina tutta la cronologia"), role: .destructive) { model.clearHistory() }
            Button(t("Cancel", "Annulla"), role: .cancel) {}
        } message: { Text(t("Your dictionary, snippets, models and settings stay.", "Dizionario, frasi pronte, modelli e impostazioni restano.")) }
        .confirmationDialog(t("Remove the style for \(removingApp.map(appName) ?? "")?", "Togliere lo stile per \(removingApp.map(appName) ?? "")?"), isPresented: Binding(get: { removingApp != nil }, set: { if !$0 { removingApp = nil } }), presenting: removingApp) { bundleID in
            Button(t("Remove", "Togli"), role: .destructive) { model.settings.appStyles.removeValue(forKey: bundleID); model.settings.stylePrompts.removeValue(forKey: bundleID) }
            Button(t("Cancel", "Annulla"), role: .cancel) {}
        } message: { _ in Text(t("Its dictations will use the default style.", "Le sue dettature useranno lo stile predefinito.")) }
        .confirmationDialog(pruneTitle, isPresented: Binding(get: { model.pendingPrune != nil }, set: { if !$0 { model.pendingPrune = nil } }), presenting: model.pendingPrune) { _ in
            Button(t("Delete", "Elimina"), role: .destructive) { model.confirmPrune() }
            Button(t("Keep everything", "Tieni tutto"), role: .cancel) { model.pendingPrune = nil }
        } message: { _ in Text(t("This can’t be undone. With the setting as it is, they expire in their own time.", "Non si può annullare. Con l’impostazione com’è, scadono a tempo debito.")) }
        .sheet(item: $editingKeys) { KeyCaptureSheet(target: $0.target).environmentObject(model).environment(\.lang, t) }
        .sheet(isPresented: $testingMicrophones) { MicrophoneTestSheet().environmentObject(model).environment(\.lang, t).environment(\.locale, t.locale) }
        .sheet(isPresented: $model.reporting) { ReportSheet().environmentObject(model).environment(\.lang, t).environment(\.locale, t.locale) }
    }

    @ViewBuilder private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: general
        case .dictation: dictation
        case .audio: audio
        case .keyboard: keyboard
        case .voice: voice
        case .styles: styles
        case .meetings: MeetingSettings()
        case .privacy: privacy
        case .advanced: advanced
        }
    }

    /// What a shorter history or audio turned off would delete now, in numbers.
    private var pruneTitle: String {
        guard let pending = model.pendingPrune else { return "" }
        var parts: [String] = []
        if pending.entries > 0 { parts.append(t.count(pending.entries, "dictation", "dictations", "dettatura", "dettature")) }
        if pending.recordings > 0 { parts.append(t.count(pending.recordings, "recording", "recordings", "registrazione", "registrazioni")) }
        return t("Delete \(parts.formatted(.list(type: .and).locale(t.locale))) now?", "Eliminare ora \(parts.formatted(.list(type: .and).locale(t.locale)))?")
    }
    private func note(_ text: String) -> some View {
        Text(text).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true).measure().padding(.vertical, Space.sm)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: t("Language", "Lingua")) {
                Segmented(title: t("Language", "Lingua"), values: InterfaceLanguage.allCases, selection: $model.settings.interfaceOptions.language, label: { $0.nativeName }).fixedSize()
            }
            Hairline()
            SettingRow(title: t("Appearance", "Aspetto")) {
                Segmented(title: t("Appearance", "Aspetto"), values: Appearance.allCases, selection: $model.settings.interfaceOptions.appearance, label: { $0.title(t) }, symbol: { $0.symbol }).fixedSize()
            }
            Hairline()
            OpenAtLoginSwitch()
            Hairline()
            SettingRow(title: t("Welcome and tour", "Introduzione e tour")) {
                HStack(spacing: Space.sm) {
                    Button(t("Show the welcome", "Rivedi l’introduzione")) { model.startWelcome() }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                    Button(t("Take the tour", "Fai il tour")) { model.startTour() }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                }
            }
            Hairline()
            SettingRow(title: t("Something not working?", "Qualcosa non va?"), detail: t("Describe it; Verb adds the details that help.", "Descrivilo; Verb aggiunge i dettagli che servono.")) {
                Button(t("Report a problem…", "Segnala un problema…")) { model.reporting = true }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            }
            Hairline()
            note(t("⌘W closes the window and Verb stays in the menu bar. Quit with ⌘Q.", "⌘W chiude la finestra e Verb resta nella barra dei menu. Esci con ⌘Q."))
        }
    }

    /// The languages the speech model on this Mac knows, in the interface language's order; any
    /// language with a server, which decides for itself. The chosen one stays listed.
    private var localSpeechModel: LocalSpeechModel? { model.settings.speechProvider == .onDevice ? try? SpeechCatalog.model(model.settings.localModel) : nil }
    private var spokenLanguages: [DictationLanguage] {
        let known = DictationLanguage.allCases.filter { $0 != .auto && (localSpeechModel?.recognizes($0) ?? true) || $0 == model.settings.language }
        return [.auto] + known.filter { $0 != .auto }.sorted { $0.title(t).localizedCompare($1.title(t)) == .orderedAscending }
    }
    private var languageWarning: String? {
        guard let speech = localSpeechModel, !speech.recognizes(model.settings.language) else { return nil }
        return t("\(t.engine(speech.id)) doesn’t know \(model.settings.language.title(t)). Choose another language or another model in Models.",
                 "\(t.engine(speech.id)) non conosce la lingua \(model.settings.language.title(t).lowercased(with: t.locale)). Scegli un’altra lingua o un altro modello in Modelli.")
    }

    private var dictation: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: t("Spoken language", "Lingua parlata"), detail: languageWarning) {
                VerbPicker(title: t("Spoken language", "Lingua parlata"), selection: $model.settings.language, options: spokenLanguages.map { ($0, $0.title(t)) })
                    .frame(width: 220)
            }
            Hairline()
            SwitchRow(title: t("Insert text into the app in front", "Inserisci il testo nell’app in primo piano"),
                      detail: t("With no text field in front, it waits as your last dictation.", "Senza un campo di testo davanti, resta come ultima dettatura."),
                      isOn: $model.settings.autoInsert)
                .help(t("What you had copied stays on the clipboard. The paste and copy keys reach the last dictation.", "Ciò che avevi copiato resta negli appunti. I tasti incolla e copia arrivano all’ultima dettatura."))
            Hairline()
            SwitchRow(title: t("Show the words as you speak", "Mostra le parole mentre parli"),
                      detail: t("A card above the overlay shows the text as it forms.", "Una scheda sopra la capsula mostra il testo man mano."),
                      isOn: $model.settings.livePreview)
                .disabled(!model.speechInstalled)
                .help(t("The lighter part is still being heard. The text that goes in comes from the whole recording.", "La parte più chiara si sta ancora formando. Il testo inserito viene dall’intera registrazione."))
            Hairline()
            SettingRow(title: t("Finish hands-free on silence", "Chiudi a mani libere col silenzio"), detail: t("A dictation started with fn + Space ends after this much quiet.", "Una dettatura avviata con fn + Spazio finisce dopo questo silenzio.")) {
                VerbPicker(title: t("Finish hands-free on silence", "Chiudi a mani libere col silenzio"), selection: $model.settings.handsFreeSilence,
                           options: [(0, t("Never", "Mai")), (5, "5 s"), (10, "10 s"), (20, "20 s"), (30, "30 s")])
                    .frame(width: 120)
            }
            .help(t("The last three seconds are counted down in the overlay: speak and it goes on.", "Gli ultimi tre secondi sono contati nella capsula: parla e continua."))
            Hairline()
            SettingRow(title: t("Overlay", "Capsula"), detail: model.settings.overlayStyle.detail(t)) {
                VerbPicker(title: t("Overlay", "Capsula"), selection: $model.settings.overlayStyle, options: OverlayStyle.allCases.map { ($0, $0.title(t)) })
                    .frame(width: 160)
            }
            .help(model.settings.overlayStyle == .classic ? "" : (model.keysCantFinish ? t("Without Accessibility its stop and cancel buttons stay in sight.", "Senza Accessibilità i pulsanti per terminare e annullare restano visibili.") : t("Space finishes and Escape cancels, as always.", "Spazio termina ed Esc annulla, come sempre.")))
            if model.settings.overlayStyle == .notch {
                Hairline()
                SwitchRow(title: t("Stay at the notch between dictations", "Resta al notch tra una dettatura e l’altra"),
                          detail: t("Point at it to see how to start, click it to dictate hands-free. A meeting shows beside it.", "Passaci sopra per vedere come iniziare, cliccalo per dettare a mani libere. Una riunione si vede accanto."),
                          isOn: $model.settings.notchAtRest)
            }
        }
    }

    /// The automatic choice in one line, and the microphone it would use now.
    private var microphoneDetail: String {
        guard model.settings.microphoneID.isEmpty else { return t("If it isn’t there, Verb chooses on its own.", "Se non c’è, Verb sceglie da solo.") }
        let order = model.settings.preferBuiltInMic ? t("Wired, this Mac, headphones, iPhone.", "Con filo, questo Mac, cuffie, iPhone.") : t("Wired, headphones, this Mac, iPhone.", "Con filo, cuffie, questo Mac, iPhone.")
        guard let now = model.automaticMicrophone else { return order }
        return order + " " + t("Now: \(now.name).", "Ora: \(now.name).")
    }

    private var audio: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: t("Microphone", "Microfono"), detail: microphoneDetail) {
                VerbPicker(title: t("Microphone", "Microfono"), selection: $model.settings.microphoneID,
                           options: [("", t("Automatic", "Automatico"))] + model.microphones.map { ($0.id, $0.name.isEmpty ? t("Microphone", "Microfono") : $0.name) })
                    .frame(width: 220)
            }
            if model.settings.microphoneID.isEmpty {
                Hairline()
                SwitchRow(title: t("This Mac’s microphone before headphones", "Il microfono del Mac prima delle cuffie"),
                          detail: t("Headphones hear you better, but sound like a call while you dictate.", "Le cuffie ti sentono meglio, ma mentre detti suonano come in una chiamata."),
                          isOn: $model.settings.preferBuiltInMic)
            }
            Hairline()
            SettingRow(title: t("Test the microphones", "Prova i microfoni"), detail: t("Find the one that hears you best.", "Scopri quello che ti sente meglio.")) {
                Button(t("Test…", "Prova…")) { model.refreshMicrophones(); testingMicrophones = true }.buttonStyle(VerbButtonStyle(kind: .secondary))
            }
            Hairline()
            SwitchRow(title: t("Play start and finish sounds", "Suoni di inizio e fine"), isOn: $model.settings.soundFeedback)
            Hairline()
            SwitchRow(title: t("Lower the sound while you dictate", "Abbassa l’audio mentre detti"),
                      detail: t("Music and videos drop while you speak, then come back.", "Musica e video si abbassano mentre parli, poi tornano."),
                      isOn: $model.settings.duckAudio)
                .help(t("Not during a call or with VoiceOver on. A volume you change in the meantime stays.", "Non durante una chiamata né con VoiceOver attivo. Se cambi il volume nel frattempo, resta il tuo."))
        }
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(KeyTarget.actions.enumerated()), id: \.offset) { index, target in
                if index > 0 { Hairline() }
                // fn + Space, which always works, comes before the keys that can be added for it.
                if target == .handsFree { HandsFreeChordRow(); Hairline() }
                KeyBindingRow(target: target, editing: $editingKeys)
            }
            if NSWorkspace.shared.isVoiceOverEnabled, model.settings.keyOptions.voiceEdit?.usesVoiceOverKeys == true {
                Hairline()
                StatusLabel(text: t("VoiceOver is on and uses ⌃ ⌥: voice edit waits until you choose other keys for it.", "VoiceOver è attivo e usa ⌃ ⌥: la modifica a voce aspetta che tu scelga altri tasti."), symbol: "exclamationmark.triangle", tone: .warning)
                    .padding(.vertical, Space.sm)
            }
            Hairline()
            note(t("Escape cancels. Each transform has its keys on the Transforms page.", "Esc annulla. Ogni trasformazione ha i suoi tasti nella pagina Trasformazioni."))
                .help(t("Keys chosen for one command are taken from any other that had them. fn and modifiers held on their own need Accessibility.", "I tasti scelti per un comando vengono tolti a quello che li aveva. fn e i modificatori da soli richiedono Accessibilità."))
        }
    }

    private var voice: some View {
        let name = model.settings.voiceOptions.spokenName
        return VStack(alignment: .leading, spacing: 0) {
            SwitchRow(title: t("Start with “Hey \(name)”", "Avvia con “Ehi \(name)”"),
                      detail: t("Dictate without touching the keyboard. The microphone stays on while Verb listens.", "Detti senza toccare la tastiera. Il microfono resta acceso mentre Verb ascolta."),
                      isOn: $model.settings.voiceOptions.wakeWord)
                .disabled(!model.speechInstalled)
                .help(t("Verb listens on this Mac and keeps nothing until it hears the phrase. It stops listening while the screen is locked or asleep.", "Verb ascolta su questo Mac e non conserva nulla finché non sente la frase. Smette di ascoltare a schermo bloccato o spento."))
            Hairline()
            SwitchRow(title: t("Finish with “Hey \(name) stop”", "Termina con “Ehi \(name) stop”"),
                      detail: t("End a hands-free dictation by voice, or throw it away.", "Chiudi a voce una dettatura a mani libere, o scartala."),
                      isOn: $model.settings.voiceOptions.stopCommands)
                .disabled(!model.speechInstalled)
            Hairline()
            VoiceWordsEditor()
            Hairline()
            VoiceTrialPanel()
            note(model.speechInstalled ? t("A dictation started by voice finishes after 20 seconds of silence.", "Una dettatura avviata a voce si chiude dopo 20 secondi di silenzio.")
                                       : t("Voice commands need the speech model on this Mac. Download it in Models.", "I comandi vocali richiedono il modello vocale su questo Mac. Scaricalo in Modelli."))
        }
    }

    /// Whether styles reach the dictations at all, and which ones, under the writing model and policy chosen in Models.
    @ViewBuilder private var stylesReach: some View {
        if model.settings.cleanupProvider == .off || model.settings.cleanupPolicy == .never {
            HStack(spacing: Space.sm) {
                StatusLabel(text: model.settings.cleanupProvider == .off ? t("There is no writing model, so styles don’t apply.", "Non c’è un modello di scrittura, quindi gli stili non si applicano.")
                                                                         : t("Refining is set to Never, so styles don’t apply.", "La rifinitura è su Mai, quindi gli stili non si applicano."),
                            symbol: "exclamationmark.triangle", tone: .warning)
                Spacer(minLength: Space.sm)
                Button(t("Open Models", "Apri Modelli")) { model.page = .models }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            }
            .padding(.vertical, Space.sm)
        } else {
            note(model.settings.cleanupPolicy == .always
                 ? t("Every dictation is refined in its app’s style.", "Ogni dettatura viene rifinita nello stile della sua app.")
                 : t("Apps with a style of their own are refined at every dictation; the others when the words call for it.", "Le app con uno stile proprio vengono rifinite a ogni dettatura; le altre quando le parole lo richiedono."))
        }
    }

    private var styles: some View {
        VStack(alignment: .leading, spacing: 0) {
            note(t("A style changes tone and form, never what you said. It goes by the app, or by the site in a browser.", "Lo stile cambia tono e forma, mai ciò che hai detto. Dipende dall’app, o dal sito nel browser."))
            stylesReach
            Hairline()
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(t("About you", "Su di te")).font(Typeface.text(TypeSize.body, .semibold)).foregroundStyle(Palette.textPrimary).accessibilityAddTraits(.isHeader)
                Text(t("Your name, your role, how you sign. Every rewrite and answer reads it.", "Il tuo nome, il ruolo, come firmi. Ogni rifinitura e risposta lo legge."))
                    .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
                VerbEditor(text: $model.settings.personalInstructions, minHeight: 72, label: t("About you", "Su di te"))
            }
            .padding(.vertical, Space.md)
            .help(t("Say “remember that…” with the command keys and nothing selected to add a line here.", "Di’ “ricorda che…” con i tasti di comando e nulla selezionato per aggiungere una riga qui."))
            Hairline()
            SettingRow(title: t("Default style", "Stile predefinito"), detail: model.settings.style.detail(t)) {
                VerbPicker(title: t("Default style", "Stile predefinito"), selection: $model.settings.style, options: WritingStyle.standard.map { ($0, $0.title(t)) })
                    .frame(width: 180)
            }
            ForEach(AppCategory.allCases.filter { $0 != .other }) { kind in
                Hairline()
                SettingRow(title: kind.title(t), detail: kind.detail(t)) {
                    VerbPicker(title: kind.title(t), selection: Binding(get: { model.settings.categoryStyles[kind] }, set: { model.settings.categoryStyles[kind] = $0 }),
                               options: [(nil, t("Default style", "Stile predefinito"))] + WritingStyle.standard.map { (Optional($0), $0.title(t)) })
                        .frame(width: 180)
                }
            }
            Hairline()
            HStack(alignment: .firstTextBaseline) {
                Text(t("Apps and sites", "App e siti")).font(Typeface.text(TypeSize.body, .semibold)).foregroundStyle(Palette.textPrimary).accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    ForEach(Places.sites.filter { model.settings.appStyles[$0.styleKey] == nil }, id: \.id) { site in
                        Button(site.name) { model.settings.appStyles[site.styleKey] = model.settings.style(for: "", site: site) }
                    }
                } label: { Label(t("Add site", "Aggiungi sito"), systemImage: "globe") }
                    .menuStyle(.button).buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).fixedSize()
                Button { addApp() } label: { Label(t("Add app…", "Aggiungi app…"), systemImage: "plus") }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            }
            .padding(.top, Space.md)
            appList
        }
    }

    /// Apps on this Mac and sites first; the apps it doesn't have wait behind a line of their own.
    private var appList: some View {
        let ids = model.settings.appStyles.keys.sorted { (Places.site(styleKey: $0) != nil ? 1 : 0, appName($0).lowercased()) < (Places.site(styleKey: $1) != nil ? 1 : 0, appName($1).lowercased()) }
        let installed = ids.filter { Places.site(styleKey: $0) != nil || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }, missing = ids.filter { !installed.contains($0) }
        return VStack(spacing: 0) {
            ForEach(Array((installed + (showMissingApps ? missing : [])).enumerated()), id: \.element) { index, bundleID in
                if index > 0 { Hairline() }
                AppStyleRow(bundleID: bundleID, name: appName(bundleID)) { removingApp = bundleID }
            }
            if !missing.isEmpty {
                Button(showMissingApps ? t("Hide the apps not on this Mac", "Nascondi le app non presenti")
                                       : t("Show \(t.count(missing.count, "app", "apps", "app", "app")) not on this Mac", "Mostra \(t.count(missing.count, "app", "apps", "app", "app")) non \(missing.count == 1 ? "presente" : "presenti") su questo Mac")) { showMissingApps.toggle() }
                    .buttonStyle(VerbButtonStyle(kind: .link, compact: true)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, Space.sm)
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 0) {
            SwitchRow(title: t("Allow remote processing", "Consenti l’elaborazione remota"),
                      detail: t("Only the providers you pick in Models receive anything.", "Ricevono dati solo i fornitori scelti in Modelli."),
                      isOn: $model.settings.allowRemoteProcessing)
                .help(t("Audio for recognition, text for cleanup. Turning this off cancels a running job; data already sent cannot be recalled.", "L’audio per il riconoscimento, il testo per la rifinitura. Spegnendo si annulla il lavoro in corso; i dati già inviati non si possono ritirare."))
            Hairline()
            Group {
                SettingRow(title: t("Keep history", "Conserva la cronologia")) {
                    VerbPicker(title: t("Keep history", "Conserva la cronologia"), selection: Binding(get: { model.settings.retention }, set: { model.proposeKeeping(retention: $0) }),
                               options: Retention.allCases.map { ($0, $0.title(t)) })
                        .frame(width: 220)
                }
                Hairline()
                SwitchRow(title: t("Keep audio", "Conserva l’audio"),
                          detail: t("To listen again and retry. Recordings expire after 14 days.", "Per riascoltare e riprovare. Le registrazioni scadono dopo 14 giorni."),
                          isOn: Binding(get: { model.settings.keepAudio }, set: { model.proposeKeeping(keepAudio: $0) }))
                    .disabled(model.settings.retention == .none)
                    .help(t("Meetings included, or sooner under your history setting. With audio off, only a dictation that failed keeps its recording, for Retry.", "Anche delle riunioni, o prima secondo la cronologia. Con l’audio spento resta solo quella di una dettatura non riuscita, per riprovare."))
                Hairline()
                HStack(spacing: Space.sm) {
                    Button { NSWorkspace.shared.open(model.paths.root) } label: { Label(t("Open data folder", "Apri la cartella dei dati"), systemImage: "folder") }.buttonStyle(VerbButtonStyle(kind: .secondary))
                    Spacer()
                    Button(role: .destructive) { clearConfirmation = true } label: { Label(t("Delete all history", "Elimina tutta la cronologia"), systemImage: "trash") }
                        .buttonStyle(VerbButtonStyle(kind: .danger)).disabled(model.history.isEmpty)
                }
                .padding(.vertical, Space.sm)
            }
            .disabled(model.busy)
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            SwitchRow(title: t("Fit the text to the cursor", "Adatta il testo al cursore"),
                      detail: t("Spacing, capitals and full stops follow the sentence around it.", "Spazi, maiuscole e punti seguono la frase intorno."),
                      isOn: $model.settings.fitToField)
                .help(t("Apps that don’t show their text to Verb, such as VS Code, get it as dictated.", "Le app che non mostrano il testo a Verb, come VS Code, lo ricevono come dettato."))
            Hairline()
            SwitchRow(title: t("Names from the field", "Nomi dal campo"),
                      detail: t("Spells names and terms as they are written on screen.", "Scrive nomi e termini come sono già scritti sullo schermo."),
                      isOn: $model.settings.namesFromField)
                .help(t("Verb reads the text around the cursor and the window’s title. Nothing is kept, keys and passwords are skipped, and the names reach a writing model only on this Mac.", "Verb legge il testo intorno al cursore e il titolo della finestra. Non conserva nulla, salta chiavi e password, e i nomi arrivano al modello di scrittura solo se gira su questo Mac."))
            Hairline()
            SwitchRow(title: t("English inside Italian", "Inglese nell’italiano"),
                      detail: t("“mercio” becomes merge, “bundolo” bundle.", "“mercio” diventa merge, “bundolo” bundle."),
                      isOn: $model.settings.restoreEnglish)
                .help(t("Only words that exist in neither language and sound like one of your English words. Verbs made Italian, like “fixa”, stay.", "Solo parole che non esistono in nessuna delle due lingue e suonano come una tua parola inglese. I verbi all’italiana, come “fixa”, restano."))
            Hairline()
            SwitchRow(title: t("Code names in editors", "Nomi di codice negli editor"),
                      detail: t("“user id” becomes userId, “app model dot swift” AppModel.swift.", "“user id” diventa userId, “app model punto swift” AppModel.swift."),
                      isOn: $model.settings.codeNames)
                .help(t("In editors and terminals Verb reads the open project. “camel case”, “snake case” and the like format the words that follow.", "Negli editor e nei terminali Verb legge il progetto aperto. “camel case”, “snake case” e simili formattano le parole che seguono."))
            Hairline()
            SwitchRow(title: t("Learn from your corrections", "Impara dalle tue correzioni"),
                      detail: t("A word you retype, or a name you say often, is offered to the Dictionary.", "Una parola che riscrivi, o un nome che dici spesso, ti viene proposta per il Dizionario."),
                      isOn: $model.settings.learnFromCorrections)
            Hairline()
            SwitchRow(title: t("Lists and bold for each app", "Elenchi e grassetto per ogni app"),
                      detail: t("Formatted in mail and documents, plain in chats, as written in editors.", "Formattati in posta e documenti, semplici nelle chat, come scritti negli editor."),
                      isOn: $model.settings.formatForApp)
            Hairline()
            SwitchRow(title: t("Requests read the screen", "Le richieste leggono lo schermo"),
                      detail: t("Asking with nothing selected, a writing model on this Mac reads the window’s text.", "Chiedendo senza selezione, un modello di scrittura su questo Mac legge il testo della finestra."),
                      isOn: $model.settings.askReadsScreen)
                .help(t("What you are replying to, the names, the tone. Nothing is kept, and a server never gets it.", "A cosa rispondi, i nomi, il tono. Non si conserva nulla e un server non lo riceve mai."))
            Hairline()
            SettingRow(title: t("Permissions", "Autorizzazioni")) {
                HStack(spacing: Space.sm) {
                    permission(model.microphoneGranted, t("Microphone", "Microfono")) { model.requestMicrophone() }
                    permission(model.accessibilityGranted, t("Accessibility", "Accessibilità")) { model.requestAccessibility() }
                }
            }
            Hairline()
            SettingRow(title: t("Dictionary and snippets", "Dizionario e frasi pronte"), detail: t("Move them to another Mac.", "Portali su un altro Mac.")) {
                HStack(spacing: Space.sm) {
                    Button(t("Export", "Esporta")) { exportLibrary() }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                    Button(t("Import", "Importa")) { importLibrary() }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                }
            }
            if let libraryNote { TransferNoteView(note: libraryNote) { self.libraryNote = nil }.padding(.bottom, Space.md) }
            Hairline()
            SettingRow(title: t("Notes folder", "Cartella delle note"), detail: t("Markdown files: iCloud Drive or an Obsidian vault work too.", "File Markdown: vanno bene anche iCloud Drive o un vault di Obsidian.")) {
                HStack(spacing: Space.sm) {
                    if !model.settings.notesPath.isEmpty { Button(t("Use Verb’s folder", "Usa la cartella di Verb")) { model.settings.notesPath = ""; model.openNote = nil; model.reloadNotes() }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true)) }
                    Button(t("Choose…", "Scegli…")) { model.chooseNotesFolder() }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                }
            }
            // The path on one line, in monospace, shortened in the middle where it must be.
            HStack(spacing: Space.sm) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Palette.textSecondary).accessibilityHidden(true)
                Text(model.notesFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(Typeface.mono(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: Space.sm)
                Button(t("Show in Finder", "Mostra nel Finder")) { NSWorkspace.shared.activateFileViewerSelecting([model.notesFolder]) }.buttonStyle(VerbButtonStyle(kind: .link, compact: true))
            }
            .padding(.bottom, Space.sm)
        }
    }

    private func permission(_ granted: Bool, _ title: String, request: @escaping () -> Void) -> some View {
        Group {
            if granted { StatusLabel(text: title, symbol: "checkmark.circle", tone: .success) }
            else { Button(title, action: request).buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)) }
        }
    }
    /// Installed apps are named by macOS; the defaults Verb ships with are named here when they are not installed.
    private func appName(_ id: String) -> String {
        if let site = Places.site(styleKey: id) { return site.name }
        let known = ["com.apple.MobileSMS": "Messages", "net.whatsapp.WhatsApp": "WhatsApp", "com.tinyspeck.slackmacgap": "Slack", "com.apple.mail": "Mail",
                     "com.microsoft.Outlook": "Microsoft Outlook", "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm2"]
        // The name Finder shows, in the Mac's language: “Messaggi”, “Terminale”.
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? known[id] ?? id
    }
    private func addApp() {
        let panel = NSOpenPanel(); panel.prompt = t("Add", "Aggiungi"); panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url)?.bundleIdentifier { model.settings.appStyles[bundle] = model.settings.style }
    }
    private func exportLibrary() {
        let panel = NSSavePanel(); panel.prompt = t("Export", "Esporta"); panel.nameFieldStringValue = t("Verb-library.json", "Verb-libreria.json"); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { do { try JSONStore.save(model.library, to: url) } catch { libraryNote = TransferNote(text: t.message(error.localizedDescription), failed: true) } }
    }
    private func importLibrary() {
        let panel = NSOpenPanel(); panel.prompt = t("Import", "Importa"); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url); guard data.count < 2_000_000 else { throw VerbError("The library file is too large.") }
                let incoming = try JSONDecoder().decode(Library.self, from: data)
                var updated = model.library
                // The same rules as the Dictionary and Snippets pages: only what is new, nothing that clashes.
                let words = LibraryTransfer.merge(incoming.vocabulary, into: &updated.vocabulary, snippets: updated.snippets)
                let phrases = LibraryTransfer.merge(incoming.snippets, into: &updated.snippets, vocabulary: updated.vocabulary)
                if updated != model.library { model.library = updated }
                libraryNote = TransferNote(text: t.count(words.added, "word", "words", "parola", "parole") + " · " + t.count(phrases.added, "snippet added", "snippets added", "frase aggiunta", "frasi aggiunte"))
            } catch { libraryNote = TransferNote(text: t.message(error.localizedDescription), failed: true) }
        }
    }
}

/// The pages of Settings as a row of tabs, each an icon over its name.
private struct SettingsTabs: View {
    @Binding var selection: SettingsTab
    @Environment(\.lang) private var t
    var body: some View {
        // One row while every name fits whole; in a narrow window, a menu of the sections rather
        // than a block of tabs that pushes the settings down.
        ViewThatFits(in: .horizontal) {
            EqualWidths(spacing: Space.xs) {
                ForEach(SettingsTab.allCases) { tab in SettingsTabButton(tab: tab, selected: tab == selection) { selection = tab } }
            }
            .padding(Space.xs)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.borderSubtle))
            HStack(spacing: Space.md) {
                Text(t("Section", "Sezione")).font(Typeface.text(TypeSize.body, .semibold)).foregroundStyle(Palette.textPrimary)
                VerbPicker(title: t("Section", "Sezione"), selection: $selection, options: SettingsTab.allCases.map { ($0, $0.title(t)) })
                    .frame(width: 220)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(t("Settings pages", "Pagine delle impostazioni"))
    }
}
private struct SettingsTabButton: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void
    @Environment(\.lang) private var t
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                // Every icon in the same box, so the names share one baseline.
                Image(systemName: tab.symbol).font(.system(size: 15, weight: selected ? .semibold : .regular)).frame(width: 22, height: 18)
                Text(tab.title(t)).font(Typeface.text(TypeSize.caption, selected ? .semibold : .medium)).lineLimit(1)
            }
            .padding(.horizontal, Space.sm)
            .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
            .frame(maxWidth: .infinity, minHeight: Sizing.controlMin)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(selected ? Palette.surfaceRaised : (hovering ? Palette.fillHover : .clear))
                    .shadow(color: selected ? Palette.shadow.opacity(0.35) : .clear, radius: 2, y: 1)
            }
            .overlay { if selected { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.borderSubtle) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .onPointerOver { hovering = $0 }
        .animation(.easeOut(duration: Motion.fast), value: hovering)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
    }
}

/// One app with a style of its own: its style and, for Custom, what to write there.
private struct AppStyleRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let bundleID: String
    let name: String
    let remove: () -> Void
    var body: some View {
        let site = Places.site(styleKey: bundleID)
        let location = site == nil ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) : nil
        let style = model.settings.appStyles[bundleID] ?? .natural
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.md) {
                Group {
                    if let location { Image(nsImage: NSWorkspace.shared.icon(forFile: location.path)).resizable() }
                    else if site != nil { Image(systemName: "globe").font(.system(size: 17, weight: .light)).foregroundStyle(Palette.textSecondary) }
                    else { Image(systemName: "app.dashed").font(.system(size: 18, weight: .light)).foregroundStyle(Palette.textTertiary) }
                }
                .frame(width: 24, height: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Typeface.text(TypeSize.body, .medium)).foregroundStyle(Palette.textPrimary)
                    if site != nil { Text(t("Site, in any browser", "Sito, in qualsiasi browser")).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary) }
                    else if location == nil { Text(t("Not installed on this Mac", "Non installata su questo Mac")).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary) }
                }
                .help(bundleID)
                Spacer()
                VerbPicker(title: t("Style for \(name)", "Stile per \(name)"), selection: Binding(get: { style }, set: { model.settings.appStyles[bundleID] = $0 }),
                           options: WritingStyle.allCases.map { ($0, $0.title(t)) })
                    .frame(width: 160)
                // Quiet until asked, and asked again before anything goes.
                IconButton(symbol: "minus.circle", label: t("Remove \(name)", "Rimuovi \(name)"), action: remove)
            }
            if style == .custom {
                VerbField(label: t("How to write in \(name)", "Come scrivere in \(name)"),
                          text: Binding(get: { model.settings.stylePrompts[bundleID] ?? "" }, set: { model.settings.stylePrompts[bundleID] = $0.isEmpty ? nil : $0 }),
                          prompt: t("Short and friendly, no full stop at the end", "Brevi e cordiali, senza punto finale"))
                    .padding(.leading, 24 + Space.md)
            }
        }
        .padding(.vertical, Space.sm)
    }
}

/// The words Verb listens for: the names after "Ehi", then the words that finish or cancel.
/// Each field holds as many as wanted, separated by " / ". The fields keep what is typed; the
/// lists are read from them as they change.
private struct VoiceWordsEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var names = ""
    @State private var finishes = ""
    @State private var cancels = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VerbField(label: t("Names after “Hey”", "Nomi dopo “Ehi”"), text: $names, prompt: "Verb / Jarvis")
            Text(t("A word you never say otherwise. Try a new one below.", "Una parola che non usi parlando. Prova quella nuova qui sotto."))
                .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true).measure()
            VerbField(label: t("Words that finish", "Parole per finire"), text: $finishes, prompt: VoiceCommands.standardFinishes.joined(separator: " / "))
            VerbField(label: t("Words that cancel", "Parole per annullare"), text: $cancels, prompt: VoiceCommands.standardCancels.joined(separator: " / "))
            Text(t("Separate them with “ / ”. They count only at the end: “Hey Verb stop”.", "Separale con “ / ”. Valgono solo alla fine: “Ehi Verb stop”."))
                .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true).measure()
        }
        .padding(.vertical, Space.md)
        .onAppear {
            let voice = model.settings.voiceOptions
            names = voice.names.joined(separator: " / "); finishes = voice.finishWords.joined(separator: " / "); cancels = voice.cancelWords.joined(separator: " / ")
        }
        // Settings are written only when a field says something new, not when the page fills them in.
        .onChange(of: names) { _, value in
            let list = Self.list(value, fallback: ["Verb"])
            if model.settings.voiceOptions.names != list { model.settings.voiceOptions.names = list }
        }
        .onChange(of: finishes) { _, value in
            let list = Self.list(value, fallback: VoiceCommands.standardFinishes)
            if model.settings.voiceOptions.finishWords != list { model.settings.voiceOptions.finishWords = list }
        }
        .onChange(of: cancels) { _, value in
            let list = Self.list(value, fallback: VoiceCommands.standardCancels)
            if model.settings.voiceOptions.cancelWords != list { model.settings.voiceOptions.cancelWords = list }
        }
    }
    /// The entries between the slashes (commas work too). An empty field means the standard
    /// words, so the commands never go silent by accident.
    static func list(_ text: String, fallback: [String]) -> [String] {
        let words = text.split(whereSeparator: { $0 == "/" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return words.isEmpty ? fallback : words
    }
}

/// Say the phrase once and see what the engine wrote. A spelling Verb did not understand can
/// be taught to the dictionary as the phrase.
private struct VoiceTrialPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        let name = model.settings.voiceOptions.spokenName
        // The phrases as said in the interface's language; Verb takes “Hey” and “Ehi” alike.
        let wake = t("Hey ", "Ehi ") + name, close = wake + " " + (model.settings.voiceOptions.finishWords.first ?? "stop")
        VStack(alignment: .leading, spacing: Space.md) {
            RowLabel(title: t("Try the phrases", "Prova le frasi"),
                     detail: t("Say it and see what Verb hears. A different spelling can be taught.", "Dilla e guarda cosa sente Verb. Una grafia diversa si può insegnare."))
            HStack(spacing: Space.sm) {
                Button { model.startVoiceTrial(.wake) } label: { Label(t("Try “\(wake)”", "Prova “\(wake)”"), systemImage: "waveform") }
                    .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                Button { model.startVoiceTrial(.finish) } label: { Label(t("Try “\(close)”", "Prova “\(close)”"), systemImage: "stop.circle") }
                    .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            }
            .disabled(model.busy || !model.speechInstalled || isListening)
            result(wake: wake)
        }
        .padding(.vertical, Space.md)
    }
    private var isListening: Bool { if case .listening = model.voiceTrial { return true }; return false }
    private func note(_ text: String) -> some View {
        Text(text).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true).measure()
    }
    @ViewBuilder private func result(wake: String) -> some View {
        switch model.voiceTrial {
        case .idle: EmptyView()
        case .listening(let kind):
            StatusLabel(text: kind == .wake ? t("Listening. Say “\(wake)”.", "Ascolto. Di’ “\(wake)”.") : t("Listening. Say the closing phrase.", "Ascolto. Di’ la frase di chiusura."), symbol: "waveform", tone: .neutral)
        case .silent:
            StatusLabel(text: t("Verb heard nothing. Try again, a little closer.", "Verb non ha sentito nulla. Riprova avvicinandoti un po’."), symbol: "mic.slash", tone: .warning)
        case .heard(_, let text, true, _):
            StatusLabel(text: t("Understood: “\(text)”", "Riconosciuta: “\(text)”"), symbol: "checkmark.circle", tone: .success)
        case .heard(_, let text, false, let lesson):
            VStack(alignment: .leading, spacing: Space.sm) {
                StatusLabel(text: text.isEmpty ? t("Not understood.", "Non riconosciuta.") : t("Not understood: “\(text)”", "Non riconosciuta: “\(text)”"), symbol: "exclamationmark.triangle", tone: .warning)
                if let lesson {
                    let meaning = model.meaning(of: lesson, t)
                    Button { model.teachVoiceTrial() } label: { Label(t("Teach “\(lesson.heard)” as “\(meaning)”", "Insegna “\(lesson.heard)” come “\(meaning)”"), systemImage: "character.book.closed") }
                        .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                    note(lesson.command == nil
                         ? t("Verb will then take “\(lesson.heard)” as “\(meaning)” when it opens or closes what you say. Elsewhere your words stay as spoken. You can remove it from the Dictionary.",
                             "Da quel momento Verb prenderà “\(lesson.heard)” per “\(meaning)” quando apre o chiude ciò che dici. Altrove le tue parole restano come le hai dette. Puoi toglierla dal Dizionario.")
                         : t("Verb will then finish when a dictation ends with “\(lesson.heard)”. It never starts a dictation, and elsewhere your words stay as spoken. You can remove it from the Dictionary.",
                             "Da quel momento Verb chiuderà la dettatura quando finisce con “\(lesson.heard)”. Non ne avvia mai una, e altrove le tue parole restano come le hai dette. Puoi toglierla dal Dizionario."))
                } else {
                    note(t("Say only the phrase, then try again.", "Di’ solo la frase di attivazione, poi riprova."))
                }
            }
        case .common(_, let text, let lesson):
            VStack(alignment: .leading, spacing: Space.sm) {
                StatusLabel(text: t("Not understood: “\(text)”", "Non riconosciuta: “\(text)”"), symbol: "exclamationmark.triangle", tone: .warning)
                let single = !lesson.heard.contains(" ")
                note((single ? t("“\(lesson.heard)” is an ordinary word", "“\(lesson.heard)” è una parola comune") : t("“\(lesson.heard)” are ordinary words", "“\(lesson.heard)” sono parole comuni"))
                     + t(": taught as the phrase, Verb would start whenever a sentence opens that way. Try again a little more slowly, or choose another name. If you rarely begin a sentence like that, you can still teach it.",
                         ": se diventasse la frase, Verb partirebbe ogni volta che una frase inizia così. Riprova un po’ più lentamente, oppure scegli un altro nome. Se inizi di rado una frase così, puoi insegnarla comunque."))
                Button { model.teachVoiceTrial() } label: { Label(t("Teach it anyway", "Insegnala comunque"), systemImage: "character.book.closed") }
                    .buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
            }
        case .taught(_, let heard, let meaning):
            let shown = t.isItalian ? meaning : meaning.replacingOccurrences(of: "Ehi ", with: "Hey ")
            StatusLabel(text: t("Added to the Dictionary: “\(heard)” becomes “\(shown)”.", "Aggiunta al Dizionario: “\(heard)” diventa “\(shown)”."), symbol: "checkmark.circle", tone: .success)
        }
    }
}
