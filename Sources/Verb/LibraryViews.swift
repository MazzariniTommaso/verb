import SwiftUI
import VerbCore

// MARK: - Dictionary

struct DictionaryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var editing: VocabularyEntry?
    @State private var search = ""
    @State private var transferNote: String?
    private var words: [VocabularyEntry] {
        model.library.vocabulary.filter { search.isEmpty || $0.word.localizedCaseInsensitiveContains(search) || $0.heardAs.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        PageScroll {
            PageHeader(rubric: t.count(model.library.vocabulary.count, "word", "words", "parola", "parole"), title: t("Dictionary", "Dizionario"),
                       detail: t("Names, acronyms and terms that Verb should always spell your way.", "Nomi, sigle e termini che Verb deve scrivere sempre a modo tuo.")) {
                HStack(spacing: Space.sm) {
                    LibraryTransferMenu(part: .vocabulary, note: $transferNote)
                    Button { editing = VocabularyEntry(word: "") } label: { Label(t("Add word", "Aggiungi parola"), systemImage: "plus") }.buttonStyle(VerbButtonStyle(kind: .primary))
                }
            }
            if let transferNote { StatusLabel(text: transferNote, symbol: "arrow.up.arrow.down", tone: .success) }
            if !model.suggestions.isEmpty { SuggestionList(suggestions: model.suggestions.reversed()) }
            if model.library.vocabulary.isEmpty {
                Card {
                    EmptyState(symbol: "character.book.closed", title: t("Teach Verb your words", "Insegna a Verb le tue parole"),
                               detail: t("Add a name so it is recognised, or a frequent mishearing to fix automatically.", "Aggiungi un nome da riconoscere, o un errore frequente da correggere in automatico."))
                }
            } else {
                SearchField(text: $search, prompt: t("Find a word or correction", "Cerca una parola o una correzione"), clearLabel: t("Clear search", "Cancella la ricerca"))
                if words.isEmpty {
                    Card { EmptyState(symbol: "magnifyingglass", title: t("Nothing matches", "Nessun risultato"), detail: t("Try a shorter part of the word.", "Prova con una parte più breve della parola.")) }
                } else {
                    // Spellings taught for the voice phrases only find the commands; the row says so.
                    let phrases = model.settings.voiceOptions.phrases(vocabulary: [])
                    RowList {
                        ForEach(Array(words.enumerated()), id: \.element.id) { index, word in
                            if index > 0 { Hairline().padding(.horizontal, Space.lg) }
                            EditableRow(hint: t("Opens the word to edit or delete it", "Apre la parola per modificarla o eliminarla"), action: { editing = word }) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(word.word).font(Typeface.display(TypeSize.reading)).foregroundStyle(Palette.textPrimary)
                                    if phrases.isCommand(word) {
                                        Text(t("Heard as “\(word.heardAs)” · voice command only", "Sentita come “\(word.heardAs)” · solo per il comando vocale")).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
                                    } else if !word.heardAs.isEmpty {
                                        Text(t("Replaces “\(word.heardAs)”", "Sostituisce “\(word.heardAs)”")).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { WordEditor(entry: $0).environmentObject(model).environment(\.lang, t) }
    }
}

struct WordEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lang) private var t
    let entry: VocabularyEntry
    @State private var word = ""
    @State private var heardAs = ""
    @State private var error: String?
    private var saved: Bool { model.library.vocabulary.contains { $0.id == entry.id } }
    var body: some View {
        EditorSheet(title: saved ? t("Edit word", "Modifica la parola") : t("Add a word", "Aggiungi una parola"), width: 460, error: error,
                    save: t("Save", "Salva"), cancel: t("Cancel", "Annulla"), canSave: !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, onSave: save,
                    removal: saved ? SheetRemoval(label: t("Delete", "Elimina"), confirm: t("Delete word", "Elimina la parola"), question: t("Delete “\(entry.word)”?", "Eliminare “\(entry.word)”?"),
                                           detail: t("Verb stops recognising and correcting it. This can’t be undone.", "Verb smetterà di riconoscerla e correggerla. Non si può annullare.")) {
                        model.library.vocabulary.removeAll { $0.id == entry.id }
                    } : nil) {
            VerbField(label: t("Preferred spelling", "Grafia preferita"), text: $word)
            VerbField(label: t("Often heard as (optional)", "Spesso sentita come (facoltativo)"), text: $heardAs)
            Text(t("The spelling guides recognition. A correction replaces whole words and phrases with your spelling.", "La grafia guida il riconoscimento. Una correzione sostituisce parole e frasi intere con la tua grafia."))
                .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { word = entry.word; heardAs = entry.heardAs }
    }
    private func save() {
        do {
            let clean = word.trimmingCharacters(in: .whitespacesAndNewlines), wrong = heardAs.trimmingCharacters(in: .whitespacesAndNewlines)
            let others = model.library.vocabulary.filter { $0.id != entry.id }
            // One spelling may fix several mishearings ("para kit", "parachi"); a plain spelling is listed once.
            try TextRules.validate(trigger: clean, existing: (wrong.isEmpty ? others.filter { $0.heardAs.isEmpty } : []).map(\.word) + model.library.snippets.map(\.trigger))
            if !wrong.isEmpty { try TextRules.validate(trigger: wrong, existing: others.map(\.heardAs)) }
            let value = VocabularyEntry(id: entry.id, word: clean, heardAs: wrong)
            if let index = model.library.vocabulary.firstIndex(where: { $0.id == entry.id }) { model.library.vocabulary[index] = value } else { model.library.vocabulary.append(value) }
            dismiss()
        } catch { self.error = t.message(error.localizedDescription) }
    }
}

// MARK: - Snippets

struct SnippetsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var editing: Snippet?
    @State private var transferNote: String?
    var body: some View {
        PageScroll {
            PageHeader(rubric: t.count(model.library.snippets.count, "snippet", "snippets", "frase", "frasi"), title: t("Snippets", "Frasi pronte"),
                       detail: t("Say a short phrase and get the full text: a signature, an address, a reply you write often.", "Pronuncia una frase breve e ottieni il testo completo: una firma, un indirizzo, una risposta che scrivi spesso.")) {
                HStack(spacing: Space.sm) {
                    LibraryTransferMenu(part: .snippets, note: $transferNote)
                    Button { editing = Snippet(trigger: "", expansion: "") } label: { Label(t("Add snippet", "Aggiungi frase"), systemImage: "plus") }.buttonStyle(VerbButtonStyle(kind: .primary))
                }
            }
            if let transferNote { StatusLabel(text: transferNote, symbol: "arrow.up.arrow.down", tone: .success) }
            if model.library.snippets.isEmpty {
                Card {
                    EmptyState(symbol: "text.quote", title: t("Your shortcuts, spoken", "Le tue scorciatoie, a voce"),
                               detail: t("For example, say “my signature” to insert your full email signature.", "Per esempio, di’ “la mia firma” per inserire la firma completa delle email."))
                }
            } else {
                RowList {
                    ForEach(Array(model.library.snippets.enumerated()), id: \.element.id) { index, snippet in
                        if index > 0 { Hairline().padding(.horizontal, Space.lg) }
                        EditableRow(hint: t("Opens the snippet to edit or delete it", "Apre la frase per modificarla o eliminarla"), action: { editing = snippet }) {
                            VStack(alignment: .leading, spacing: Space.xs + 2) {
                                Text("“\(snippet.trigger)”").font(Typeface.display(TypeSize.reading)).foregroundStyle(Palette.textPrimary)
                                Text(snippet.expansion).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).lineSpacing(2).lineLimit(3).multilineTextAlignment(.leading)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { SnippetEditor(entry: $0).environmentObject(model).environment(\.lang, t) }
    }
}

struct SnippetEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lang) private var t
    let entry: Snippet
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var formatted = false
    @State private var error: String?
    private var saved: Bool { model.library.snippets.contains { $0.id == entry.id } }
    var body: some View {
        EditorSheet(title: saved ? t("Edit snippet", "Modifica la frase pronta") : t("New snippet", "Nuova frase pronta"), width: 520, error: error,
                    save: t("Save", "Salva"), cancel: t("Cancel", "Annulla"), canSave: !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, onSave: save,
                    removal: saved ? SheetRemoval(label: t("Delete", "Elimina"), confirm: t("Delete snippet", "Elimina la frase"), question: t("Delete “\(entry.trigger)”?", "Eliminare “\(entry.trigger)”?"),
                                           detail: t("Its full text is removed from Verb. This can’t be undone.", "Il testo completo viene rimosso da Verb. Non si può annullare.")) {
                        model.library.snippets.removeAll { $0.id == entry.id }
                    } : nil) {
            VerbField(label: t("When I say", "Quando dico"), text: $trigger)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: t("Write this", "Scrivi questo"))
                VerbEditor(text: $expansion, minHeight: 190, label: t("Write this", "Scrivi questo"))
                Text(t("Fill-ins: {date} {time} {weekday} {clipboard}, and {cursor} where the cursor should stop. {data} {ora} {giorno} {appunti} {cursore} give them in Italian.",
                       "Parti variabili: {data} {ora} {giorno} {appunti}, e {cursore} dove deve fermarsi il cursore. {date} {time} {weekday} {clipboard} {cursor} le scrivono in inglese."))
                    .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            SwitchRow(title: t("Paste with formatting", "Incolla con la formattazione"),
                      detail: t("Write **bold**, *italic*, `code`, [a link](https://…) and lists starting with “- ”. Mail, Notes and web apps get the formatting; terminals and plain fields get clean text.",
                                "Scrivi **grassetto**, *corsivo*, `codice`, [un link](https://…) ed elenchi che iniziano con “- ”. Mail, Note e le app web ricevono la formattazione; terminali e campi semplici il testo pulito."),
                      isOn: $formatted)
        }
        .onAppear { trigger = entry.trigger; expansion = entry.expansion; formatted = entry.isFormatted }
    }
    private func save() {
        do {
            let clean = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            try TextRules.validate(trigger: clean, existing: model.library.snippets.filter { $0.id != entry.id }.map(\.trigger) + model.library.vocabulary.map(\.word))
            guard !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, expansion.count <= 12000 else { throw VerbError("Enter between 1 and 12,000 characters of expansion text.") }
            let value = Snippet(id: entry.id, trigger: clean, expansion: expansion, formatted: formatted ? true : nil)
            if let index = model.library.snippets.firstIndex(where: { $0.id == entry.id }) { model.library.snippets[index] = value } else { model.library.snippets.append(value) }
            dismiss()
        } catch { self.error = t.message(error.localizedDescription) }
    }
}

/// Import and export for the dictionary or the snippets: CSV to edit in a spreadsheet, JSON
/// to keep everything. What happened is said on the page for a few seconds.
struct LibraryTransferMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let part: LibraryPart
    @Binding var note: String?
    var body: some View {
        Menu {
            Button(t("Import from a file…", "Importa da un file…")) { show(model.importPart(part)) }
            Divider()
            Button(t("Export as CSV…", "Esporta in CSV…")) { show(model.exportPart(part, csv: true)) }
            Button(t("Export as JSON…", "Esporta in JSON…")) { show(model.exportPart(part, csv: false)) }
        } label: {
            Label(t("Import & export", "Importa ed esporta"), systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.button).buttonStyle(VerbButtonStyle(kind: .secondary)).fixedSize()
        .help(t("CSV files open in Numbers and Excel. Importing only adds what is new.", "I file CSV si aprono con Numbers ed Excel. L’importazione aggiunge solo ciò che è nuovo."))
    }
    private func show(_ text: String?) {
        guard let text else { return }
        note = text
        Task { try? await Task.sleep(nanoseconds: 6_000_000_000); if note == text { note = nil } }
    }
}

enum LibraryPart { case vocabulary, snippets }

extension AppModel {
    /// Saves the dictionary or the snippets to a file, and says so; nil when the panel is cancelled.
    func exportPart(_ part: LibraryPart, csv: Bool) -> String? {
        let t = lang
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (part == .vocabulary ? t("Verb dictionary", "Dizionario Verb") : t("Verb snippets", "Frasi pronte Verb")) + (csv ? ".csv" : ".json")
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data: Data
            switch part {
            case .vocabulary: data = csv ? Data(LibraryTransfer.csv(vocabulary: library.vocabulary).utf8) : try LibraryTransfer.json(vocabulary: library.vocabulary)
            case .snippets: data = csv ? Data(LibraryTransfer.csv(snippets: library.snippets).utf8) : try LibraryTransfer.json(snippets: library.snippets)
            }
            try data.write(to: url, options: .atomic)
            return part == .vocabulary ? t.count(library.vocabulary.count, "word exported", "words exported", "parola esportata", "parole esportate")
                                       : t.count(library.snippets.count, "snippet exported", "snippets exported", "frase esportata", "frasi esportate")
        } catch { return t.message(error.localizedDescription) }
    }

    /// Adds the words or snippets of a CSV or JSON file, and says how many were new.
    func importPart(_ part: LibraryPart) -> String? {
        let t = lang
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .json, .plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 5_000_000 else { throw VerbError("The file is too large to import.") }
            let isCSV = url.pathExtension.lowercased() != "json"
            var updated = library
            let outcome: LibraryTransfer.Outcome
            switch part {
            case .vocabulary: outcome = LibraryTransfer.merge(try LibraryTransfer.vocabulary(from: data, isCSV: isCSV), into: &updated.vocabulary, snippets: updated.snippets)
            case .snippets: outcome = LibraryTransfer.merge(try LibraryTransfer.snippets(from: data, isCSV: isCSV), into: &updated.snippets, vocabulary: updated.vocabulary)
            }
            if updated != library { library = updated }
            let added = part == .vocabulary ? t.count(outcome.added, "word added", "words added", "parola aggiunta", "parole aggiunte")
                                            : t.count(outcome.added, "snippet added", "snippets added", "frase aggiunta", "frasi aggiunte")
            return outcome.skipped == 0 ? added : added + " · " + t.count(outcome.skipped, "already there or clashing", "already there or clashing", "già presente o in conflitto", "già presenti o in conflitto")
        } catch { return t.message(error.localizedDescription) }
    }
}

// MARK: - Transforms

struct TransformsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var editing: Transform?
    @State private var removing: Transform?
    @State private var editingKeys: KeyEditing?
    var body: some View {
        let transforms = model.library.transforms
        PageScroll {
            PageHeader(rubric: rubric, title: t("Transforms", "Trasformazioni"),
                       detail: t("A transform is a prompt you keep. Select text in any app and the writing model rewrites it as the prompt says, with a shortcut or from the menu bar.",
                                 "Una trasformazione è un prompt che conservi. Seleziona un testo in qualsiasi app e il modello di scrittura lo riscrive come dice il prompt, con una scorciatoia o dalla barra dei menu.")) {
                Button { editing = Transform(name: "", instruction: "") } label: { Label(t("New transform", "Nuova trasformazione"), systemImage: "plus") }
                    .buttonStyle(VerbButtonStyle(kind: .primary))
            }
            Card {
                SectionHeading(title: t("Edit with your voice", "Modifica a voce"))
                Text(t("Select your text, hold \(t.keys(model.settings.keyOptions.voiceEdit)), then say “make this shorter” or “traduci in inglese”. It works in any app, VS Code and Sublime Text included.",
                       "Seleziona il testo, tieni premuto \(t.keys(model.settings.keyOptions.voiceEdit)), poi di’ “rendilo più breve” o “translate into English”. Funziona in qualsiasi app, anche in VS Code e Sublime Text."))
                    .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.body, Leading.reading))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, Space.sm)
            }
            if transforms.isEmpty {
                Card { EmptyState(symbol: "pencil.line", title: t("No transforms yet", "Ancora nessuna trasformazione"), detail: t("Create one for an edit you ask for often, such as a translation.", "Creane una per una modifica che chiedi spesso, come una traduzione.")) }
            } else {
                RowList {
                    ForEach(Array(transforms.enumerated()), id: \.element.id) { index, transform in
                        if index > 0 { Hairline().padding(.horizontal, Space.lg) }
                        // The keys are their own button, beside the row that opens the prompt.
                        HStack(alignment: .center, spacing: 0) {
                            KeyButton(target: .transform(transform.id), editing: $editingKeys, minWidth: 104).padding(.leading, Space.lg)
                            EditableRow(hint: t("Opens the prompt to edit or delete it. More actions with a secondary click.", "Apre il prompt per modificarlo o eliminarlo. Altre azioni con il clic secondario."), action: { editing = transform }) {
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    Text(transform.name).font(Typeface.text(TypeSize.body, .semibold)).foregroundStyle(Palette.textPrimary)
                                    Text(transform.instruction).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).lineSpacing(2).lineLimit(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .contextMenu { actions(for: transform, at: index, count: transforms.count) }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                Text(t("Transforms use your writing model, on up to 1,000 selected words. The result replaces the selection only if it has not changed in the meantime.",
                       "Le trasformazioni usano il tuo modello di scrittura, fino a 1.000 parole selezionate. Il risultato sostituisce la selezione solo se nel frattempo non è cambiata."))
                    .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.md)
                if !missingDefaults.isEmpty {
                    Button(t("Restore the defaults", "Ripristina le predefinite")) { model.library.transforms.append(contentsOf: missingDefaults) }
                        .buttonStyle(VerbButtonStyle(kind: .quiet, compact: true)).fixedSize()
                        .help(t("Adds back the ready-made transforms you deleted. Yours stay as they are.", "Aggiunge di nuovo le trasformazioni pronte che hai eliminato. Le tue restano come sono."))
                }
            }
        }
        .sheet(item: $editing) { TransformEditor(entry: $0).environmentObject(model).environment(\.lang, t) }
        .sheet(item: $editingKeys) { KeyCaptureSheet(target: $0.target).environmentObject(model).environment(\.lang, t) }
        .confirmationDialog(t("Delete “\(removing?.name ?? "")”?", "Eliminare “\(removing?.name ?? "")”?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { transform in
            Button(t("Delete transform", "Elimina la trasformazione"), role: .destructive) { model.library.transforms.removeAll { $0.id == transform.id } }
            Button(t("Cancel", "Annulla"), role: .cancel) {}
        } message: { _ in Text(t("Its keys become free. This can’t be undone.", "I suoi tasti tornano liberi. Non si può annullare.")) }
    }

    private var rubric: String {
        let count = model.library.transforms.count
        guard count > 0 else { return t("No transforms", "Nessuna trasformazione") }
        let keyed = model.library.transforms.filter { $0.keys != nil }.count
        return t.count(count, "transform", "transforms", "trasformazione", "trasformazioni") + " · " + t.count(keyed, "with keys", "with keys", "con tasti", "con tasti")
    }

    /// The ready-made transforms no longer in the list, recognised by name.
    private var missingDefaults: [Transform] {
        return Transform.missing(from: model.library.transforms, italian: t.isItalian).map { standard in
            let free = standard.keys.map { KeyBindings.owner(of: $0, keys: model.settings.keyOptions, transforms: model.library.transforms) == nil } ?? false
            return Transform(name: standard.name, instruction: standard.instruction, keys: free ? standard.keys : nil)
        }
    }

    @ViewBuilder private func actions(for transform: Transform, at index: Int, count: Int) -> some View {
        Button(t("Edit Prompt…", "Modifica il prompt…")) { editing = transform }
        Button(t("Change Keys…", "Cambia i tasti…")) { editingKeys = KeyEditing(target: .transform(transform.id)) }
        Button(t("Duplicate", "Duplica")) {
            model.library.transforms.insert(Transform(name: t("\(transform.name) copy", "\(transform.name) (copia)"), instruction: transform.instruction, keys: model.library.freeTransformKeys(keys: model.settings.keyOptions)), at: index + 1)
        }
        Divider()
        Button(t("Move Up", "Sposta in alto")) { model.library.transforms.swapAt(index, index - 1) }.disabled(index == 0)
        Button(t("Move Down", "Sposta in basso")) { model.library.transforms.swapAt(index, index + 1) }.disabled(index + 1 >= count)
        Divider()
        Button(t("Delete…", "Elimina…"), role: .destructive) { removing = transform }
    }
}

struct TransformEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lang) private var t
    let entry: Transform
    @State private var name = ""
    @State private var instruction = ""
    private var saved: Bool { model.library.transforms.contains { $0.id == entry.id } }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        EditorSheet(title: saved ? t("Edit transform", "Modifica la trasformazione") : t("Shape a transform", "Crea una trasformazione"), width: 500, error: nil,
                    save: t("Save", "Salva"), cancel: t("Cancel", "Annulla"), canSave: valid, onSave: save,
                    removal: saved ? SheetRemoval(label: t("Delete", "Elimina"), confirm: t("Delete transform", "Elimina la trasformazione"), question: t("Delete “\(entry.name)”?", "Eliminare “\(entry.name)”?"),
                                           detail: t("Its keys become free. This can’t be undone.", "I suoi tasti tornano liberi. Non si può annullare.")) {
                        model.library.transforms.removeAll { $0.id == entry.id }
                    } : nil) {
            VerbField(label: t("Name", "Nome"), text: $name)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Prompt")
                VerbEditor(text: $instruction, minHeight: 150, label: t("Prompt", "Prompt"))
            }
            Text(t("Write what the model should do with the selected text, as you would in a chat. Keep to one edit, and say which facts and formatting must stay. Verb adds the selected text and returns only the rewritten version.",
                   "Scrivi cosa deve fare il modello con il testo selezionato, come faresti in una chat. Chiedi una sola modifica e indica quali fatti e quale formattazione devono restare. Verb aggiunge il testo selezionato e restituisce solo la versione riscritta."))
                .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { name = entry.name; instruction = entry.instruction }
    }
    private func save() {
        // An edited transform keeps its keys; a new one gets the first ⌃⌥ digit nothing uses, if any.
        let existing = model.library.transforms.firstIndex { $0.id == entry.id }
        let keys = existing.map { model.library.transforms[$0].keys } ?? model.library.freeTransformKeys(keys: model.settings.keyOptions)
        let value = Transform(id: entry.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), instruction: instruction, keys: keys)
        if let existing { model.library.transforms[existing] = value } else { model.library.transforms.append(value) }
        dismiss()
    }
}

