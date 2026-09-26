import SwiftUI
import UniformTypeIdentifiers
import VerbCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var clearConfirmation = false
    @State private var editingKeys: KeyEditing?
    @State private var libraryNote: String?
    var body: some View {
        PageScroll {
            PageHeader(rubric: nil, title: t("Settings", "Impostazioni"),
                       detail: t("Language, appearance, shortcuts and what stays on your Mac.", "Lingua, aspetto, scorciatoie e cosa resta sul tuo Mac."))
            // While a dictation runs only remote processing can change, so it can be turned off mid-way.
            Group { general; dictation; voice; keyboard; appStyles }.disabled(model.busy)
            privacy
            system.disabled(model.busy)
        }
        .confirmationDialog(t("Delete all dictation history and saved audio?", "Eliminare tutta la cronologia e l’audio salvato?"), isPresented: $clearConfirmation) {
            Button(t("Delete all history", "Elimina tutta la cronologia"), role: .destructive) { model.clearHistory() }
            Button(t("Cancel", "Annulla"), role: .cancel) {}
        } message: { Text(t("Your dictionary, snippets, models and settings stay.", "Dizionario, frasi pronte, modelli e impostazioni restano.")) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Card {
            SectionHeading(title: title)
            VStack(alignment: .leading, spacing: 0) { content() }.padding(.top, Space.sm)
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true).padding(.vertical, Space.sm)
    }

    private var general: some View {
        section(t("General", "Generale")) {
            SettingRow(title: t("Language", "Lingua"), detail: t("The language Verb speaks to you in.", "La lingua in cui ti parla Verb.")) {
                Segmented(title: t("Language", "Lingua"), values: InterfaceLanguage.allCases, selection: $model.settings.interfaceOptions.language, label: { $0.nativeName }).fixedSize()
            }
            Hairline()
            SettingRow(title: t("Appearance", "Aspetto"), detail: t("Automatic follows your Mac.", "Automatico segue il tuo Mac.")) {
                Segmented(title: t("Appearance", "Aspetto"), values: Appearance.allCases, selection: $model.settings.interfaceOptions.appearance, label: { $0.title(t) }, symbol: { $0.symbol }).fixedSize()
            }
            Hairline()
            OpenAtLoginSwitch()
            Hairline()
            SettingRow(title: t("Welcome and tour", "Introduzione e tour"), detail: t("The setup pages from the first launch, or a tour of this window.", "Le pagine di configurazione del primo avvio, oppure un giro di questa finestra.")) {
                HStack(spacing: Space.sm) {
                    Button(t("Show the welcome", "Rivedi l’introduzione")) { model.startWelcome() }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
                    Button(t("Take the tour", "Fai il tour")) { model.startTour() }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                }
            }
            Hairline()
            Label { note(t("Closing the window with ⌘W keeps Verb running in the menu bar. Quit from its menu or with ⌘Q.", "Chiudendo la finestra con ⌘W Verb resta attivo nella barra dei menu. Per uscire usa il suo menu o ⌘Q.")) }
                icon: { Image(systemName: "menubar.rectangle").foregroundStyle(Palette.textSecondary).padding(.top, Space.sm) }
        }
    }

    private var dictation: some View {
        section(t("Dictation", "Dettatura")) {
            SettingRow(title: t("Spoken language", "Lingua parlata")) {
                Picker(t("Spoken language", "Lingua parlata"), selection: $model.settings.language) { ForEach(DictationLanguage.allCases) { Text($0.title(t)).tag($0) } }
                    .labelsHidden().pickerStyle(.menu).frame(width: 220)
            }
            Hairline()
            SettingRow(title: t("Microphone", "Microfono")) {
                Picker(t("Microphone", "Microfono"), selection: $model.settings.microphoneID) {
                    Text(t("System default", "Predefinito di sistema")).tag("")
                    ForEach(model.microphones) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 220)
            }
            if model.settings.microphoneID.isEmpty {
                SwitchRow(title: t("Prefer the Mac’s microphone to headphones", "Preferisci il microfono del Mac alle cuffie"),
                          detail: t("Bluetooth headphones switch to call quality while their microphone is open, and your music with them. Verb listens with the Mac’s own instead.",
                                    "Le cuffie Bluetooth passano alla qualità da telefonata mentre il loro microfono è aperto, e la musica con loro. Verb ascolta invece con il microfono del Mac."),
                          isOn: $model.settings.preferBuiltInMic)
            }
            Hairline()
            SettingRow(title: t("Default style", "Stile predefinito"), detail: model.settings.style.detail(t)) {
                Picker(t("Default style", "Stile predefinito"), selection: $model.settings.style) { ForEach(WritingStyle.allCases) { Text($0.title(t)).tag($0) } }
                    .labelsHidden().pickerStyle(.menu).frame(width: 220)
            }
            Hairline()
            SwitchRow(title: t("Insert text into the focused app", "Inserisci il testo nell’app in primo piano"),
                      detail: t("What you had copied stays on the clipboard. With no text field in front, such as on the desktop, the text waits: \(t.keys(model.settings.keyOptions.pasteLast)) pastes it where you want, \(t.keys(model.settings.keyOptions.copyLast)) copies it.",
                                "Ciò che avevi copiato resta negli appunti. Se davanti non c’è un campo di testo, come sulla scrivania, il testo resta pronto: \(t.keys(model.settings.keyOptions.pasteLast)) lo incolla dove vuoi, \(t.keys(model.settings.keyOptions.copyLast)) lo copia."),
                      isOn: $model.settings.autoInsert)
            Hairline()
            SwitchRow(title: t("Fit the text to what is around the cursor", "Adatta il testo a quello intorno al cursore"),
                      detail: t("A space before it after a word, a small letter mid-sentence, and no full stop when the sentence carries on. Apps that don’t show their text to Verb, such as VS Code, get it as dictated.",
                                "Uno spazio prima se segue una parola, la minuscola a metà frase, niente punto se la frase continua. Le app che non mostrano il testo a Verb, come VS Code, lo ricevono come dettato."),
                      isOn: $model.settings.fitToField)
            Hairline()
            SwitchRow(title: t("Use the names already in the field", "Usa i nomi già presenti nel campo"),
                      detail: t("When a dictation starts, Verb reads the text around the cursor and the window’s title for names and terms, so it spells them as written there. Nothing is kept; the names can reach your writing model as hints.",
                                "Quando inizia una dettatura, Verb legge il testo intorno al cursore e il titolo della finestra per trovare nomi e termini, e li scrive come sono lì. Non conserva nulla; i nomi possono arrivare al modello di scrittura come suggerimenti."),
                      isOn: $model.settings.namesFromField)
            Hairline()
            SwitchRow(title: t("English words in Italian sentences", "Parole inglesi nelle frasi italiane"),
                      detail: t("The engine sometimes writes an English word the way it sounds in Italian: “mercio” for merge, “bundolo” for bundle. Verb puts it back when a word exists in neither language and one of your English words, a dictionary word or a common term sounds almost the same. English verbs made Italian, like “fixa”, stay.",
                                "Il riconoscimento a volte scrive una parola inglese come suona in italiano: “mercio” per merge, “bundolo” per bundle. Verb la rimette a posto quando una parola non esiste in nessuna delle due lingue e una tua parola inglese, una del dizionario o un termine comune suona quasi uguale. I verbi inglesi all’italiana, come “fixa”, restano."),
                      isOn: $model.settings.restoreEnglish)
            Hairline()
            SwitchRow(title: t("Code names and files in editors", "Nomi di codice e file negli editor"),
                      detail: t("In editors and terminals Verb reads the open project: “user id” becomes userId when the project has it, “app model dot swift” becomes AppModel.swift, and “tag index dot ts” mentions the file (@src/index.ts in a terminal, for Claude Code). “camel case”, “snake case”, “pascal case”, “kebab case” and “constant case” format the words that follow.",
                                "Negli editor e nei terminali Verb legge il progetto aperto: “user id” diventa userId se il progetto lo usa, “app model punto swift” diventa AppModel.swift, e “tag index punto ts” menziona il file (@src/index.ts nel terminale, per Claude Code). “camel case”, “snake case”, “pascal case”, “kebab case” e “constant case” formattano le parole che seguono."),
                      isOn: $model.settings.codeNames)
            Hairline()
            SwitchRow(title: t("Learn from your corrections", "Impara dalle tue correzioni"),
                      detail: t("For a little while after a paste, a word you retype in the text Verb wrote is offered to the dictionary. Nothing is added without your yes.",
                                "Per qualche istante dopo l’inserimento, una parola che riscrivi nel testo di Verb ti viene proposta per il dizionario. Non aggiunge nulla senza il tuo sì."),
                      isOn: $model.settings.learnFromCorrections)
            Hairline()
            SwitchRow(title: t("Show the words as you speak", "Mostra le parole mentre parli"),
                      detail: t("A card above the overlay shows the text as it forms; the lighter part is still being heard. The text that goes in at the end comes from the whole recording.",
                                "Una scheda sopra la capsula mostra il testo man mano; la parte più chiara si sta ancora formando. Il testo inserito alla fine viene dall’intera registrazione."),
                      isOn: $model.settings.livePreview)
                .disabled(!model.speechInstalled)
            Hairline()
            SettingRow(title: t("Overlay", "Capsula"), detail: model.settings.overlayStyle.detail(t) + (model.settings.overlayStyle == .classic ? "" : " " + t("Space finishes and Escape cancels, as always.", "Spazio termina ed Esc annulla, come sempre."))) {
                Picker(t("Overlay", "Capsula"), selection: $model.settings.overlayStyle) { ForEach(OverlayStyle.allCases) { Text($0.title(t)).tag($0) } }
                    .labelsHidden().pickerStyle(.menu).frame(width: 160)
            }
            Hairline()
            SwitchRow(title: t("Play start and finish sounds", "Suoni di inizio e fine"), isOn: $model.settings.soundFeedback)
            Hairline()
            SwitchRow(title: t("Lower the sound while you dictate", "Abbassa l’audio mentre detti"),
                      detail: t("Music and videos drop to a fifth of your volume while you speak, and come back when you stop. A volume you change in the meantime stays.",
                                "Musica e video scendono a un quinto del tuo volume mentre parli e tornano quando finisci. Se cambi il volume nel frattempo, resta il tuo."),
                      isOn: $model.settings.duckAudio)
        }
    }

    private var voice: some View {
        let name = model.settings.voiceOptions.spokenName
        return section(t("Voice", "Voce")) {
            SwitchRow(title: t("Start with “Hey \(name)”", "Avvia con “Ehi \(name)”"),
                      detail: t("Say “Hey \(name)” and dictate hands-free, without touching the keyboard. Verb listens on this Mac and keeps nothing until it hears the phrase. While it listens the orange microphone light stays on, and it stops listening while the screen is locked or asleep.",
                                "Di’ “Ehi \(name)” e detta a mani libere, senza toccare la tastiera. Verb ascolta su questo Mac e non conserva nulla finché non sente la frase. Mentre ascolta la spia arancione del microfono resta accesa, e smette di ascoltare quando lo schermo è bloccato o spento."),
                      isOn: $model.settings.voiceOptions.wakeWord)
                .disabled(!model.speechInstalled)
            Hairline()
            SwitchRow(title: t("Finish with “Hey \(name) stop”", "Termina con “Ehi \(name) stop”"),
                      detail: t("In hands-free dictation, end with “Hey \(name)” and one of the words below: Verb finishes as with Space, or throws the recording away. The command never reaches your text.",
                                "Nella dettatura a mani libere chiudi con “Ehi \(name)” e una delle parole qui sotto: Verb termina come con Spazio, oppure scarta la registrazione. Il comando non finisce nel testo."),
                      isOn: $model.settings.voiceOptions.stopCommands)
                .disabled(!model.speechInstalled)
            Hairline()
            VoiceWordsEditor()
            Hairline()
            VoiceTrialPanel()
            if !model.speechInstalled {
                note(t("Voice commands need the speech model on this Mac. Download it in Models.", "I comandi vocali richiedono il modello vocale su questo Mac. Scaricalo in Modelli."))
            } else {
                note(t("A dictation started by voice finishes by itself after 20 seconds of silence. It is never thrown away on its own.",
                       "Una dettatura avviata a voce si chiude da sola dopo 20 secondi di silenzio. Non viene mai scartata da sola."))
            }
        }
    }

    private var keyboard: some View {
        section(t("Keyboard", "Tastiera")) {
            ForEach(Array(KeyTarget.actions.enumerated()), id: \.offset) { index, target in
                if index > 0 { Hairline() }
                KeyBindingRow(target: target, editing: $editingKeys)
            }
            Hairline()
            note(t("Hands-free, plain Space finishes and Escape cancels. Each transform has its keys on the Transforms page. Keys chosen for one command are taken from any other that had them. fn and modifiers held on their own need Accessibility.",
                   "A mani libere, Spazio da solo termina ed Esc annulla. Ogni trasformazione ha i suoi tasti nella pagina Trasformazioni. I tasti scelti per un comando vengono tolti a quello che li aveva. fn e i modificatori da soli richiedono Accessibilità."))
        }
        .sheet(item: $editingKeys) { KeyCaptureSheet(target: $0.target).environmentObject(model).environment(\.lang, t) }
    }

    private var appStyles: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(title: t("A style for each app", "Uno stile per ogni app"))
                Spacer()
                Button { addApp() } label: { Label(t("Add app", "Aggiungi app"), systemImage: "plus") }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            }
            note(t("A style is chosen by the app alone, not by what it shows: Verb takes no screenshots.", "Lo stile si sceglie in base all’app, non a ciò che mostra: Verb non cattura lo schermo."))
            VStack(spacing: 0) {
                ForEach(Array(model.settings.appStyles.keys.sorted().enumerated()), id: \.element) { index, bundleID in
                    if index > 0 { Hairline() }
                    let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                    HStack(spacing: Space.md) {
                        Group {
                            if let location { Image(nsImage: NSWorkspace.shared.icon(forFile: location.path)).resizable() }
                            else { Image(systemName: "app.dashed").font(.system(size: 18, weight: .light)).foregroundStyle(Palette.textTertiary) }
                        }
                        .frame(width: 24, height: 24).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appName(bundleID)).font(Typeface.text(TypeSize.body, .medium)).foregroundStyle(Palette.textPrimary)
                            if location == nil { Text(t("Not installed on this Mac", "Non installata su questo Mac")).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary) }
                        }
                        .help(bundleID)
                        Spacer()
                        Picker(t("Style", "Stile"), selection: Binding(get: { model.settings.appStyles[bundleID] ?? .natural }, set: { model.settings.appStyles[bundleID] = $0 })) {
                            ForEach(WritingStyle.allCases) { Text($0.title(t)).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 150)
                        IconButton(symbol: "minus.circle", label: t("Remove \(appName(bundleID))", "Rimuovi \(appName(bundleID))"), tone: .danger) { model.settings.appStyles.removeValue(forKey: bundleID) }
                    }
                    .padding(.vertical, Space.xs)
                }
            }
        }
    }

    private var privacy: some View {
        section(t("Privacy and history", "Privacy e cronologia")) {
            SwitchRow(title: t("Allow remote processing", "Consenti l’elaborazione remota"),
                      detail: t("Only the providers you pick in Models receive anything: audio for recognition, text for cleanup. Turning this off cancels a running job; data already sent cannot be recalled.",
                                "Ricevono dati solo i fornitori scelti in Modelli: l’audio per il riconoscimento, il testo per la rifinitura. Spegnendo si annulla il lavoro in corso; i dati già inviati non si possono richiamare."),
                      isOn: $model.settings.allowRemoteProcessing)
            Hairline()
            Group {
            SettingRow(title: t("Keep local history", "Conserva la cronologia")) {
                Picker(t("Keep local history", "Conserva la cronologia"), selection: $model.settings.retention) { ForEach(Retention.allCases) { Text($0.title(t)).tag($0) } }
                    .labelsHidden().pickerStyle(.menu).frame(width: 220)
            }
            Hairline()
            SwitchRow(title: t("Keep audio for playback and recovery", "Conserva l’audio per riascolto e recupero"),
                      detail: t("Recordings, meetings included, expire after 14 days, or sooner under your history setting. With audio off, only a dictation that failed keeps its recording, for Retry. With history off, nothing is kept.",
                                "Le registrazioni, anche delle riunioni, scadono dopo 14 giorni, o prima secondo la cronologia. Ad audio spento resta solo quella di una dettatura non riuscita, per riprovare. A cronologia spenta non resta nulla."),
                      isOn: $model.settings.keepAudio)
                .disabled(model.settings.retention == .none)
            Hairline()
            HStack(spacing: Space.sm) {
                Button { NSWorkspace.shared.open(model.paths.root) } label: { Label(t("Open data folder", "Apri la cartella dei dati"), systemImage: "folder") }.buttonStyle(VerbButtonStyle(kind: .secondary))
                Spacer()
                Button(role: .destructive) { clearConfirmation = true } label: { Label(t("Delete all history", "Elimina tutta la cronologia"), systemImage: "trash") }
                    .buttonStyle(VerbButtonStyle(kind: .danger)).disabled(model.history.isEmpty)
            }
            .padding(.top, Space.sm)
            }
            .disabled(model.busy)
        }
    }

    private var system: some View {
        section(t("System", "Sistema")) {
            SettingRow(title: t("Permissions", "Autorizzazioni")) {
                HStack(spacing: Space.sm) {
                    permission(model.microphoneGranted, t("Microphone", "Microfono")) { model.requestMicrophone() }
                    permission(model.accessibilityGranted, t("Accessibility", "Accessibilità")) { model.requestAccessibility() }
                }
            }
            Hairline()
            SettingRow(title: t("Dictionary and snippets", "Dizionario e frasi pronte"), detail: t("Move your library to another Mac. For CSV, use the Dictionary and Snippets pages.", "Porta la tua libreria su un altro Mac. Per il CSV usa le pagine Dizionario e Frasi pronte.")) {
                HStack(spacing: Space.sm) {
                    Button(t("Export", "Esporta")) { exportLibrary() }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                    Button(t("Import", "Importa")) { importLibrary() }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                }
            }
            if let libraryNote { StatusLabel(text: libraryNote, symbol: "arrow.up.arrow.down", tone: .success).padding(.bottom, Space.md) }
            Hairline()
            SettingRow(title: t("Notes folder", "Cartella delle note"), detail: model.notesFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + " · " + t("Notes and meeting notes are Markdown files: a folder in iCloud Drive or an Obsidian vault works too.", "Note e note delle riunioni sono file Markdown: va bene anche una cartella di iCloud Drive o un vault di Obsidian.")) {
                HStack(spacing: Space.sm) {
                    if !model.settings.notesPath.isEmpty { Button(t("Use Verb’s folder", "Usa la cartella di Verb")) { model.settings.notesPath = ""; model.openNote = nil; model.reloadNotes() }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true)) }
                    Button(t("Choose…", "Scegli…")) { model.chooseNotesFolder() }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                }
            }
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
        let known = ["com.apple.MobileSMS": "Messages", "net.whatsapp.WhatsApp": "WhatsApp", "com.tinyspeck.slackmacgap": "Slack", "com.apple.mail": "Mail",
                     "com.microsoft.Outlook": "Microsoft Outlook", "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm2"]
        // The name Finder shows, in the Mac's language: “Messaggi”, “Terminale”.
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? known[id] ?? id
    }
    private func addApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url)?.bundleIdentifier { model.settings.appStyles[bundle] = model.settings.style }
    }
    private func exportLibrary() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = t("Verb-library.json", "Verb-libreria.json"); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { do { try JSONStore.save(model.library, to: url) } catch { model.notify(error.localizedDescription) } }
    }
    private func importLibrary() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url); guard data.count < 2_000_000 else { throw VerbError("The library file is too large.") }
                let incoming = try JSONDecoder().decode(Library.self, from: data)
                var updated = model.library
                // The same rules as the Dictionary and Snippets pages: only what is new, nothing that clashes.
                let words = LibraryTransfer.merge(incoming.vocabulary, into: &updated.vocabulary, snippets: updated.snippets)
                let phrases = LibraryTransfer.merge(incoming.snippets, into: &updated.snippets, vocabulary: updated.vocabulary)
                if updated != model.library { model.library = updated }
                libraryNote = t.count(words.added, "word", "words", "parola", "parole") + " · " + t.count(phrases.added, "snippet added", "snippets added", "frase aggiunta", "frasi aggiunte")
            } catch { libraryNote = t.message(error.localizedDescription) }
        }
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
            Text(t("Words you don’t use when you talk. Verb already knows how the engine spells its own name; another name is matched as written, so try it below.",
                   "Parole che non usi quando parli. Verb sa già come il riconoscimento scrive il suo nome; un altro nome viene cercato così com’è, quindi provalo qui sotto."))
                .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            VerbField(label: t("Words that finish", "Parole per finire"), text: $finishes, prompt: VoiceCommands.standardFinishes.joined(separator: " / "))
            VerbField(label: t("Words that cancel", "Parole per annullare"), text: $cancels, prompt: VoiceCommands.standardCancels.joined(separator: " / "))
            Text(t("As many as you like, separated by “ / ”. They count after a name, at the end of what you say: “Hey Verb stop”.",
                   "Quante vuoi, separate da “ / ”. Valgono dopo un nome, alla fine di ciò che dici: “Ehi Verb stop”."))
                .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
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
                     detail: t("Say the phrase and see what Verb hears. If it writes it another way, you can teach it: the spelling goes into your Dictionary.",
                               "Di’ la frase e guarda cosa sente Verb. Se la scrive in un altro modo puoi insegnargliela: la grafia finisce nel tuo Dizionario."))
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
        Text(text).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func result(wake: String) -> some View {
        switch model.voiceTrial {
        case .idle: EmptyView()
        case .listening(let kind):
            StatusLabel(text: kind == .wake ? t("Listening. Say “\(wake)”.", "Ascolto. Di’ “\(wake)”.") : t("Listening. Say the closing phrase.", "Ascolto. Di’ la frase per finire."), symbol: "waveform", tone: .neutral)
        case .silent:
            StatusLabel(text: t("Verb heard nothing. Try again, a little closer.", "Verb non ha sentito nulla. Riprova, un po’ più vicino."), symbol: "mic.slash", tone: .warning)
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
                    note(t("Say only the phrase, then try again.", "Di’ solo la frase, poi riprova."))
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