/// The shared frame of every editing sheet: a serif title, the fields, an error line, and the
/// actions. Delete, when the item exists, sits apart on the left and asks before it acts.
struct SheetRemoval {
    /// The short button in the sheet ("Delete"); the sheet's title already names the object.
    let label: String
    /// The confirming button, which restates the action and the object ("Delete word").
    let confirm: String
    let question: String
    let detail: String
    let perform: () -> Void
}

struct EditorSheet<Fields: View>: View {
    let title: String
    let width: CGFloat
    let error: String?
    let save: String
    let cancel: String
    let canSave: Bool
    let onSave: () -> Void
    var removal: SheetRemoval? = nil
    @ViewBuilder var fields: Fields
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoval = false
    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(title).font(Typeface.display(TypeSize.title2)).foregroundStyle(Palette.textPrimary).accessibilityAddTraits(.isHeader)
            fields
            if let error { StatusLabel(text: error, symbol: "exclamationmark.triangle", tone: .danger) }
            HStack(spacing: Space.sm) {
                if let removal {
                    Button(role: .destructive) { confirmRemoval = true } label: { Label(removal.label, systemImage: "trash") }.buttonStyle(VerbButtonStyle(kind: .danger))
                }
                Spacer()
                Button(cancel) { dismiss() }.buttonStyle(VerbButtonStyle(kind: .quiet)).keyboardShortcut(.cancelAction)
                Button(save, action: onSave).buttonStyle(VerbButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
            .padding(.top, Space.xs)
        }
        .padding(Space.xxl)
        .frame(width: width)
        .background(Palette.surfacePage)
        .confirmationDialog(removal?.question ?? "", isPresented: $confirmRemoval) {
            if let removal {
                Button(removal.confirm, role: .destructive) { removal.perform(); dismiss() }
                Button(cancel, role: .cancel) {}
            }
        } message: { Text(removal?.detail ?? "") }
    }
}
